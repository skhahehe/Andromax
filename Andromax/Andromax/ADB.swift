import Foundation

/// Thin wrapper around the `adb` command-line tool.
enum ADB {
    struct Output {
        let status: Int32
        let out: String
        let err: String

        var message: String {
            let text = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    /// Where Andromax keeps its own copy of Google's platform-tools when the Mac has none.
    static let managedFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Andromax/platform-tools")

    /// An adb the user already has wins over Andromax's own copy, so we never fight
    /// Android Studio over which server version is running.
    static var path: String {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            managedFolder.appendingPathComponent("adb").path,
        ]
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.insert("\(sdk)/platform-tools/adb", at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[candidates.count - 1]
    }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// First run on a Mac without adb: fetch Google's official platform-tools into Application Support.
    static func install() async throws {
        let source = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
        let (zip, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TransferError("Couldn't download Android platform-tools from Google.")
        }
        let parent = managedFolder.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard tool("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) == 0 else {
            throw TransferError("Couldn't unpack Android platform-tools.")
        }
        let unpacked = staging.appendingPathComponent("platform-tools")
        // Only ever run an adb that Google signed (team EQHXZ8M8AV).
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard tool("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", unpacked.appendingPathComponent("adb").path]) == 0 else {
            throw TransferError("The downloaded adb isn't signed by Google, so it wasn't installed.")
        }
        try? FileManager.default.removeItem(at: managedFolder)
        try FileManager.default.moveItem(at: unpacked, to: managedFolder)
    }

    private static func tool(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func run(_ arguments: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    out: String(decoding: outData, as: UTF8.self),
                    err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    /// Runs a shell command on the device. `command` is passed to the remote shell as-is.
    static func shell(_ serial: String, _ command: String) async -> Output {
        await run(["-s", serial, "shell", command])
    }

    /// Quotes a string for the device's shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a push/pull, feeding adb's `[ 42%] /path` progress lines to `control`.
    /// adb only prints progress to a terminal, so it gets a pseudo-terminal instead of a pipe.
    static func transfer(_ arguments: [String], control: TransferControl) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var primary: Int32 = -1, secondary: Int32 = -1
                // Wide enough that adb never shortens a path to fit the "window".
                var size = winsize(ws_row: 24, ws_col: 4096, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
                    continuation.resume(throwing: TransferError("Couldn't start adb."))
                    return
                }
                let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm"]) { _, new in new }
                process.standardOutput = terminal
                process.standardError = terminal
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    close(primary)
                    close(secondary)
                    continuation.resume(throwing: error)
                    return
                }
                close(secondary)
                control.onCancel { if process.isRunning { process.terminate() } }

                var pending = Data()
                var lastMessage = ""
                var buffer = [UInt8](repeating: 0, count: 4096)
                // read() fails with EIO once adb exits and the terminal closes.
                while case let count = read(primary, &buffer, buffer.count), count > 0 {
                    pending.append(contentsOf: buffer[0..<count])
                    while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: pending[pending.startIndex..<index], as: UTF8.self)
                            .replacingOccurrences(of: "\u{1B}[K", with: "")
                        pending.removeSubrange(pending.startIndex...index)
                        if let progress = parseProgress(line) {
                            control.report(progress.fraction, progress.name)
                        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            lastMessage = line
                        }
                    }
                }
                close(primary)
                process.waitUntilExit()
                control.onCancel {}

                if control.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: TransferError(explain(lastMessage, status: process.terminationStatus)))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func explain(_ message: String, status: Int32) -> String {
        if message.contains("Operation not permitted") || message.contains("Invalid argument") {
            return "Android doesn't accept this file name here. Names can't contain \" * : < > ? \\ or |."
        }
        if message.contains("No space left") { return "The phone's storage is full." }
        if message.contains("Permission denied") { return "Android doesn't allow access to this location." }
        if message.contains("offline") || message.contains("not found") || message.contains("no devices") {
            return "The phone was disconnected."
        }
        let text = message.replacingOccurrences(of: "adb: error: ", with: "")
        return text.isEmpty ? "adb exited with status \(status)." : text
    }

    /// Parses `[ 42%] /sdcard/a.bin` and `[ 42%] /sdcard/dir/a.bin: 17%`.
    static func parseProgress(_ line: String) -> (fraction: Double?, name: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inside = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard inside.hasSuffix("%") || inside == "?" else { return nil }
        let fraction = Double(inside.dropLast()).map { min(max($0 / 100, 0), 1) }
        var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if let colon = rest.range(of: ": ", options: .backwards),
           rest[colon.upperBound...].hasSuffix("%") || rest[colon.upperBound...].hasSuffix("/?") {
            rest = String(rest[..<colon.lowerBound])
        }
        return (fraction, (rest as NSString).lastPathComponent)
    }
}
