import Foundation

/// libmtp is not thread-safe, so every call into it goes through one serial queue.
enum MTP {
    struct Detected {
        let ref: MTPRef
        let vendor: String?
        let product: String?
    }

    static let queue = DispatchQueue(label: "andromax.mtp", qos: .userInitiated)
    private static var initialized = false

    static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if !initialized {
                    LIBMTP_Init()
                    initialized = true
                }
                continuation.resume(with: Result { try body() })
            }
        }
    }

    static func detect() async -> [Detected] {
        (try? await run {
            rawDevices().map { raw in
                Detected(
                    ref: MTPRef(bus: raw.bus_location, address: raw.devnum),
                    vendor: raw.device_entry.vendor.map { String(cString: $0) },
                    product: raw.device_entry.product.map { String(cString: $0) })
            }
        }) ?? []
    }

    /// Must be called on `queue`.
    fileprivate static func rawDevices() -> [LIBMTP_raw_device_t] {
        var pointer: UnsafeMutablePointer<LIBMTP_raw_device_t>? = nil
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&pointer, &count)
        defer { free(pointer) }
        guard status == LIBMTP_ERROR_NONE, count > 0, let pointer else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
    }

    /// macOS's own camera daemon (ptpcamerad) grabs any PTP/MTP interface the moment a phone
    /// appears and holds it exclusively, and launchd restarts it as soon as it exits. Keeping it
    /// down for the few seconds it takes to open our session is what lets libusb claim the
    /// interface; once we hold it the daemon can't take it back, and it returns after we let go.
    fileprivate final class SystemClaimGuard {
        private let lock = NSLock()
        private var active = true

        init() {
            Thread.detachNewThread { [self] in
                while isActive {
                    var pids = [pid_t](repeating: 0, count: 4096)
                    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
                    for pid in pids.prefix(max(count, 0)) {
                        var name = [CChar](repeating: 0, count: 64)
                        proc_name(pid, &name, UInt32(name.count))
                        if String(cString: name) == "ptpcamerad" { kill(pid, SIGKILL) }
                    }
                    usleep(20_000)
                }
            }
            usleep(60_000)
        }

        private var isActive: Bool {
            lock.lock(); defer { lock.unlock() }
            return active
        }

        func stop() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }
}

final class MTPBackend: FileBackend {
    let transport = Transport.mtp
    private typealias Device = UnsafeMutablePointer<LIBMTP_mtpdevice_t>
    private var device: Device?

    /// Whether the phone can read and write files in pieces, which is what makes cancelling safe.
    private let canReadChunks: Bool
    private let canWriteChunks: Bool

