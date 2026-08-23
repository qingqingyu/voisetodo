import Foundation

/// 任务拆小协议(2026-08-23 拆小改版)。
///
/// 两种输入形态、同一条链路(AI 代理的 `mode=split`,复用 provider failover):
/// 1. 一件拖着没做的模糊任务标题 → 拆成 2-4 条可启动的步骤(「拆小」sheet 的候选)
/// 2. 用户口述的一段话(说了好几件事)→ 按内容切分(sheet 内「说一句」的解析)
///
/// 拍板口径(2026-08-23):
/// - **不计费额度**——拆小是低频辅助动作,不占每日提取额度(代理侧 quotaState 置空);
/// - 失败/离线由调用方降级为手动输入(sheet 的「自己写一条」路径),不走熔断器
///   (与主提取链路独立:拆小失败不代表提取不健康)。
protocol TodoSplitterProtocol {
    /// - Parameters:
    ///   - input: 任务标题,或用户说的一整段话
    ///   - locale: 内容语言(选择匹配的 split prompt)
    ///   - wantsAlternative: true = 「换一批」——要求与上次不同角度的拆法
    /// - Returns: 拆好的步骤标题(2-4 条)。解析出空数组视为失败,实现方抛错而非返回空。
    func splitSteps(for input: String, locale: Locale, wantsAlternative: Bool) async throws -> [String]
}
