import Foundation

// MARK: - 快照与账本(阶段 4,docs/todo-review-flow-design.md「阶段 4」)

/// 一条洞察在第 3 步展示时的快照——冷却判定(§2.4)比较的就是历史会话里的
/// `effectSize`。不存 headline/body 等展示文案(每期文案会随样本重算,存了也过期)。
struct InsightSnapshot: Codable, Sendable, Equatable {
    let id: InsightID
    /// 展示当期的归一化效应量。
    let effectSize: Double
    /// 当期的信号强度标签。
    let strength: InsightStrength
}

/// 收尾账本的持久化形状(第 5 步渲染数字的落盘版,对应 `ReviewFlowState.ledger`)。
struct ReviewLedger: Codable, Sendable, Equatable {
    /// 流程开始时的待处理一次性任务数(N)。
    let inputCount: Int
    /// 处理后仍留在卡堆的(M)。
    let remainingCount: Int
    /// 排进下周。
    let scheduledCount: Int
    /// 今天就做。
    let todayCount: Int
    /// 划掉。
    let abandonedCount: Int
    /// 拆小。
    let splitCount: Int
    /// 下周三件事置顶数。
    let pinnedCount: Int
}

/// 一次完整复盘会话(阶段 4)。App Group UserDefaults + JSON 持久化,**不进 SwiftData**
/// (一年约 52 条,动 `VoiceTodoSchema` 会连累 Widget 只读容器,不值)。
/// 2026-08-22 拍板:规则回访(followUps + 历史规则状态改写)整体移除——v1 只存档
/// 不驱动下游;旧 payload 里的 `followUps` / 规则 `status` 键解码时自然忽略。
struct ReviewSession: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    /// 会话收尾时刻。
    let completedAt: Date
    /// 本期洞察原料的取数区间(`ReviewFlowView.loadInsightContext` 用的 start/end)。
    let periodStart: Date
    let periodEnd: Date
    /// 第 3 步「问问自己」的回答(空输入存 nil)。
    let voiceNote: String?
    /// 账本。
    let ledger: ReviewLedger
    /// 第 3 步展示过的洞察快照(冷却判定用)。未到洞察步(降级跳过)时为空数组。
    let shownInsights: [InsightSnapshot]

    init(
        id: UUID = UUID(),
        completedAt: Date,
        periodStart: Date,
        periodEnd: Date,
        voiceNote: String?,
        ledger: ReviewLedger,
        shownInsights: [InsightSnapshot]
    ) {
        self.id = id
        self.completedAt = completedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.voiceNote = voiceNote
        self.ledger = ledger
        self.shownInsights = shownInsights
    }
}

// MARK: - 冷却历史取数(纯函数,单测友好)

/// 从历史会话(按 completedAt 升序)为某条洞察取冷却输入(§2.4)。
enum ReviewCooldownHistory {
    static func input(
        insightID: InsightID,
        sessions: [ReviewSession],
        currentEffectSize: Double,
        lowerIsBetter: Bool
    ) -> InsightEngine.CooldownInput? {
        // 倒序找最近一次展示该洞察的会话
        guard let lastIndex = sessions.lastIndex(where: { session in
            session.shownInsights.contains { $0.id == insightID }
        }) else { return nil }

        let lastSession = sessions[lastIndex]
        guard let snapshot = lastSession.shownInsights.first(where: { $0.id == insightID }) else {
            return nil // contains 为真的前提下不会走到;防御式返回 nil
        }
        return InsightEngine.CooldownInput(
            reviewsSinceLastShown: sessions.count - 1 - lastIndex,
            lastEffectSize: snapshot.effectSize,
            currentEffectSize: currentEffectSize,
            lowerIsBetter: lowerIsBetter
        )
    }
}

// MARK: - 存储

/// 复盘会话存储(App Group UserDefaults + JSON,与 `PersonalGlossaryStore` /
/// `CorrectionTracker` / `ReviewPinningStore` 同范式)。线程安全(NSLock)。
///
/// - **不进 SwiftData**(文档阶段 4 明确):一年 ~52 条,动 schema 连累 Widget 只读容器。
/// - 容量上限 `capacity = 52`(一年每周一次),append 时按 `completedAt` 裁掉最旧的。
/// - decode 失败显式处理:记 error 日志后按空历史处理(复盘历史是增强,损坏不该
///   阻塞复盘流程;但**不静默**——日志留痕,`parse` 以 Result 暴露给单测断言)。
final class ReviewSessionStore {
    static let shared = ReviewSessionStore()
    static let sessionsKey = "VoiceTodoReviewSessions"
    /// 容量上限:一年 ~52 次周复盘。
    static let capacity = 52

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)) {
        self.defaults = defaults
    }

    // MARK: 读取

    /// 最近一次完成的会话(复盘流程第 1 步 ReviewStepRecap「上次复盘」行的
    /// 数据源——`ReviewFlowView` 传的 lastReviewDate 即 `previousSessions.last?.completedAt`)。无历史返回 nil。
    func lastSession() -> ReviewSession? {
        allSessions().last
    }

    /// 全量会话,按 `completedAt` 升序(冷却 / 跨期对照的数据源)。
    func allSessions() -> [ReviewSession] {
        guard let defaults else { return [] }
        return lock.withLock { Self.load(from: defaults) }
    }

    /// `completedAt >= since` 的会话,升序。
    func sessions(since: Date) -> [ReviewSession] {
        allSessions().filter { $0.completedAt >= since }
    }

    // MARK: 写入

    /// 收尾落库:追加一条会话并按容量裁剪(保留最近 `capacity` 条)。
    /// defaults 不可用时打 warning 显式记录,不静默假装成功。
    func append(_ session: ReviewSession) {
        guard let defaults else {
            VoiceTodoLog.app.warning("review_session.append.failed reason=defaults_unavailable")
            return
        }
        lock.withLock {
            var sessions = Self.load(from: defaults)
            sessions.append(session)
            // 升序排 + 裁容量:UserDefaults 里的顺序不保证,落盘前归一。
            sessions.sort { $0.completedAt < $1.completedAt }
            if sessions.count > Self.capacity {
                sessions.removeFirst(sessions.count - Self.capacity)
            }
            Self.save(sessions, to: defaults)
        }
        VoiceTodoLog.app.info("review_session.append.success insights=\(session.shownInsights.count)")
    }

    // MARK: 存取实现

    /// 解析 payloads。独立成 static Result 形态供单测直接断言损坏 JSON 行为。
    static func parse(_ data: Data) -> Result<[ReviewSession], ReviewSessionStoreError> {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .success(try decoder.decode([ReviewSession].self, from: data))
        } catch {
            return .failure(.corruptedPayload(underlying: error))
        }
    }

    private static func load(from defaults: UserDefaults) -> [ReviewSession] {
        guard let data = defaults.data(forKey: sessionsKey) else { return [] }
        switch parse(data) {
        case .success(let sessions):
            return sessions.sorted { $0.completedAt < $1.completedAt }
        case .failure(let error):
            // 脏数据:显式记 error 日志后按空历史处理(见类注释的取舍)。
            VoiceTodoLog.app.error("review_session.load.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return []
        }
    }

    private static func save(_ sessions: [ReviewSession], to defaults: UserDefaults) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            defaults.set(data, forKey: sessionsKey)
        } catch {
            VoiceTodoLog.app.error("review_session.save.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }
}

/// 会话存储的解码错误。
enum ReviewSessionStoreError: Error {
    /// 存储的 JSON 解不开(损坏 / 被外部改写)。`underlying` 是 JSONDecoder 原始错误。
    case corruptedPayload(underlying: Error)
}
