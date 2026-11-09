import Foundation
import Testing
@testable import BotCore

struct QQHistoryTests {
    @Test func windowsAreScopedBoundedAndSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.sqlite3")
        let scope = "12345:group:54321"
        let now = Date()
        func event(_ index: Int, _ text: String) -> QQMemoryEvent {
            QQMemoryEvent(id: String(index), subject: "MEMBER_\(index)", text: text, at: now.addingTimeInterval(Double(index - 200)))
        }
        do {
            let store = try QQHistory(url: file)
            var rows = (0..<155).map { event($0, "普通消息") }
            rows[24] = event(24, "项目 超出前窗")
            rows[25] = event(25, "项目 窗口前沿")
            rows[75] = event(75, "项目蓝图 确认命中")
            rows[76] = event(76, "项目蓝图 第二命中")
            rows[77] = event(77, "项目蓝图 第三命中")
            rows[125] = event(125, "蓝图 窗口后沿")
            rows[130] = event(130, "项目 超出后窗")
            try store.savePage(rows, scope: scope, cursor: "0", state: "", pages: 1)
            try store.append([event(75, "项目 重复写入")], scope: scope)
            try store.append([event(75, "项目蓝图 跨群隐私")], scope: "12345:group:65432")
        }
        let store = try QQHistory(url: file)
        #expect(try store.progress(scope: scope).pages == 1)
        let context = try store.context(for: "项目蓝图", scope: scope, through: now.timeIntervalSince1970, excluding: [])
        for expected in ["确认命中", "窗口前沿", "窗口后沿"] { #expect(context.contains(expected)) }
        for excluded in ["超出前窗", "超出后窗", "跨群隐私", "重复写入"] { #expect(!context.contains(excluded)) }
        #expect(context.count <= 1800)
        #expect(try store.context(for: "无关主题", scope: scope, through: now.timeIntervalSince1970, excluding: []).isEmpty)
        let early = try store.context(for: "项目蓝图", scope: scope, through: now.timeIntervalSince1970 - 126, excluding: ["25"])
        #expect(!early.contains("确认命中") && !early.contains("窗口前沿"))
        try store.prune(now: now.addingTimeInterval(QQHistory.retention))
        #expect(try store.context(for: "项目蓝图", scope: scope, through: now.timeIntervalSince1970, excluding: []).isEmpty)
        try store.clear(scope: scope)
        #expect(try store.progress(scope: scope).pages == 0)
        try store.append([event(75, "项目蓝图 不应恢复")], scope: scope)
        #expect(try store.context(for: "项目蓝图", scope: scope, through: now.timeIntervalSince1970, excluding: []).isEmpty)
    }

    @Test func groupsSameSpeakerAcrossAdjacentAndInterruptedMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try QQHistory(url: directory.appendingPathComponent("archive.sqlite3"))
        let start = Date().addingTimeInterval(-5000)
        let scope = "12345:group:54321"
        let rows: [(Double, String, String)] = [
            (0, "MEMBER_A", "唯一检索锚点"),
            (600, "MEMBER_A", "隔得久但相邻"),
            (650, "BOT", "机器人的起句"),
            (900, "MEMBER_A", "被插话后恰好五分钟"),
            (920, "BOT", "机器人的续句"),
            (1201, "MEMBER_A", "被插话后超过五分钟")
        ]
        try history.append(rows.enumerated().map { i, row in
            QQMemoryEvent(id: String(i), subject: row.1, text: row.2, at: start.addingTimeInterval(row.0))
        }, scope: scope)
        let context = try history.context(for: "唯一检索锚点", scope: scope, through: Date().timeIntervalSince1970, excluding: [])
        #expect(context.contains("隔得久但相邻"))
        #expect(context.contains("被插话后恰好五分钟"))
        #expect(!context.contains("机器人的起句"))
        #expect(!context.contains("被插话后超过五分钟"))
        let bot = try history.context(for: "机器人的起句", scope: scope, through: Date().timeIntervalSince1970, excluding: [])
        #expect(bot.contains("机器人的续句"))
        let early = try history.context(for: "唯一检索锚点", scope: scope, through: start.addingTimeInterval(899).timeIntervalSince1970, excluding: ["1"])
        #expect(!early.contains("隔得久但相邻") && !early.contains("被插话后恰好五分钟"))
    }
}
