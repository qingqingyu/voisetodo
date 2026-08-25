import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// `ReviewSessionStore` / `ReviewCooldownHistory` / `ReviewFlowState.buildSession`
/// 的阶段 4 验收(docs/todo-review-flow-design.md「阶段 4」):
/// 读写往返 / 旧 payload 兼容 / 容量上限 / 损坏 JSON / 冷却接真历史 /
/// 跨期对照数据源 / 账本→session 映射 / prune 用全量 id。
/// (2026-08-22 拍板:规则回访状态机与存规则链路移除,相关用例删除。)
final class ReviewSessionStoreTests: XCTestCase {

    // MARK: - 夹具

    private func session(
        id: UUID = UUID(),
        completedAt: Date = Date(),
        voiceNote: String? = nil,
        shownInsights: [InsightSnapshot] = []
    ) -> ReviewSession {
        ReviewSession(
            id: id,
            completedAt: completedAt,
            periodStart: completedAt,
            periodEnd: completedAt,
            voiceNote: voiceNote,
            ledger: ReviewLedger(
                inputCount: 1, remainingCount: 0, scheduledCount: 1, todayCount: 0,
                abandonedCount: 0, splitCount: 0, pinnedCount: 0
            ),
            shownInsights: shownInsights
        )
    }

    private func snapshot(
        _ id: InsightID = .rotting,
        effectSize: Double = 0.5,
        strength: InsightStrength = .medium
    ) -> InsightSnapshot {
        InsightSnapshot(id: id, effectSize: effectSize, strength: strength)
    }

    // MARK: - 读写往返

    func testAppendThenLastSessionAndOrdering() {
        let store = makeStore()
        let older = session(completedAt: Date(timeIntervalSinceNow: -86_400))
        let newer = session(completedAt: Date())

        store.append(older)
        store.append(newer)

        XCTAssertEqual(store.lastSession()?.id, newer.id)
        XCTAssertEqual(store.allSessions().map(\.id), [older.id, newer.id])
    }

    func testAppendUnsortedInputNormalizesToAscending() {
        let store = makeStore()
        // 先 append 新的再 append 旧的:读取仍按 completedAt 升序。
        store.append(session(completedAt: Date(timeIntervalSinceNow: 100)))
        store.append(session(completedAt: Date(timeIntervalSinceNow: -100)))

        let sessions = store.allSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertLessThan(sessions[0].completedAt, sessions[1].completedAt)
    }

    func testSessionsSinceFiltersByCompletedAt() {
        let store = makeStore()
        let cutoff = Date()
        store.append(session(completedAt: cutoff.addingTimeInterval(-1)))
        store.append(session(completedAt: cutoff.addingTimeInterval(1)))

        XCTAssertEqual(store.sessions(since: cutoff).count, 1)
        XCTAssertEqual(store.allSessions().count, 2)
    }

    func testNewInstanceWithSameDefaultsSeesData() {
        let defaults = makeDefaults()
        let writer = ReviewSessionStore(defaults: defaults)
        let expected = session(voiceNote: "想把晚上留给八字 App")
        writer.append(expected)

        let reader = ReviewSessionStore(defaults: defaults)
        // 不整 struct 比较:iso8601 往返丢亚秒精度,Date 严格相等会假红。
        let loaded = reader.lastSession()
        XCTAssertEqual(loaded?.id, expected.id)
        XCTAssertEqual(loaded?.voiceNote, expected.voiceNote)
        XCTAssertEqual(loaded?.ledger, expected.ledger)
    }

    // MARK: - 容量上限

    func testAppendCapsAtCapacityKeepingMostRecent() {
        let store = makeStore()
        var expectedKeptIDs: [UUID] = []
        for index in 0...(ReviewSessionStore.capacity + 2) {
            let item = session(completedAt: Date(timeIntervalSinceNow: Double(index) * 60))
            if index >= 3 { expectedKeptIDs.append(item.id) }
            store.append(item)
        }

        XCTAssertEqual(store.allSessions().count, ReviewSessionStore.capacity)
        // 最旧的 3 条被裁掉,留下的顺序即 index 3…(capacity+2)。
        XCTAssertEqual(store.allSessions().map(\.id), expectedKeptIDs)
        XCTAssertNotNil(store.lastSession())
    }

