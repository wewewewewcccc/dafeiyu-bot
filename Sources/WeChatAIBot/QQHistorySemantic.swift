import Foundation
import BotCore

struct QQHistorySemantic: Sendable {
    private let database: URL
    private let directory: URL
    private let script: URL
    private let python: URL

    init?(storage: URL) {
        guard let resources = RuntimeResources.directory else { return nil }
        database = storage.appendingPathComponent("qq-history.sqlite3")
        directory = storage.appendingPathComponent("semantic-model")
        script = resources.appendingPathComponent("Linux/history-semantic.py")
        python = directory.appendingPathComponent("venv/bin/python")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: "/usr/bin/timeout"), files.isExecutableFile(atPath: python.path),
              files.fileExists(atPath: script.path), files.fileExists(atPath: directory.appendingPathComponent("model.onnx").path),
              files.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) else { return nil }
    }

    static func expandedQuery(_ query: String, recent: String) -> String {
        guard query.count <= 80,
              query.range(of: #"那个|这个|那件事|上次|之前说|刚才说|后来呢|然后呢|改到哪|什么来着"#, options: .regularExpression) != nil else { return query }
        let topics = recent.split(separator: "\n").suffix(8).reversed().compactMap { line -> String? in
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String],
                  let text = row["text"], text.count >= 4, text != query, !text.hasPrefix("["), !text.hasPrefix("（") else { return nil }
            return String(text.prefix(100))
        }
        return ([query] + Array(topics.prefix(2))).joined(separator: "\n")
    }

    func candidates(text: String, scope: String, through time: Double, excluding: Set<String>) async -> [String] {
        let payload: [String: Any] = ["scope": scope, "text": String(QQMemoryBook.redact(text).suffix(1800)),
            "from": Date().timeIntervalSince1970 - QQHistory.retention, "through": time, "excluded": Array(excluding)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let output = await run("search", input: data, timeout: "6"),
              let ids = try? JSONDecoder().decode([String].self, from: output) else { return [] }
        return Array(ids.prefix(6))
    }

    func index(scope: String) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["scope": scope]) else { return }
        _ = await run("index", input: data, timeout: "15")
    }

    private func run(_ mode: String, input: Data, timeout: String) async -> Data? {
        guard !Task.isCancelled, input.count <= 32768 else { return nil }
        return await Task.detached(priority: mode == "index" ? .utility : .userInitiated) {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
            command.arguments = ["--signal=KILL", timeout, python.path, script.path, mode, database.path, directory.path]
            let stdin = Pipe(), stdout = Pipe()
            command.standardInput = stdin; command.standardOutput = stdout; command.standardError = FileHandle.nullDevice
            do {
                try command.run()
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                command.waitUntilExit()
                return command.terminationStatus == 0 && data.count <= 4096 ? data : nil
            } catch {
                try? stdin.fileHandleForWriting.close()
                return nil
            }
        }.value
    }
}
