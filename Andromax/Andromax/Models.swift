import Foundation

enum Transport: String, CaseIterable, Identifiable {
    case adb = "ADB"
    case mtp = "MTP"

    var id: String { rawValue }
}

/// Where an MTP device sits on the USB bus. Changes whenever the phone re-enumerates.
struct MTPRef: Hashable {
    let bus: UInt32
    let address: UInt8
}

/// One physical phone, reachable over ADB, MTP, or both.
struct PhoneDevice: Identifiable, Hashable {
    let id: String
    var name: String
    var adbSerial: String?
    var adbState: String?
    var mtp: MTPRef?

    var adbReady: Bool { adbSerial != nil && adbState == "device" }

    /// Usable transports, best first. ADB is faster and survives a locked screen.
    var transports: [Transport] {
        var result: [Transport] = []
        if adbReady { result.append(.adb) }
        if mtp != nil { result.append(.mtp) }
        return result
    }

    var statusText: String? {
        if !transports.isEmpty { return nil }
        switch adbState {
        case "unauthorized": return "Tap Allow on the phone"
        case "offline": return "Offline — replug the cable"
        case let state?: return state.capitalized
        default: return nil
        }
    }
}

struct RemoteItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    // ADB
    var path: String = ""
    // MTP
    var storageID: UInt32 = 0
    var objectID: UInt32 = 0

    /// Extra text for storage roots (free space).
    var detail: String? = nil

    var isHidden: Bool { name.hasPrefix(".") }
    var modifiedSort: Date { modified ?? .distantPast }
    var kindSort: String { isDirectory ? "" : (name as NSString).pathExtension.lowercased() }

    var sizeText: String {
        if let detail { return detail }
        if isDirectory { return "—" }
        return Format.bytes(size)
    }

    var modifiedText: String {
        guard let modified else { return "—" }
        return Format.date.string(from: modified)
    }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "dng": return "photo.fill"
        case "mp4", "mkv", "avi", "mov", "webm", "3gp": return "film.fill"
        case "mp3", "wav", "flac", "ogg", "m4a", "opus", "aac": return "waveform"
        case "zip", "rar", "tar", "gz", "7z": return "doc.zipper"
        case "apk", "xapk", "apks": return "shippingbox.fill"
        case "pdf": return "doc.richtext.fill"
        case "txt", "md", "log", "json", "xml", "csv": return "doc.text.fill"
        default: return "doc.fill"
        }
    }
}

enum Format {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

struct TransferError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared between a running transfer and the UI: progress flows up, cancellation flows down.
final class TransferControl {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandler: (() -> Void)?

    /// Fraction of the current top-level item (nil = unknown) and the file being copied.
    var report: (Double?, String?) -> Void = { _, _ in }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancelHandler
        lock.unlock()
        handler?()
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        cancelHandler = handler
        let already = cancelled
        lock.unlock()
        if already { handler() }
    }
}

/// A way of talking to one phone's file system.
protocol FileBackend: AnyObject {
    var transport: Transport { get }
    func roots() async throws -> [RemoteItem]
    func list(_ directory: RemoteItem) async throws -> [RemoteItem]
    func makeDirectory(named name: String, in directory: RemoteItem) async throws
    func rename(_ item: RemoteItem, to newName: String) async throws
    func delete(_ item: RemoteItem) async throws
    /// Copies `item` (file or folder) to `localURL`, which does not exist yet.
    func download(_ item: RemoteItem, to localURL: URL, control: TransferControl) async throws
    /// Copies `localURL` (file or folder) into `directory`. `existing` is the item it replaces or merges into.
    func upload(_ localURL: URL, into directory: RemoteItem, existing: RemoteItem?, control: TransferControl) async throws
    func close()
}
