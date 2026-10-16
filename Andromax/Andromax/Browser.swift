import Foundation
import SwiftUI

/// Drives the file browser for the selected phone: connection, navigation, file operations and transfers.
@MainActor
final class Browser: ObservableObject {
    struct Activity {
        var title: String
        var name: String
        var fraction: Double?
        var index: Int
        var count: Int
        var rate: String?
    }

    struct Summary {
        let text: String
        var details: [String] = []
        var reveal: [URL] = []
        var isError = false
    }

    struct Conflict: Identifiable {
        let id = UUID()
        let urls: [URL]
        let clashing: [String]
    }

    @Published private(set) var device: PhoneDevice?
    @Published private(set) var transport: Transport?
    @Published private(set) var crumbs: [RemoteItem] = []
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var isLoading = false
    /// Name of the folder being opened, shown at the bottom while a big folder loads.
    @Published private(set) var opening: String?
    @Published private(set) var problem: String?
    @Published private(set) var activity: Activity?
    @Published var selection = Set<RemoteItem.ID>()
    @Published var search = ""
    @Published var showHidden = false
    @Published var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    @Published var alertMessage: String?
    @Published var summary: Summary?
    @Published var conflict: Conflict?

    private var backend: FileBackend?
    private var connectionKey: String?
    private var chosenTransport: Transport?
    private var generation = 0
    private var connecting: Task<Void, Never>?

    var atRoots: Bool { crumbs.isEmpty }
    var canModify: Bool { backend != nil && !crumbs.isEmpty }

    var visibleItems: [RemoteItem] {
        var list = items
        if !showHidden { list.removeAll(where: \.isHidden) }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        if atRoots { return list }
        list.sort(using: sortOrder)
        return list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
    }

    var selectedItems: [RemoteItem] {
        guard !atRoots else { return [] }
        return items.filter { selection.contains($0.id) }
    }

    // MARK: - Connection

    /// Called whenever the selected phone or its available transports change.
    func show(_ newDevice: PhoneDevice?) {
        if device?.id != newDevice?.id {
            chosenTransport = nil
            transport = nil
        }
        device = newDevice
        let available = newDevice?.transports ?? []
        let choice = chosenTransport.flatMap { available.contains($0) ? $0 : nil }
            ?? transport.flatMap { available.contains($0) ? $0 : nil }
            ?? available.first
        connect(choice, force: false)
    }

    func choose(_ transport: Transport) {
        chosenTransport = transport
        connect(transport, force: false)
    }

    func retry() {
        connect(transport ?? device?.transports.first, force: true)
    }

