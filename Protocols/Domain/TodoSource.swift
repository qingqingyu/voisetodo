import Foundation

/// `TodoItem` 的数据来源标签,用于区分语音录入、日历事件导入、协作同步三类来源。
///
/// 这是「数据来源」维度,与「AI 提取质量」维度的 `ExtractionOutcome` 正交——
/// 后者标记 `.parsed / .rawFallback / .unparsed`(AI 看没看过 / 看出没看出结构),
/// 而 `TodoSource` 标记 todo 是怎么进来的(谁产生的)。
///
/// 第一版本使用场景:
/// - `.voice` 是默认值,覆盖语音录入 + 键盘手动输入两条路径
/// - `.calendarImport` 标记从系统日历事件导入的 todo(场景 3 的产物)
/// - `.collaboration` 预留,等多人协作上线后由同步路径写入
///
/// 撞车检测(场景 1)只对 `.voice` 的 todo 有意义——`.calendarImport` 本就是日历事件
/// 的镜像,再做 overlap 检测会循环。
enum TodoSource: String, Codable, CaseIterable, Sendable {
    /// 语音录入或键盘手动输入。第一版本的默认值,旧数据轻量迁移时也补这个值。
    case voice
    /// 从系统日历事件导入。由 `SystemCalendarEventImporter` 转换时显式 stamp。
    case calendarImport
    /// 多人协作同步来源。预留值,第一版本不写入——等协作上线后由同步路径使用。
    case collaboration
}
