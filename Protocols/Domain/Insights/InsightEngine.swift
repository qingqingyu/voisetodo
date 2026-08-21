import Foundation

// MARK: - 反 gaming 原则(docs/todo-review-flow-design.md §2.5,规格 §4)
//
// 复盘指标一旦成为分数,用户就会去优化分数而不是优化生活。本引擎因此:
//   1. 不打总分——只有单条洞察的排序分 `score`,且 `score` 只用于「哪条放前面」,
//      不暴露成任何「复盘得分」;
//   2. 不做效率评级——没有 A/B/C 用户等级,没有「你超过了上周的自己」;
//   3. 不把完成率放大成主指标——用户会少建任务、只建容易的;
//   4. 不做连续复盘 streak 奖励——复盘是自愿的,漏一次不该有惩罚感。
//
// 这四条对本文件内所有规则和辅助函数都成立;后续加规则时同样受约束。

// MARK: - 洞察标识

/// 六条洞察的稳定 ID。v1 只实现 `rotting` / `reactiveVsPlanned`(拍板 2)。
///
/// 其余四个 case 仅预留 ID,**不建规则文件**——待阶段 0 体检(01/05)、
/// 数据攒满(06)或 v2(04)再启用。case 顺序即文档编号,勿重排
/// (占位行、冷却历史、规则回访都以 rawValue 持久化)。
enum InsightID: String, CaseIterable, Sendable {
    /// 01 先易后难(待阶段 0 体检决定是否值得实现)。
    case effortOrdering
    /// 02 任务在腐烂。← v1 实现
    case rotting
    /// 03 计划 vs 救火。← v1 实现
    case reactiveVsPlanned
    /// 04 对谁失约(v2:涉及可编辑 accountability 映射)。
    case brokenPromises
    /// 05 精力窗口(待阶段 0 体检)。
    case energyWindow
    /// 06 周内衰减(待 ≥4 个完整周)。
    case weeklyDecay
}

// MARK: - 强度与展示状态

/// 洞察的信号强度标签(卡片的右上角)。三档,不做更细的评级。
enum InsightStrength: Sendable, Equatable {
    /// score ≥ 0.62,信号强。
    case high
    /// 0.35 ≤ score < 0.62,信号中。
    case medium
    /// 数据偏少(n < 1.5 × minSample)——不管 score 多高都强制标,诚实说「还不够准」。
    case lowData
}

/// 规则对一条洞察的展示判定。
enum InsightAvailability: Sendable {
    /// 触发,携带完整结果。
    case fired(InsightResult)
    /// 已实现的规则但样本未到线——**必须写清还差多少**(「还需 11 条」,
    /// 不是「数据不足」)。v1 只对已实现的 02/03 生效,未实现规则不产生占位行(拍板 2)。
    case placeholder(needMore: Int)
    /// 不显示(未触发,或降级阶梯裁掉)。不是「无异常」。
    case hidden
}

// MARK: - 结果与图数据

/// 「腐烂」卡的可视化数据:一条腐烂任务(标题/推迟数/躺了几天),
/// 携带 `todoId` 供阶段 3 点击跳回第 2 步卡片堆。
struct RottingVizItem: Sendable, Equatable {
    let todoId: UUID
    let title: String
    /// 有效推迟次数(已排除 origin == .review)。
    let deferCount: Int
    /// 从记下(now 用户日)到现在躺了几个用户日。
    let ageDays: Int
}

/// 六种图各一个 case。v1 只有 02/03 两图有数据;其余四个 case 是预留锚点,
/// 对应规则启用时再补关联值(避免为未实现洞察臆造数据形状)。
enum InsightViz: Sendable {
    /// 01 先易后难(预留,无数据)。
    case effortOrdering
    /// 02 腐烂任务列表,按推迟次数降序。
    case rotting(items: [RottingVizItem])
    /// 03 救火占比与样本量。
    case reactiveVsPlanned(ratio: Double, sampleCount: Int)
    /// 04 对谁失约(预留,无数据)。
    case brokenPromises
    /// 05 精力窗口(预留,无数据)。
    case energyWindow
    /// 06 周内衰减(预留,无数据)。
    case weeklyDecay
}

