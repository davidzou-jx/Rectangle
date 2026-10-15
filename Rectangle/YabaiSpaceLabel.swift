/// YabaiSpaceLabel.swift

import Foundation

enum YabaiSpaceLabel {
    static func abbreviated(_ label: String?, delimiter: String) -> String? {
        guard let label else { return nil }
        let firstPart: Substring
        if !delimiter.isEmpty, let separator = label.range(of: delimiter) {
            firstPart = label[..<separator.lowerBound]
        } else {
            firstPart = label[...]
        }
        let text = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let abbreviated = String(text.prefix(max(0, StatusItemSpaceLabelStyle.maxCharacters)))
        return abbreviated.isEmpty ? nil : abbreviated
    }

    static func label(from data: Data) -> String? {
        struct FocusedSpace: Decodable { let label: String }
        return (try? JSONDecoder().decode(FocusedSpace.self, from: data))?.label
    }
}

/// Queries only while the label option is enabled. All process work stays off the menu bar thread.
final class YabaiSpaceLabelReader {
    private let queue = DispatchQueue(label: "Rectangle.YabaiSpaceLabel", qos: .utility)
    private let executableProvider: () -> URL?
    private let timeout: TimeInterval

    init(executableProvider: @escaping () -> URL? = { YabaiSpaceLabelReader.executableURL() },
         timeout: TimeInterval = 0.75) {
        self.executableProvider = executableProvider
        self.timeout = timeout
    }

    func read(completion: @escaping (String?) -> Void) {
        queue.async {
            let label = self.query()
            DispatchQueue.main.async { completion(label) }
        }
    }

    static func executableURL() -> URL? {
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for directory in searchPaths where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("yabai")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func query() -> String? {
        guard let executable = executableProvider() else { return nil }
        let process = Process()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["-m", "query", "--spaces", "--space"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 65_536 else { return nil }
        return YabaiSpaceLabel.label(from: data)
    }
}