    // MARK: - 损坏 JSON

    func testParseCorruptDataReturnsFailure() {
        let result = ReviewSessionStore.parse(Data("not-json".utf8))
        guard case .failure(.corruptedPayload(let underlying)) = result else {
            return XCTFail("损坏 JSON 应返回 .failure(.corruptedPayload)")
        }
        XCTAssertNotNil(underlying)
    }

    func testCorruptStoredJSONReadsAsEmptyHistory() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: ReviewSessionStore.sessionsKey)

        let store = ReviewSessionStore(defaults: defaults)
        XCTAssertNil(store.lastSession())
        XCTAssertEqual(store.allSessions(), [])
    }

    // MARK: - 旧 payload 前向兼容

    func testOldPayloadWithRemovedRuleFieldsDecodes() throws {
        let id = UUID()
        // 2026-08-22 之前的 payload 形状:顶层有 savedRules/followUps、ledger 有
        // savedRuleCount——这些字段随存规则链路移除,解码时应被忽略而不是报错。
        let json = """
        [{
          "id": "\(id.uuidString)",
          "completedAt": "2026-08-01T09:00:00Z",
          "periodStart": "2026-07-25T00:00:00Z",
          "periodEnd": "2026-08-01T00:00:00Z",
          "voiceNote": null,
          "savedRules": [{
            "id": "\(UUID().uuidString)",
            "insightID": "rotting",
            "text": "22 点后不排重要任务",
            "createdAt": "2026-08-01T09:00:00Z",
            "status": "working"
          }],
          "followUps": [{"ruleID": "\(UUID().uuidString)", "status": "working"}],
          "ledger": {
            "inputCount": 3, "remainingCount": 1, "scheduledCount": 1, "todayCount": 0,
            "abandonedCount": 1, "splitCount": 0, "savedRuleCount": 1, "pinnedCount": 1
          },
          "shownInsights": [{"id": "rotting", "effectSize": 0.42, "strength": {\"high\":{}}}]
        }]
        """
        let result = ReviewSessionStore.parse(Data(json.utf8))
        guard case .success(let sessions) = result else {
            return XCTFail("旧 payload 应解码成功: \(result)")
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].shownInsights.first?.id, .rotting)
        XCTAssertEqual(sessions[0].ledger.pinnedCount, 1)
    }

    // MARK: - 冷却接真历史(§2.4)

    private func cooldownInput(
        sessions: [ReviewSession],
        current: Double
    ) -> InsightEngine.CooldownInput? {
        ReviewCooldownHistory.input(
            insightID: .rotting,
            sessions: sessions,
            currentEffectSize: current,
            lowerIsBetter: true
        )
    }

    func testCooldownNoHistoryPasses() throws {
        let input = cooldownInput(sessions: [], current: 0.5)
        XCTAssertNil(input, "无历史 = 第一次展示,由调用方直接放行")
    }

    func testCooldownShownLastSessionWithoutRuleOrChangeSuppresses() throws {
        // 上次刚展示过(距上次 0 次复盘)、效应量变化 8%、没存规则 → 冷却。
        let sessions = [session(completedAt: Date(), shownInsights: [snapshot(effectSize: 0.5)])]
        let input = try XCTUnwrap(cooldownInput(sessions: sessions, current: 0.46))
        guard case .failure(.cooldownActive) = InsightEngine.cooldown(input) else {
            return XCTFail("应处于冷却中")
        }
    }

    func testCooldownThreeSessionsSinceLastShownPasses() throws {
        // 三个会话都没展示 rotting,第三个之后(距上次 3 次)放行 intervalElapsed。
        var sessions: [ReviewSession] = []
        for index in 0..<4 {
            let shown: [InsightSnapshot] = index == 0 ? [snapshot(effectSize: 0.5)] : []
            sessions.append(session(completedAt: Date(timeIntervalSinceNow: Double(4 - index) * 86_400), shownInsights: shown))
        }
        let input = try XCTUnwrap(cooldownInput(sessions: sessions, current: 0.52))
        XCTAssertEqual(input.reviewsSinceLastShown, 3)
        XCTAssertEqual(InsightEngine.cooldown(input), .success(.intervalElapsed))
    }

    func testCooldownEffectSizeChangeAtLeast15PercentPasses() throws {
        // 0.50 → 0.42 相对变化 16%(lowerIsBetter:效应量降了 = 变好):放行 + improving。
        let sessions = [session(completedAt: Date(), shownInsights: [snapshot(effectSize: 0.50)])]
        let input = try XCTUnwrap(cooldownInput(sessions: sessions, current: 0.42))
        XCTAssertEqual(InsightEngine.cooldown(input), .success(.effectChanged(improved: true)))
    }

    func testCooldownEffectSizeWorsenedStillPassesButNotImproved() throws {
        // 变坏也算「变化」,放行但 improved = false(lowerIsBetter:效应量升了)。
        let sessions = [session(completedAt: Date(), shownInsights: [snapshot(effectSize: 0.40)])]
        let input = try XCTUnwrap(cooldownInput(sessions: sessions, current: 0.60))
        XCTAssertEqual(InsightEngine.cooldown(input), .success(.effectChanged(improved: false)))
    }

    func testCooldownOtherInsightsHistoryDoesNotInterfere() throws {
        // 上次展示的是别的洞察(reactiveVsPlanned),对 rotting 而言等于没有历史。
        let sessions = [session(completedAt: Date(), shownInsights: [snapshot(.reactiveVsPlanned, effectSize: 0.5)])]
        let input = cooldownInput(sessions: sessions, current: 0.51)
        XCTAssertNil(input, "别的洞察的展示历史不算数")
    }

    // MARK: - prune 用全量 id(不是窗口化工作集)

    func testPruneWithFullIDSetKeepsOutOfWindowPinned() {
        let defaults = makeDefaults()
        let pinning = ReviewPinningStore(defaults: defaults)
        let pinned: Set<UUID> = [UUID(), UUID()]
        pinning.setPinned(pinned)

        // 全量 id 含两个置顶 id + 窗口外任务 → 置顶全保留。
        let allIDs = pinned.union([UUID(), UUID()])
        pinning.prune(existingIDs: allIDs)
        XCTAssertEqual(pinning.pinnedIDs(), pinned)

        // 工作集窗口不含置顶 id(模拟误用窗口化集合)→ 会被误删——这正是
        // 收尾必须走 `TodoIDListing.allTodoIDs` 的原因。
        pinning.setPinned(pinned)
        pinning.prune(existingIDs: [UUID()])
        XCTAssertNotEqual(pinning.pinnedIDs(), pinned)
    }

    // MARK: - 辅助

    private func makeStore() -> ReviewSessionStore {
        ReviewSessionStore(defaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "VoiceTodoTests.ReviewSessionStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

// MARK: - 语义对照(2026-08-23 拍板,任务 #4)

final class ReviewTopicStoreTests: XCTestCase {

    private func makeStore() -> ReviewSessionStore {
        let suite = "ReviewTopicStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ReviewSessionStore(defaults: defaults)
    }

    private func session(id: UUID = UUID(), voiceNote: String? = "想把晚上留给八字 App") -> ReviewSession {
        ReviewSession(
            id: id,
            completedAt: Date(),
            periodStart: Date(),
            periodEnd: Date(),
            voiceNote: voiceNote,
            ledger: ReviewLedger(
                inputCount: 2, remainingCount: 0, scheduledCount: 1, todayCount: 1,
                abandonedCount: 0, splitCount: 0, pinnedCount: 0
            ),
            shownInsights: []
        )
    }

    /// updateTopics 按 id 原地回写;目标不存在时不崩溃、不动其他会话。
    func testUpdateTopics_replacesById() {
        let store = makeStore()
        let a = session()
        let b = session()
        store.append(a)
        store.append(b)

        let topics = [
            ReviewTopic(text: "少接会议", category: .work, timeBucket: nil, periodCount: 6),
            ReviewTopic(text: "晚上留给八字 App", category: nil, timeBucket: .evening, periodCount: 4)
        ]
        store.updateTopics(sessionID: a.id, topics: topics)

        let reloaded = store.allSessions()
        XCTAssertEqual(reloaded.first { $0.id == a.id }?.topics, topics, "按 id 回写并持久化")
        XCTAssertNil(reloaded.first { $0.id == b.id }?.topics, "其他会话不受影响")

        // 目标不存在:只记日志,不改任何数据。
        store.updateTopics(sessionID: UUID(), topics: topics)
        XCTAssertEqual(store.allSessions().count, 2)
    }

    /// 旧 payload(无 completedCount/topics 键)解码 → 新字段 nil(向后兼容)。
    func testDecodeLegacyPayload_missingNewFields_decodesNil() throws {
        let legacyJSON = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "completedAt": "2026-08-01T12:00:00Z",
          "periodStart": "2026-07-01T12:00:00Z",
          "periodEnd": "2026-08-01T12:00:00Z",
          "voiceNote": "旧的",
          "ledger": {"inputCount": 3, "remainingCount": 0, "scheduledCount": 1,
                     "todayCount": 1, "abandonedCount": 1, "splitCount": 0, "pinnedCount": 0},
          "shownInsights": []
        }]
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let result = ReviewSessionStore.parse(data)
        guard case .success(let sessions) = result else {
            return XCTFail("旧 payload 必须可解码")
        }
        XCTAssertNil(sessions.first?.completedCount)
        XCTAssertNil(sessions.first?.topics)
    }
}

