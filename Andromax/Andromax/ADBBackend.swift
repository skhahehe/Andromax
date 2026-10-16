import Foundation

final class ADBBackend: FileBackend {
    let transport = Transport.adb
    let serial: String

    init(serial: String) {
        self.serial = serial
    }

    func roots() async throws -> [RemoteItem] {
        var roots = [directory(name: "Internal Storage", path: "/sdcard")]
        // Removable volumes are mounted as /storage/XXXX-XXXX.
        let storage = await ADB.shell(serial, "ls -1 /storage 2>/dev/null")
        for line in storage.out.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == "emulated" || name == "self" { continue }
            roots.append(directory(name: "SD Card (\(name))", path: "/storage/\(name)"))
        }
        roots.append(directory(name: "System Root", path: "/"))
        return roots
    }

    func list(_ directory: RemoteItem) async throws -> [RemoteItem] {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let result = await ADB.shell(serial, "ls -la \(ADB.quote(base))")
        let items = Self.parseListing(result.out, parent: base)
        // Old devices report failures on stdout with a zero exit status, so look at the text too.
        if items.isEmpty {
            let text = result.message
            let failed = result.status != 0 || text.contains("No such file") || text.contains("Permission denied")
            if failed && !text.isEmpty && !text.hasPrefix("total") {
                throw TransferError(Self.friendly(text))
            }
        }
        return items
    }

    func makeDirectory(named name: String, in directory: RemoteItem) async throws {
        try await check("mkdir \(ADB.quote(join(directory.path, name)))")
    }

    func rename(_ item: RemoteItem, to newName: String) async throws {
        let parent = (item.path as NSString).deletingLastPathComponent
        try await check("mv \(ADB.quote(item.path)) \(ADB.quote(join(parent, newName)))")
    }

    func delete(_ item: RemoteItem) async throws {
        try await check("rm -rf \(ADB.quote(item.path))")
    }

    func download(_ item: RemoteItem, to localURL: URL, control: TransferControl) async throws {
        do {
            try await ADB.transfer(["-s", serial, "pull", "-a", item.path, localURL.path], control: control)
        } catch {
            if control.isCancelled { try? FileManager.default.removeItem(at: localURL) }
            throw error
        }
    }

    func upload(_ localURL: URL, into directory: RemoteItem, existing: RemoteItem?, control: TransferControl) async throws {
        // Pushing into the directory (trailing slash) keeps the local name for files and folders alike.
        let target = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        try await ADB.transfer(["-s", serial, "push", localURL.path, target], control: control)
        // Older Android versions only show new media in the gallery after a scan.
        let remote = join(directory.path, localURL.lastPathComponent)
        _ = await ADB.shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ADB.quote("file://" + remote)) >/dev/null 2>&1")
    }

    func close() {}

    // MARK: - Helpers

    private func directory(name: String, path: String) -> RemoteItem {
        RemoteItem(id: path, name: name, isDirectory: true, size: 0, modified: nil, path: path)
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private func check(_ command: String) async throws {
        let result = await ADB.shell(serial, command)
        let text = result.message
        if result.status != 0 || !text.isEmpty {
            throw TransferError(Self.friendly(text.isEmpty ? "Command failed (\(result.status))" : text))
        }
    }

    private static func friendly(_ text: String) -> String {
        if text.contains("Permission denied") { return "Android doesn't allow access to this location." }
        if text.contains("No such file") { return "This item no longer exists on the phone." }
        if text.contains("device offline") || text.contains("not found") && text.contains("device") {
            return "The phone was disconnected."
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static let listingDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let dateAnchor = try! NSRegularExpression(pattern: #" (\d{4}-\d{2}-\d{2}) +(\d{2}:\d{2}) "#)

    /// Parses `ls -la` from both toybox (`perms links owner group size date time name`) and the
    /// pre-Marshmallow toolbox (`perms owner group [size] date time name`) by anchoring on the date.
    static func parseListing(_ output: String, parent: String) -> [RemoteItem] {
        var items: [RemoteItem] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let first = line.first, "-dlbcps".contains(first),
                  let match = dateAnchor.firstMatch(in: line, range: range),
                  let whole = Range(match.range, in: line),
                  let day = Range(match.range(at: 1), in: line),
                  let time = Range(match.range(at: 2), in: line) else { continue }

            var name = String(line[whole.upperBound...])
            if first == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name.isEmpty || name == "." || name == ".." { continue }

            let fields = line[..<whole.lowerBound].split(separator: " ")
            let size = fields.last.flatMap { Int64($0) } ?? 0
            let isDirectory = first == "d" || first == "l"
            let path = parent + name
            items.append(RemoteItem(
                id: path,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : size,
                modified: listingDate.date(from: "\(line[day]) \(line[time])"),
                path: path))
        }
        return items
    }
}