    private func connect(_ choice: Transport?, force: Bool) {
        var key: String?
        if let device, let choice {
            key = "\(device.id)|\(choice.rawValue)"
        }
        // The bus address is deliberately not part of the key: opening an MTP session can make the
        // phone re-enumerate, and that must not tear down the session that caused it.
        if key == connectionKey && !force { return }
        connectionKey = key

        generation += 1
        let current = generation
        backend?.close()
        backend = nil
        transport = choice
        crumbs = []
        items = []
        selection = []
        search = ""
        problem = nil
        isLoading = false

        guard let device, let choice else { return }
        isLoading = true
        // Wait for the previous attempt to finish and release its session, or two opens race for the phone.
        let previous = connecting
        connecting = Task {
            await previous?.value
            guard current == generation else { return }
            do {
                let opened: FileBackend
                switch choice {
                case .adb: opened = ADBBackend(serial: device.adbSerial ?? "")
                case .mtp:
                    guard let ref = device.mtp else { throw TransferError("The phone is no longer in File Transfer mode.") }
                    opened = try await MTPBackend.open(ref)
                }
                guard current == generation else { opened.close(); return }
                backend = opened
                let roots = try await opened.roots()
                guard current == generation else { return }
                // Land straight in the main storage; the device level stays one click away.
                if let first = roots.first {
                    let listing = try await opened.list(first)
                    guard current == generation else { return }
                    crumbs = [first]
                    items = listing
                } else {
                    items = roots
                }
                isLoading = false
            } catch {
                guard current == generation else { return }
                isLoading = false
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - Navigation

    func open(_ item: RemoteItem) {
        guard item.isDirectory else { return }
        navigate(to: crumbs + [item])
    }

    func goUp() {
        guard !crumbs.isEmpty else { return }
        navigate(to: Array(crumbs.dropLast()))
    }

    /// `depth` 0 is the device level (list of storages).
    func jump(toDepth depth: Int) {
        guard depth < crumbs.count else { return }
        navigate(to: Array(crumbs.prefix(depth)))
    }

    func refresh() {
        navigate(to: crumbs, keepSelection: true)
    }

    private func navigate(to path: [RemoteItem], keepSelection: Bool = false) {
        guard let backend else { return }
        generation += 1
        let current = generation
        isLoading = true
        opening = keepSelection ? nil : path.last?.name ?? device?.name
        Task {
            defer { if current == generation { opening = nil } }
            do {
                let listing: [RemoteItem]
                if let directory = path.last {
                    listing = try await backend.list(directory)
                } else {
                    listing = try await backend.roots()
                }
                guard current == generation else { return }
                if !keepSelection {
                    selection = []
                    search = ""
                }
                crumbs = path
                items = listing
                problem = nil
            } catch {
                guard current == generation else { return }
                if keepSelection { problem = error.localizedDescription } else { alertMessage = error.localizedDescription }
            }
            isLoading = false
        }
    }

    // MARK: - File operations

    func makeFolder(named name: String) {
        guard let directory = crumbs.last, let name = validated(name) else { return }
        perform { try await $0.makeDirectory(named: name, in: directory) }
    }

    func rename(_ item: RemoteItem, to name: String) {
        guard let name = validated(name), name != item.name else { return }
        perform { try await $0.rename(item, to: name) }
    }

    func delete(_ targets: [RemoteItem]) {
        perform { backend in
            for item in targets { try await backend.delete(item) }
        }
    }

    private func validated(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("/") || items.contains(where: { $0.name == trimmed }) {
            alertMessage = trimmed.contains("/") ? "Names can't contain “/”." : "“\(trimmed)” already exists here."
            return nil
        }
        return trimmed
    }

    private func perform(_ operation: @escaping (FileBackend) async throws -> Void) {
        guard let backend else { return }
        Task {
            do {
                try await operation(backend)
            } catch {
                alertMessage = error.localizedDescription
            }
            if backend === self.backend { refresh() }
        }
    }

    // MARK: - Transfers

    private struct Job {
        enum Kind { case upload, download }
        let kind: Kind
        let backend: FileBackend
        var uploads: [(url: URL, existing: RemoteItem?)] = []
        var directory: RemoteItem?
        var downloads: [RemoteItem] = []
        var destination: URL?
        var deleteAfterwards = false
        var completion: ((Result<[URL], Error>) -> Void)?
    }

    /// Lets progress reports from background threads say which item they belong to.
    private final class Cursor {
        var index = 0
    }

    private var pending: [Job] = []
    private var running = false
    private var control: TransferControl?
    private var cursor = Cursor()
    private var weights: [Int64] = []
    private var bytesKnown = false
    private var rateSample: (time: Date, bytes: Double)?

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    func upload(_ urls: [URL]) {
        guard canModify else {
            alertMessage = "Open a storage on the phone first, then drop files into it."
            return
        }
        let names = Set(items.map(\.name))
        let clashing = urls.map(\.lastPathComponent).filter(names.contains)
        if clashing.isEmpty {
            startUpload(urls)
        } else {
            conflict = Conflict(urls: urls, clashing: clashing)
        }
    }

    func resolve(_ conflict: Conflict, replace: Bool) {
        let urls = replace ? conflict.urls : conflict.urls.filter { !conflict.clashing.contains($0.lastPathComponent) }
        if !urls.isEmpty { startUpload(urls) }
    }

    private func startUpload(_ urls: [URL]) {
        guard let backend, let directory = crumbs.last else { return }
        let existing = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var job = Job(kind: .upload, backend: backend)
        job.directory = directory
        job.uploads = urls.map { ($0, existing[$0.lastPathComponent]) }
        enqueue(job)
    }

    func download(_ targets: [RemoteItem], to folder: URL, deleteAfterwards: Bool = false) {
        guard let backend, !targets.isEmpty else { return }
        var job = Job(kind: .download, backend: backend)
        job.downloads = targets
        job.destination = folder
        job.deleteAfterwards = deleteAfterwards
        enqueue(job)
    }

    /// Downloads one item into a temporary folder; used when a file is dragged out to Finder.
    func fetchForDrag(_ item: RemoteItem) async throws -> URL {
        guard let backend else { throw TransferError("The phone was disconnected.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Andromax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            var job = Job(kind: .download, backend: backend)
            job.downloads = [item]
            job.destination = folder
            job.completion = { result in
                continuation.resume(with: result.flatMap { urls in
                    urls.first.map(Result.success) ?? .failure(TransferError("Couldn't copy “\(item.name)”."))
                })
            }
            enqueue(job)
        }
    }

    func cancelTransfers() {
        for job in pending { job.completion?(.failure(CancellationError())) }
        pending.removeAll()
        control?.cancel()
    }

    private func enqueue(_ job: Job) {
        pending.append(job)
        pump()
    }

    private func pump() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let job = pending.removeFirst()
        Task {
            await run(job)
            running = false
            if pending.isEmpty { activity = nil }
            pump()
        }
    }

    private func run(_ job: Job) async {
        let uploading = job.kind == .upload
        let names = uploading ? job.uploads.map(\.url.lastPathComponent) : job.downloads.map(\.name)
        let count = names.count
        summary = nil
        activity = Activity(title: uploading ? "Copying to phone" : "Copying to Mac", name: names.first ?? "", fraction: nil, index: 1, count: count)

        // Weigh each item by size so the bar moves evenly; folders on the phone have no known size.
        if uploading {
            let urls = job.uploads.map(\.url)
            weights = await Task.detached { urls.map(Self.localSize(of:)) }.value
            bytesKnown = true
        } else if job.downloads.contains(where: \.isDirectory) {
            weights = Array(repeating: 1, count: count)
            bytesKnown = false
        } else {
            weights = job.downloads.map(\.size)
            bytesKnown = true
        }
        weights = weights.map { max($0, 1) }
        rateSample = nil

        let control = TransferControl()
        let cursor = Cursor()
        self.control = control
        self.cursor = cursor
        control.report = { [weak self] fraction, name in
            let index = cursor.index
            DispatchQueue.main.async { self?.tick(index: index, fraction: fraction, name: name) }
        }

        var produced: [URL] = []
        var failures: [String] = []
        var cancelled = false
        for index in 0..<count {
            if control.isCancelled { cancelled = true; break }
            cursor.index = index
            activity?.index = index + 1
            activity?.name = names[index]
            tick(index: index, fraction: count == 1 ? nil : 0, name: nil)
            do {
                if uploading, let directory = job.directory {
                    let entry = job.uploads[index]
                    try await job.backend.upload(entry.url, into: directory, existing: entry.existing, control: control)
                } else if let destination = job.destination {
                    let item = job.downloads[index]
                    let target = Self.uniqueURL(in: destination, name: item.name)
                    try await job.backend.download(item, to: target, control: control)
                    produced.append(target)
                    if job.deleteAfterwards { try await job.backend.delete(item) }
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(names[index]): \(error.localizedDescription)")
                if control.isCancelled { cancelled = true; break }
            }
        }
        self.control = nil

        if let completion = job.completion {
            completion(cancelled ? .failure(CancellationError()) : failures.isEmpty ? .success(produced) : .failure(TransferError(failures[0])))
        }
        if job.backend === backend && (uploading || job.deleteAfterwards) { refresh() }

        let done = uploading ? count - failures.count : produced.count
        let noun = count == 1 ? "“\(names[0])”" : "\(done) of \(count) items"
        if cancelled {
            summary = Summary(text: "Transfer cancelled", reveal: job.completion == nil ? produced : [])
        } else if !failures.isEmpty {
            summary = Summary(text: count == 1 ? failures[0] : "\(failures.count) of \(count) items couldn't be copied", details: count == 1 ? [] : failures, reveal: job.completion == nil ? produced : [], isError: true)
        } else if job.completion == nil {
            let place = uploading ? (device?.name ?? "phone") : (job.destination?.lastPathComponent ?? "Mac")
            summary = Summary(text: "\(job.deleteAfterwards ? "Moved" : "Copied") \(count == 1 ? noun : "\(count) items") to \(place)", reveal: produced)
        }
    }

    private func tick(index: Int, fraction: Double?, name: String?) {
        guard running, index == cursor.index, activity != nil, index < weights.count else { return }
        if let name, !name.isEmpty { activity?.name = name }
        guard let fraction else {
            if weights.count == 1 { activity?.fraction = nil }
            return
        }
        let total = Double(weights.reduce(0, +))
        let done = Double(weights.prefix(index).reduce(0, +)) + Double(weights[index]) * fraction
        activity?.fraction = min(done / total, 1)

        guard bytesKnown else { return }
        let now = Date()
        guard let sample = rateSample else {
            rateSample = (now, done)
            return
        }
        let elapsed = now.timeIntervalSince(sample.time)
        if elapsed >= 1 {
            let rate = max(done - sample.bytes, 0) / elapsed
            activity?.rate = "\(Format.bytes(Int64(rate)))/s"
            rateSample = (now, done)
        }
    }

    // MARK: - Local helpers

    /// Picks "name 2.ext" style names so nothing on the Mac is overwritten.
    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: ":")
        var candidate = folder.appendingPathComponent(safeName)
        let stem = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    nonisolated static func localSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let child = enumerator?.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