/// 用户从洞察卡「存下的规则」(v1 只存储 + 回访,不做效果逻辑)。
/// 阶段 4 的 `ReviewSession.savedRules` 持久化它。
struct ReviewRule: Sendable, Equatable, Identifiable {
    let id: UUID
    /// 规则来自哪条洞察(回访时按它配对)。
    let insightID: InsightID
    /// 规则文本,如「22 点后不排重要任务」。
    let text: String
    /// 存下的时刻。
    let createdAt: Date

    init(id: UUID = UUID(), insightID: InsightID, text: String, createdAt: Date) {
        self.id = id
        self.insightID = insightID
        self.text = text
        self.createdAt = createdAt
    }
}

/// 文案语气:普通观察 vs 好转(§2.4:效应量变好或正向信号要用好转文案——
/// 复盘只报坏消息,用户会停止复盘)。阶段 3 据此选文案与样式。
enum InsightTone: Sendable, Equatable {
    /// 普通观察(含警示)。
    case observation
    /// 好转/正向信号。
    case improving
}

/// 一条洞察的完整产出。
struct InsightResult: Sendable {
    let id: InsightID
    let strength: InsightStrength
    let tone: InsightTone
    let headline: String
    let body: String
    let viz: InsightViz
    /// v1 恒 nil(规则按钮只存储,不做效果逻辑);阶段 4 起由 UI 构造。
    let suggestedRule: ReviewRule?
    /// 样本量说明,必须写明「N 条一次性任务,不含规律任务」(§2.2)。
    let sampleNote: String
    /// 排序分 = normalizedEffect × confidence。只用于排序,不是「复盘得分」(见文件头反 gaming 注)。
    let score: Double
    /// 归一化效应量(冷却判定比较的就是它)。
    let effectSize: Double
    /// 实际样本量 n。
    let sampleCount: Int
}

// MARK: - 规则协议

/// 洞察规则:纯函数,输入 `InsightContext` 原料,输出展示判定。
/// 无 IO、无 SwiftData 依赖,`Sendable`。
protocol InsightRule: Sendable {
    var id: InsightID { get }
    /// 样本量下限。confidence 满分需要 2 × minSample。
    var minSample: Int { get }
    /// 用指定日历评估。日界口径是 `DayClock` 用户日(§2.2 对规格的偏离:
    /// 用户可配日起始小时,洞察必须跟随,否则与首页对不上)。
    /// `ctx.to` 兼作「现在」。
    func evaluate(_ ctx: InsightContext, calendar: Calendar) -> InsightAvailability
}

extension InsightRule {
    /// 便捷入口:用当前日历评估。
    func evaluate(_ ctx: InsightContext) -> InsightAvailability {
        evaluate(ctx, calendar: .current)
    }
}

// MARK: - 引擎

/// 洞察引擎:排序分 / 强度标签 / 降级阶梯 / 冷却判定的纯函数集合。
/// 规则本体在 `Rules/` 下,引擎不持有规则实例(阶段 3 的 UI 决定跑哪些)。
enum InsightEngine {
    // 阈值集中处。推导依据见 docs/todo-review-flow-design.md「验证」节内嵌用例,
    // 规格文档(voicetodoinsightspec.md)不在仓库,以下数字从验收用例反推:
    //
    // - 强度线:score ≥ 0.62 强 / 0.35 ≤ score < 0.62 中 / n < 1.5 × minSample 强制 lowData
    //   ——文档 §2.1 原文给定。
    // - confidence 满分线 2 × minSample——文档 §2.1 原文给定
    //   (防「3 条数据看出惊天规律」的主要机制)。

    /// confidence = min(1.0, n / (2 × minSample))。刚过样本线的洞察自动排后面。
    /// minSample 是规则侧编译期常量,传 0 是编程错误——直接炸,不静默兜底。
    static func confidence(sampleCount: Int, minSample: Int) -> Double {
        precondition(minSample > 0, "minSample must be > 0 (rule-side constant)")
        return min(1.0, Double(sampleCount) / Double(2 * minSample))
    }

    /// score = normalizedEffect × confidence。normalizedEffect 由各规则自己归一。
    static func score(normalizedEffect: Double, sampleCount: Int, minSample: Int) -> Double {
        let clamped = min(max(normalizedEffect, 0), 1)
        return clamped * confidence(sampleCount: sampleCount, minSample: minSample)
    }

