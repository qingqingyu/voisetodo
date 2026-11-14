import XCTest
@testable import VoiceTodo

/// BGTask 标识符一致性守卫:代码注册的任务标识符必须出现在 project.yml 的
/// `BGTaskSchedulerPermittedIdentifiers` 里(xcodegen 据此生成 Info.plist)。
/// 不一致时 BGTaskScheduler 报 error 3(Unrecognized Identifier),后台遥测
/// 上报静默失效——2026-11-14 真机日志实锤过一次(代码 `com.voicetodo.app.*`
/// vs plist `com.qingqingyu.voicetodo.*`)。改任一侧必须同步另一侧。
final class TelemetryUploaderGuardTests: XCTestCase {
    /// 惰性执行且不缓存:project.yml 是仓库文件,改完即生效,无需缓存。
    private func loadProjectYml() throws -> String {
        // VoiceTodoTests/App/本文件 → 上三级 = 仓库根
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    /// 从 project.yml 文本提取 `BGTaskSchedulerPermittedIdentifiers:` 声明的
    /// 标识符列表。只在声明块内取值——标识符字符串恰好在文件其它位置出现
    /// (注释/别的键)不能算数,避免守卫假通过。
    /// - Throws: 声明块缺失,或声明块下没有任何列表项(两者都意味着配置损坏)。
    private func permittedBGTaskIdentifiers(in yml: String) throws -> [String] {
        let lines = yml.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "BGTaskSchedulerPermittedIdentifiers:"
        }) else {
            throw NSError(
                domain: "TelemetryUploaderGuard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "project.yml 缺 BGTaskSchedulerPermittedIdentifiers 声明块,BGTask 无从注册"]
            )
        }
        var identifiers: [String] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 空行与注释行跳过,继续读块内后续列表项
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // 列表项形如 `- identifier`;遇到任何非列表项行(下一个键)即块结束
            guard trimmed.hasPrefix("- ") else { break }
            let item = trimmed
                .dropFirst(2)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            identifiers.append(item)
        }
        guard !identifiers.isEmpty else {
            throw NSError(
                domain: "TelemetryUploaderGuard", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "BGTaskSchedulerPermittedIdentifiers 声明块为空,没有任何已声明标识符"]
            )
        }
        return identifiers
    }

    func testBackgroundTaskIdentifierIsAdvertisedInProjectYml() throws {
        let yml = try loadProjectYml()
        let identifiers = try permittedBGTaskIdentifiers(in: yml)
        XCTAssertTrue(
            identifiers.contains(TelemetryUploader.backgroundTaskIdentifier),
            "TelemetryUploader.backgroundTaskIdentifier(\(TelemetryUploader.backgroundTaskIdentifier)) 未在 project.yml 的 BGTaskSchedulerPermittedIdentifiers(当前声明: \(identifiers))中——BGTask 调度会 error 3,后台上报静默失效"
        )
    }
}
