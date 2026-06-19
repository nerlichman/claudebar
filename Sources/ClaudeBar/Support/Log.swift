import Foundation
import os

/// Plain-text file logger alongside os.Logger. The file log is what
/// scripts/verify.sh asserts on, so every refresh cycle writes one
/// summary line here.
enum Log {
    private static let osLogger = Logger(subsystem: "com.nerlichman.claudebar", category: "app")

    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeBar", isDirectory: true)
        let file = dir.appendingPathComponent("claudebar.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let queue = DispatchQueue(label: "com.nerlichman.claudebar.log")

    static func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        write(message)
    }

    static func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        write("ERROR: \(message)")
    }

    private static func write(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                try? fileHandle?.write(contentsOf: data)
            }
        }
    }
}