    /// 强度标签。lowData 是一票否决:样本不够时不管 score 多高都标「数据偏少」。
    static func strength(score: Double, sampleCount: Int, minSample: Int) -> InsightStrength {
        if sampleCount < Int((Double(minSample) * 1.5).rounded(.up)) {
            return .lowData
        }
        if score >= 0.62 { return .high }
        // score < 0.62 且样本足够:归 medium——不到 0.35 线但已触发,不该比「中」更弱
        return .medium
    }

    /// 把触发的洞察按 score 降序排(稳定排序,同分保持传入顺序)。
    static func rank(_ results: [InsightResult]) -> [InsightResult] {
        results.sorted { lhs, rhs in lhs.score > rhs.score }
    }

    // MARK: 降级阶梯(§2.3)

    /// 第 3 步(观察步)按完成记录数的降级阶梯。v1 只有 02/03(拍板 2),
    /// 未实现的 01/04/05/06 **不**产生占位行。
    enum Ladder: Sendable, Equatable {
        /// 完成记录 < 5:整个第 3 步跳过,第 2 步直连第 4 步。
        case skipStep
        /// 5–14:只跑洞察 02;`needMore` = 距离 03 启用还差几条(占位文案「再记 N 条」)。
        case rottingOnly(needMore: Int)
        /// ≥ 15:02 + 03 齐跑,未达阈值的不显示。
        case full
    }

    /// 降级阶梯判定。边界含义:<5 跳过整步;5–14 只有 02;≥15 跑 02+03。
    /// 5 与 15 来自文档 §2.3 表格原文。
    static func ladder(completedRecordCount: Int) -> Ladder {
        if completedRecordCount < 5 { return .skipStep }
        if completedRecordCount < 15 { return .rottingOnly(needMore: 15 - completedRecordCount) }
        return .full
    }

    // MARK: 冷却(§2.4;阶段 4 接历史数据,本层只做纯判定)

    /// 冷却判定的输入(全部由调用方从 `ReviewSession.shownInsights` 历史取)。
    struct CooldownInput: Sendable {
        /// 距上次展示过了几次复盘。
        let reviewsSinceLastShown: Int
        /// 上次展示时的效应量(`InsightSnapshot.effectSize`)。
        let lastEffectSize: Double
        /// 本期效应量。
        let currentEffectSize: Double
        /// 该洞察的效应量是否「越小越好」(02 腐烂占比、03 救火占比都是 true)。
        let lowerIsBetter: Bool
        /// 用户上次为这条洞察存了规则(要回访规则有没有生效)。
        let userSavedRuleLastTime: Bool
    }

    /// 重复展示的原因——决定阶段 3 用哪套文案(effectChanged(improved: true) 用好转文案)。
    enum CooldownShowReason: Sendable, Equatable {
        /// 距上次 ≥ 3 次复盘。
        case intervalElapsed
        /// 效应量相对变化 ≥ 15%。`improved` = 变好(变好也算,但要用好转文案)。
        case effectChanged(improved: Bool)
        /// 用户上次存了规则,回来问「这条生效了吗」。
        case ruleFollowUp
    }

    /// 冷却判定:同一条洞察重复展示需满足任一——
    /// 距上次 ≥ 3 次复盘 / 效应量相对变化 ≥ 15%(变好也算)/ 上次存了规则。
    static func cooldown(_ input: CooldownInput) -> Result<CooldownShowReason, CooldownSuppressed> {
        if input.userSavedRuleLastTime { return .success(.ruleFollowUp) }
        let last = abs(input.lastEffectSize)
        if last > 0 {
            let relative = abs(input.currentEffectSize - input.lastEffectSize) / last
            if relative >= 0.15 {
                let improved = input.lowerIsBetter
                    ? input.currentEffectSize < input.lastEffectSize
                    : input.currentEffectSize > input.lastEffectSize
                return .success(.effectChanged(improved: improved))
            }
        }
        if input.reviewsSinceLastShown >= 3 { return .success(.intervalElapsed) }
        return .failure(.cooldownActive)
    }
}

/// 冷却中(三个放行条件都不满足),本期不展示这条洞察。
enum CooldownSuppressed: Sendable, Equatable, Error {
    /// 距上次展示不足 3 次复盘、效应量变化 < 15%、且上次没存规则。
    case cooldownActive
}