/// 关注点 ↔ 本期完成事件的计数匹配(收尾与展示共用口径)。
final class ReviewTopicMatchingTests: XCTestCase {
    private let calendar = Calendar.current

    private func event(atHour hour: Int, category: TodoCategory) -> InsightCompletedEvent {
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: hour))!
        return InsightCompletedEvent(
            todoId: UUID(),
            createdAt: date,
            completedAt: date,
            category: category,
            priority: .normal,
            hasDueTime: false,
            dueDate: nil
        )
    }

    /// 分类维度:只数该分类;与时段无关。
    func testCategoryMatch() {
        let events = [
            event(atHour: 9, category: .work),
            event(atHour: 22, category: .work),
            event(atHour: 10, category: .life)
        ]
        XCTAssertEqual(
            ReviewTopicMatching.periodCount(category: .work, timeBucket: nil, in: events, calendar: calendar),
            2
        )
    }

    /// 时段维度:5–11 morning / 12–17 afternoon / 其余 evening(与 TimeBucketResolver 同界)。
    func testBucketMatch() {
        let events = [
            event(atHour: 9, category: .work),
            event(atHour: 23, category: .life),
            event(atHour: 23, category: .health),
            event(atHour: 14, category: .study)
        ]
        XCTAssertEqual(
            ReviewTopicMatching.periodCount(category: nil, timeBucket: .evening, in: events, calendar: calendar),
            2
        )
        XCTAssertEqual(
            ReviewTopicMatching.periodCount(category: nil, timeBucket: .afternoon, in: events, calendar: calendar),
            1
        )
    }

    /// 两个维度都没有 → nil(不可统计,不显示对照)。
    func testNoDimensionReturnsNil() {
        XCTAssertNil(ReviewTopicMatching.periodCount(
            category: nil, timeBucket: nil, in: [], calendar: calendar
        ))
    }
}