    private init(device: Device) {
        self.device = device
        canReadChunks = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_GetPartialObject) != 0
        canWriteChunks = LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_SendPartialObject) != 0
            && LIBMTP_Check_Capability(device, LIBMTP_DEVICECAP_EditObjects) != 0
    }

    deinit {
        if let device {
            MTP.queue.async { LIBMTP_Release_Device(device) }
        }
    }

    static func open(_ ref: MTPRef) async throws -> MTPBackend {
        try await MTP.run { MTPBackend(device: try openSession(ref)) }
    }

    /// Must be called on `MTP.queue`.
    private static func openSession(_ ref: MTPRef) throws -> Device {
        let claimGuard = MTP.SystemClaimGuard()
        defer { claimGuard.stop() }
        // macOS respawns the daemon about a second after it dies, then backs off for ~10s, so
        // keep trying for a while rather than giving up inside that first second.
        let attempts = 16
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(500_000) }
            // Opening can reset the phone, which gives it a new bus address, so fall back to
            // the only MTP device when the address we were given has gone stale.
            let found = MTP.rawDevices()
            guard var raw = found.first(where: { $0.bus_location == ref.bus && $0.devnum == ref.address })
                    ?? (found.count == 1 ? found.first : nil) else {
                if attempt < attempts - 1 { continue }
                throw TransferError("The phone is no longer in File Transfer mode.")
            }
            if let device = LIBMTP_Open_Raw_Device_Uncached(&raw) { return device }
        }
        throw TransferError("Couldn't open the phone over MTP. Unlock it, make sure File Transfer is selected, and quit other apps that may be using it (Android File Transfer, Image Capture, Photos, Google Drive).")
    }

    func close() {
        // Runs after any transfer already on the queue, so the session is never pulled out from under it.
        MTP.queue.async { [self] in
            guard let device else { return }
            self.device = nil
            LIBMTP_Release_Device(device)
        }
    }

    // MARK: - Browsing

    func roots() async throws -> [RemoteItem] {
        try await onDevice { device in
            if LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 {
                LIBMTP_Clear_Errorstack(device)
            }
            var roots: [RemoteItem] = []
            var storage = device.pointee.storage
            while let current = storage {
                let info = current.pointee
                let name = info.StorageDescription.map { String(cString: $0) } ?? ""
                var root = RemoteItem(
                    id: "\(info.id):root",
                    name: name.isEmpty ? "Storage" : name,
                    isDirectory: true,
                    size: 0,
                    modified: nil,
                    storageID: info.id,
                    objectID: LIBMTP_FILES_AND_FOLDERS_ROOT)
                if info.MaxCapacity > 0 {
                    root.detail = "\(Format.bytes(Int64(clamping: info.FreeSpaceInBytes))) free"
                }
                roots.append(root)
                storage = info.next
            }
            if roots.isEmpty {
                throw TransferError("The phone isn't sharing its files yet. Unlock it, pull down the notification shade, tap the USB notification and choose File Transfer.")
            }
            return roots
        }
    }

    func list(_ directory: RemoteItem) async throws -> [RemoteItem] {
        try await onDevice { device in
            try Self.children(device, storage: directory.storageID, parent: directory.objectID)
        }
    }

    func makeDirectory(named name: String, in directory: RemoteItem) async throws {
        try await onDevice { device in
            _ = try Self.createFolder(device, name: name, storage: directory.storageID, parent: directory.objectID)
        }
    }

    func rename(_ item: RemoteItem, to newName: String) async throws {
        try await onDevice { device in
            let name = strdup(newName)
            defer { free(name) }
            if LIBMTP_Set_Object_Filename(device, item.objectID, name) != 0 {
                throw Self.failure(device, "Couldn't rename “\(item.name)”.")
            }
        }
    }

    func delete(_ item: RemoteItem) async throws {
        try await onDevice { device in
            if LIBMTP_Delete_Object(device, item.objectID) != 0 {
                throw Self.failure(device, "Couldn't delete “\(item.name)”.")
            }
        }
    }

    // MARK: - Transfers

    func download(_ item: RemoteItem, to localURL: URL, control: TransferControl) async throws {
        try await onDevice { device in
            // Walk the tree first so progress covers the whole folder.
            var plan: [(item: RemoteItem, url: URL)] = []
            var total: Int64 = 0
            func walk(_ item: RemoteItem, _ url: URL) throws {
                if control.isCancelled { throw CancellationError() }
                plan.append((item, url))
                if item.isDirectory {
                    control.report(nil, item.name)
                    for child in try Self.children(device, storage: item.storageID, parent: item.objectID) {
                        try walk(child, url.appendingPathComponent(child.name))
                    }
                } else {
                    total += item.size
                }
            }
            try walk(item, localURL)

            let progress = ProgressContext(control: control, total: total)
            let fileManager = FileManager.default
            for entry in plan {
                if control.isCancelled { throw CancellationError() }
                if entry.item.isDirectory {
                    try fileManager.createDirectory(at: entry.url, withIntermediateDirectories: true)
                    continue
                }
                progress.name = entry.item.name
                do {
                    if self.canReadChunks && entry.item.size > Self.chunkSize {
                        try Self.readInChunks(device, entry.item, to: entry.url, progress: progress)
                    } else {
                        let status = withExtendedLifetime(progress) {
                            LIBMTP_Get_File_To_File(device, entry.item.objectID, entry.url.path, mtpProgress, Unmanaged.passUnretained(progress).toOpaque())
                        }
                        if status != 0 { throw Self.failure(device, "Couldn't copy “\(entry.item.name)” from the phone.") }
                    }
                } catch {
                    try? fileManager.removeItem(at: entry.url)
                    if error is CancellationError { try? fileManager.removeItem(at: localURL) }
                    throw error
                }
                if let modified = entry.item.modified {
                    try? fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: entry.url.path)
                }
                progress.base += entry.item.size
            }
        }
    }

    func upload(_ localURL: URL, into directory: RemoteItem, existing: RemoteItem?, control: TransferControl) async throws {
        try await onDevice { device in
            let progress = ProgressContext(control: control, total: Browser.localSize(of: localURL))
            try Self.send(device, localURL, storage: directory.storageID, parent: directory.objectID, existing: existing, chunked: self.canWriteChunks, progress: progress)
        }
    }

    private static func send(_ device: Device, _ url: URL, storage: UInt32, parent: UInt32, existing: RemoteItem?, chunked: Bool, progress: ProgressContext) throws {
        if progress.control.isCancelled { throw CancellationError() }
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TransferError("“\(name)” no longer exists on this Mac.")
        }

        if isDirectory.boolValue {
            var folderID: UInt32
            var known: [String: RemoteItem] = [:]
            if let existing, existing.isDirectory {
                // Merge into the folder that is already there.
                folderID = existing.objectID
                for child in try children(device, storage: storage, parent: folderID) { known[child.name] = child }
            } else {
                if let existing { try remove(device, existing) }
                folderID = try createFolder(device, name: name, storage: storage, parent: parent)
            }
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for child in contents where child.lastPathComponent != ".DS_Store" {
                try send(device, child, storage: storage, parent: folderID, existing: known[child.lastPathComponent], chunked: chunked, progress: progress)
            }
            return
        }

        if let existing { try remove(device, existing) }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress.name = name
        if chunked && size > chunkSize {
            try writeInChunks(device, url, size: size, storage: storage, parent: parent, progress: progress)
        } else {
            let file = try newFile(name: name, size: size, storage: storage, parent: parent)
            defer { LIBMTP_destroy_file_t(file) }
            let status = withExtendedLifetime(progress) {
                LIBMTP_Send_File_From_File(device, url.path, file, mtpProgress, Unmanaged.passUnretained(progress).toOpaque())
            }
            if status != 0 { throw failure(device, "Couldn't copy “\(name)” to the phone.") }
        }
        progress.base += size
    }

    // MARK: - Chunked transfers

    // Aborting a transfer mid-stream makes some phones (Pixels among them) drop off USB until they
    // are replugged. Large files therefore move in pieces, and a cancel simply stops between two.
    private static let chunkSize: Int64 = 8 * 1024 * 1024

    private static func readInChunks(_ device: Device, _ item: RemoteItem, to url: URL, progress: ProgressContext) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TransferError("Couldn't create “\(item.name)” on this Mac.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < item.size {
            if progress.control.isCancelled { throw CancellationError() }
            var bytes: UnsafeMutablePointer<UInt8>? = nil
            var count: UInt32 = 0
            let status = LIBMTP_GetPartialObject(device, item.objectID, UInt64(offset), UInt32(min(chunkSize, item.size - offset)), &bytes, &count)
            defer { free(bytes) }
            guard status == 0, count > 0, let bytes else {
                throw failure(device, "Couldn't copy “\(item.name)” from the phone.")
            }
            try handle.write(contentsOf: UnsafeBufferPointer(start: bytes, count: Int(count)))
            offset += Int64(count)
            progress.report(done: offset)
        }
    }

    private static func writeInChunks(_ device: Device, _ url: URL, size: Int64, storage: UInt32, parent: UInt32, progress: ProgressContext) throws {
        let name = url.lastPathComponent
        let problem = "Couldn't copy “\(name)” to the phone."
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }

        // Create the file empty, then fill it in place.
        let file = try newFile(name: name, size: 0, storage: storage, parent: parent)
        defer { LIBMTP_destroy_file_t(file) }
        let empty = Darwin.open("/dev/null", O_RDONLY)
        defer { Darwin.close(empty) }
        guard LIBMTP_Send_File_From_File_Descriptor(device, empty, file, nil, nil) == 0 else { throw failure(device, problem) }
        let id = file.pointee.item_id
        guard LIBMTP_BeginEditObject(device, id) == 0 else {
            LIBMTP_Delete_Object(device, id)
            throw failure(device, problem)
        }

        var offset: Int64 = 0
        var outcome: Error?
        while offset < size {
            if progress.control.isCancelled { outcome = CancellationError(); break }
            guard var chunk = try? source.read(upToCount: Int(chunkSize)), !chunk.isEmpty else {
                outcome = TransferError("Couldn't read “\(name)” on this Mac.")
                break
            }
            let count = chunk.count
            let status = chunk.withUnsafeMutableBytes {
                LIBMTP_SendPartialObject(device, id, UInt64(offset), $0.bindMemory(to: UInt8.self).baseAddress, UInt32(count))
            }
            if status != 0 { outcome = failure(device, problem); break }
            offset += Int64(count)
            progress.report(done: offset)
        }
        let ended = LIBMTP_EndEditObject(device, id)
        if outcome == nil && ended != 0 { outcome = failure(device, problem) }
        if let outcome {
            // Never leave a half-written file behind.
            LIBMTP_Delete_Object(device, id)
            LIBMTP_Clear_Errorstack(device)
            throw outcome
        }
    }

    private static func newFile(name: String, size: Int64, storage: UInt32, parent: UInt32) throws -> UnsafeMutablePointer<LIBMTP_file_t> {
        guard let file = LIBMTP_new_file_t() else { throw TransferError("Out of memory.") }
        file.pointee.filename = strdup(name)
        file.pointee.filesize = UInt64(size)
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = parent
        file.pointee.storage_id = storage
        return file
    }

    // MARK: - libmtp helpers (call on MTP.queue)

    private func onDevice<T>(_ body: @escaping (Device) throws -> T) async throws -> T {
        try await MTP.run { [self] in
            guard let device else { throw TransferError("The phone was disconnected.") }
            return try body(device)
        }
    }

    private static func children(_ device: Device, storage: UInt32, parent: UInt32) throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        // One bulk request for the whole folder; the per-file fallback takes minutes on big ones.
        var next: UnsafeMutablePointer<LIBMTP_file_t>?
        if LIBMTP_Get_Children_Fast(device, storage, parent, &next) != 0 {
            LIBMTP_Clear_Errorstack(device)
            next = LIBMTP_Get_Files_And_Folders(device, storage, parent)
            if next == nil, LIBMTP_Get_Errorstack(device) != nil {
                throw failure(device, "Couldn't read this folder.")
            }
        }
        while let file = next {
            let info = file.pointee
            let isDirectory = info.filetype == LIBMTP_FILETYPE_FOLDER
            items.append(RemoteItem(
                id: "\(storage):\(info.item_id)",
                name: info.filename.map { String(cString: $0) } ?? "Untitled",
                isDirectory: isDirectory,
                size: isDirectory ? 0 : Int64(clamping: info.filesize),
                modified: info.modificationdate > 0 ? Date(timeIntervalSince1970: TimeInterval(info.modificationdate)) : nil,
                storageID: storage,
                objectID: info.item_id))
            next = info.next
            LIBMTP_destroy_file_t(file)
        }
        return items
    }

    private static func createFolder(_ device: Device, name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let cName = strdup(name)
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(device, cName, parent, storage)
        if id == 0 { throw failure(device, "Couldn't create the folder “\(name)”.") }
        return id
    }

    private static func remove(_ device: Device, _ item: RemoteItem) throws {
        if LIBMTP_Delete_Object(device, item.objectID) != 0 {
            throw failure(device, "Couldn't replace “\(item.name)”.")
        }
    }

    /// Builds an error from libmtp's error stack and clears it.
    private static func failure(_ device: Device, _ summary: String) -> TransferError {
        var details: [String] = []
        var entry = LIBMTP_Get_Errorstack(device)
        while let current = entry {
            if let text = current.pointee.error_text { details.append(String(cString: text)) }
            entry = current.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        let joined = details.joined(separator: " ")
        if joined.contains("02ff") || joined.lowercased().contains("no device") || joined.contains("LIBUSB_ERROR") {
            return TransferError("\(summary) The phone stopped responding — check the cable and that the phone is unlocked.")
        }
        if joined.lowercased().contains("store") && joined.lowercased().contains("full") {
            return TransferError("\(summary) The phone's storage is full.")
        }
        return TransferError(summary)
    }
}

/// State handed to libmtp's C progress callback.
private final class ProgressContext {
    let control: TransferControl
    let total: Int64
    /// Bytes finished in earlier files of the same top-level item.
    var base: Int64 = 0
    var name = ""
    var lastReport = Date.distantPast

    init(control: TransferControl, total: Int64) {
        self.control = control
        self.total = total
    }

    /// `done` is the number of bytes finished in the current file.
    func report(done: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.1 else { return }
        lastReport = now
        control.report(total > 0 ? min(Double(base + done) / Double(total), 1) : nil, name)
    }
}

private let mtpProgress: LIBMTP_progressfunc_t = { sent, _, data in
    guard let data else { return 0 }
    // Always let the file finish: asking libmtp to abort here is what knocks phones off USB.
    Unmanaged<ProgressContext>.fromOpaque(data).takeUnretainedValue().report(done: Int64(clamping: sent))
    return 0
}
