import XCTest
@testable import VoiceTodoProtocols

/// 解析日期审计器(纠错器 Phase 2)测试。
///
/// 口径钉子:2026-11-01 是周日、11-04 是周三、11-08 是下周日、11-11 是下周三。
/// "下周X" = 严格晚于今天的下一个周日 + 偏移(周日=0)——产品口径(prompt 规则 4 /
/// PR#6 机械算法),**不是** ISO 周一起始;今天周日/目标周日两组用例专门钉这分叉。
final class ExtractDateAuditorTests: XCTestCase {

    // MARK: - 固定时区日历(无 DST,完全确定性)

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// 2026-11-04(周三)——与 prompt few-shot 同锚风格。
    private var wednesdayAnchor: Date { date(2026, 11, 4) }

    // MARK: - 相对日(zh / ja / en)

    func testRelativeDays_zh_agreeAndMismatch() {
        let agree = ExtractDateAuditor.audit(
            hint: "明天", modelDate: date(2026, 11, 5),
            transcript: "明天交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(agree.outcome, .agree)

        let mismatch = ExtractDateAuditor.audit(
            hint: "明天", modelDate: date(2026, 11, 8),
            transcript: "明天交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(mismatch.outcome, .mismatch)
        XCTAssertEqual(mismatch.dayDelta, -3) // 复算(11-05) − 模型(11-08)
        XCTAssertEqual(mismatch.correctedDate.map { calendar.dateComponents([.day, .month], from: $0).day }, 5)
    }

    func testRelativeDays_longestMatchDaHouTian() {
        // 大后天必须先于后天命中:11-04 锚 → 11-07(而非 11-06)
        let verdict = ExtractDateAuditor.audit(
            hint: "大后天", modelDate: date(2026, 11, 7),
            transcript: "大后天复诊", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .agree)

        let wrongModel = ExtractDateAuditor.audit(
            hint: "大后天", modelDate: date(2026, 11, 6),
            transcript: "大后天复诊", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(wrongModel.outcome, .mismatch)
        XCTAssertEqual(wrongModel.dayDelta, 1)
    }

    func testRelativeDays_jaAndEnglish() {
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "明後日", modelDate: date(2026, 11, 6),
                                     transcript: "明後日までに提出", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "day after tomorrow", modelDate: date(2026, 11, 6),
                                     transcript: "submit it day after tomorrow", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "tomorrow", modelDate: date(2026, 11, 5),
                                     transcript: "pay tomorrow", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "today", modelDate: date(2026, 11, 4),
                                     transcript: "do it today", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
    }

    // MARK: - 下周X(产品口径:周日起始,严格晚于今天的下一个周日 + 偏移)

    func testNextWeek_sundayAnchor_isNotThisWeek() {
        // 锚 2026-11-01(周日):严格晚于今天的下一个周日 = 11-08,下周三 = 11-11。
        // ISO 周一起始口径会算成 11-04(本周三)——本组用例钉产品口径与它的分叉。
        let sundayAnchor = date(2026, 11, 1)
        let agree = ExtractDateAuditor.audit(
            hint: "下周三", modelDate: date(2026, 11, 11),
            transcript: "下周三开会", anchor: sundayAnchor, calendar: calendar
        )
        XCTAssertEqual(agree.outcome, .agree)

        let isoStyleWrong = ExtractDateAuditor.audit(
            hint: "下周三", modelDate: date(2026, 11, 4),
            transcript: "下周三开会", anchor: sundayAnchor, calendar: calendar
        )
        XCTAssertEqual(isoStyleWrong.outcome, .mismatch)
        XCTAssertEqual(isoStyleWrong.dayDelta, 7)
        XCTAssertEqual(isoStyleWrong.correctedDate.map { calendar.dateComponents([.day], from: $0).day }, 11)
    }

    func testNextWeek_sundayTarget_doesNotJumpExtraWeek() {
        // 锚 2026-11-04(周三):下周日 = 11-08(严格晚于今天的下一个周日,偏移 0),
        // 不是 ISO 口径的 11-15——"下周日绝不多加 7 天"的客户端钉子。
        let agree = ExtractDateAuditor.audit(
            hint: "下周日", modelDate: date(2026, 11, 8),
            transcript: "下周日去健身", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(agree.outcome, .agree)

        let wrong = ExtractDateAuditor.audit(
            hint: "下周日", modelDate: date(2026, 11, 15),
            transcript: "下周日去健身", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(wrong.outcome, .mismatch)
        XCTAssertEqual(wrong.dayDelta, -7)
        XCTAssertEqual(wrong.correctedDate.map { calendar.dateComponents([.day], from: $0).day }, 8)
    }

    func testNextWeek_mondayFromSundayAnchor() {
        // 锚 2026-11-01(周日):下周一 = 11-09(下一个周日 11-08 + 1),不是本周一 11-02
        let verdict = ExtractDateAuditor.audit(
            hint: "下周一", modelDate: date(2026, 11, 9),
            transcript: "下周一交报告", anchor: date(2026, 11, 1), calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .agree)
    }

    func testNextWeek_aliasContainment() {
        // hint 写"下周三"、原文说"下礼拜三":同义别名命中,可信度闸门放行
        let verdict = ExtractDateAuditor.audit(
            hint: "下周三", modelDate: date(2026, 11, 11),
            transcript: "下礼拜三交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .agree)
    }

    func testNextWeek_jaAndEnglish() {
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "来週水曜日", modelDate: date(2026, 11, 11),
                                     transcript: "来週の水曜日に会議", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "next wednesday", modelDate: date(2026, 11, 11),
                                     transcript: "due next wednesday", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "next sunday", modelDate: date(2026, 11, 8),
                                     transcript: "family dinner next sunday", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
    }

    func testNextWeek_withoutWeekday_isObserved() {
        // "下周"无星期、"这周末"、裸"周三"都不在零歧义闭集 → 只观察
        for (hint, transcript) in [("下周", "下周再说"), ("这周末", "这周末大扫除"), ("周三", "周三开会")] {
            let verdict = ExtractDateAuditor.audit(
                hint: hint, modelDate: date(2026, 11, 11),
                transcript: transcript, anchor: wednesdayAnchor, calendar: calendar
            )
            XCTAssertEqual(verdict.outcome, .observed, "hint=\(hint) 应为 observed")
        }
    }

    // MARK: - 具体日期

    func testExplicitDate_cjk() {
        let agree = ExtractDateAuditor.audit(
            hint: "11月5日", modelDate: date(2026, 11, 5),
            transcript: "11月5日复查", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(agree.outcome, .agree)

        let withHao = ExtractDateAuditor.audit(
            hint: "11月5号", modelDate: date(2026, 11, 5),
            transcript: "11月5号复查", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(withHao.outcome, .agree)
    }

    func testExplicitDate_rollsToNextYear() {
        // 锚 11-04,提"7月4日" → 今年已过,顺延 2027-07-04;差值截断 ±60
        let verdict = ExtractDateAuditor.audit(
            hint: "7月4日", modelDate: date(2026, 11, 5),
            transcript: "7月4日体检", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .mismatch)
        XCTAssertEqual(verdict.dayDelta, 60) // 实际 ~241 天,截断
        XCTAssertEqual(verdict.correctedDate.map { calendar.dateComponents([.year], from: $0).year }, 2027)
    }

    func testExplicitDate_english() {
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "July 5", modelDate: date(2027, 7, 5),
                                     transcript: "checkup on july 5", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
        XCTAssertEqual(
            ExtractDateAuditor.audit(hint: "Jul 5th", modelDate: date(2027, 7, 5),
                                     transcript: "checkup jul 5th", anchor: wednesdayAnchor, calendar: calendar).outcome,
            .agree
        )
    }

    func testExplicitDate_invalidDay_isObserved() {
        // 2月30日是非法日期,不得被 Calendar 归一化成 3月2 日拿去纠错
        let verdict = ExtractDateAuditor.audit(
            hint: "2月30日", modelDate: date(2026, 11, 5),
            transcript: "2月30日前处理", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .observed)
    }

    // MARK: - 观察类与闸门

    func testMonthPartAndOffsets_areObserved() {
        for (hint, transcript) in [("月底", "月底前完成"), ("下个月5号", "下个月5号缴费"), ("三天后", "三天后取件")] {
            let verdict = ExtractDateAuditor.audit(
                hint: hint, modelDate: date(2026, 11, 30),
                transcript: transcript, anchor: wednesdayAnchor, calendar: calendar
            )
            XCTAssertEqual(verdict.outcome, .observed, "hint=\(hint) 应为 observed")
        }
    }

    func testAfterSuffix_isObserved() {
        // "下周三之后"的目标日语义(当天起?次日起?)不唯一 → 不纠
        let verdict = ExtractDateAuditor.audit(
            hint: "下周三之后", modelDate: date(2026, 11, 12),
            transcript: "下周三之后再约", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .observed)
    }

    func testHintNotInTranscript_isObserved() {
        // 模型改写过 hint(原文说"后天",hint 写"明天")→ hint 不可信,只观察
        let verdict = ExtractDateAuditor.audit(
            hint: "明天", modelDate: date(2026, 11, 6),
            transcript: "后天去健身——不对,今天就去吧", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .observed)
    }

    func testNilTranscript_isObserved() {
        let verdict = ExtractDateAuditor.audit(
            hint: "明天", modelDate: date(2026, 11, 5),
            transcript: nil, anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .observed)
    }

    func testModelDateMissing_isMissingOutcome() {
        // hint 属闭集但模型丢了 due_date(F3 类信号)→ 只记录,v1 不补造
        let verdict = ExtractDateAuditor.audit(
            hint: "明天", modelDate: nil,
            transcript: "明天交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .missing)
    }

    func testNoDateExpression() {
        // 纯钟点 hint(日期轴无可比对)与空 hint → none
        let timeOnly = ExtractDateAuditor.audit(
            hint: "下午三点", modelDate: nil,
            transcript: "下午三点提醒我", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(timeOnly.outcome, .noDateExpression)

        let empty = ExtractDateAuditor.audit(
            hint: nil, modelDate: date(2026, 11, 5),
            transcript: "交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(empty.outcome, .noDateExpression)
    }

    // MARK: - 假阳性源排除(闭集子串误吞)

    func testWeekAfterNextForms_areObserved() {
        // "下下周三"/"再来週水曜日"含子串"下周"/"来週",必须先行排除——
        // 模型按 +2 周(11-18)算对也会被误判 mismatch
        let zh = ExtractDateAuditor.audit(
            hint: "下下周三", modelDate: date(2026, 11, 18),
            transcript: "下下周三交报告", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(zh.outcome, .observed)

        let ja = ExtractDateAuditor.audit(
            hint: "再来週水曜日", modelDate: date(2026, 11, 18),
            transcript: "再来週の水曜日に会議", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(ja.outcome, .observed)
    }

    func testEitherDayForm_isObserved() {
        // "明后天"(明天或后天)含"后天"子串,或然日不比对
        let verdict = ExtractDateAuditor.audit(
            hint: "明后天", modelDate: date(2026, 11, 5),
            transcript: "明后天交房租", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .observed)
    }

    func testSuffixGuard_precedesRelativeDays() {
        // 后缀守卫必须先于相对日 token:否则这些 hint 会先命中"明天"/"大后天"/
        // "明後日"/"tomorrow"子串被按零歧义语义比对
        for (hint, transcript) in [
            ("明天以后", "明天以后再说"),
            ("大后天之后", "大后天之后复诊"),
            ("明後日以降", "明後日以降に提出"),
            ("3 days after tomorrow", "submit it 3 days after tomorrow")
        ] {
            let verdict = ExtractDateAuditor.audit(
                hint: hint, modelDate: date(2026, 11, 5),
                transcript: transcript, anchor: wednesdayAnchor, calendar: calendar
            )
            XCTAssertEqual(verdict.outcome, .observed, "hint=\(hint) 应为 observed")
        }
    }

    func testAliasGate_englishWordBoundary() {
        // 英文缩写别名必须词边界匹配:"sat"≠"satisfied"、"mar"≠"market"——
        // 子串命中会放行被改写的 hint,制造假 mismatch
        let sat = ExtractDateAuditor.audit(
            hint: "next saturday", modelDate: date(2026, 11, 7),
            transcript: "i will be satisfied next week", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(sat.outcome, .observed)

        let mar = ExtractDateAuditor.audit(
            hint: "mar 5", modelDate: date(2026, 11, 5),
            transcript: "go to the market on the 5th", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(mar.outcome, .observed)
    }

    func testTraditionalForms_areObserved_notNone() {
        // 繁体周表达不在闭集触发(週X token 未建表),但必须落到 observed
        // 而非 none(有日期表达却记"无日期表达"会失真)
        for hint in ["下週三", "下禮拜三"] {
            let verdict = ExtractDateAuditor.audit(
                hint: hint, modelDate: date(2026, 11, 11),
                transcript: "下週三開會", anchor: wednesdayAnchor, calendar: calendar
            )
            XCTAssertEqual(verdict.outcome, .observed, "hint=\(hint) 应为 observed")
        }
    }

    func testTraditionalRelativeDay_isCovered() {
        // 繁体"後天"在闭集内(aliases 本就预期了繁体)
        let verdict = ExtractDateAuditor.audit(
            hint: "後天", modelDate: date(2026, 11, 6),
            transcript: "後天去健身", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .agree)
    }

    func testAuditAndApply_missingOutcome_recordsEvent() {
        // 闭集 hint + 模型丢 due_date → missing 事件通路钉子(dayDelta/overrideApplied 不带歧义值)
        let outcome = telemetrySpy { sink in
            ExtractDateAuditor.audited(
                [ExtractedTodo(title: "交房租", dueHint: "明天", dueDateBasis: .userExplicit)],
                transcript: "明天交房租", locale: Locale(identifier: "zh-CN"),
                anchor: wednesdayAnchor, calendar: calendar, sink: sink
            )
        }
        XCTAssertEqual(outcome.events.count, 1)
        XCTAssertEqual(outcome.events[0].outcome, "missing")
        XCTAssertEqual(outcome.events[0].overrideApplied, "false")
        XCTAssertNil(outcome.events[0].dayDelta)
        // 纯观察语义:missing 不补造日期
        XCTAssertNil(outcome.todos[0].dueDate)
    }

    func testTonightVariants_andPluralWeeks_areClassified() {
        // "今夜"/"今晩"(今晚的文语/ja 变体)进相对日闭集;en 复数周是词边界
        // 单数 marker 匹配不中的形态,至少落 observed 而非 none
        XCTAssertEqual(ExtractDateAuditor.audit(
            hint: "今夜", modelDate: date(2026, 11, 4),
            transcript: "今夜中に片付ける", anchor: wednesdayAnchor, calendar: calendar
        ).outcome, .agree)
        XCTAssertEqual(ExtractDateAuditor.audit(
            hint: "in two weeks", modelDate: date(2026, 11, 18),
            transcript: "submit it in two weeks", anchor: wednesdayAnchor, calendar: calendar
        ).outcome, .observed)
    }

    func testExplicitDate_haoRiAliasCrossMatch() {
        // 模型把原话"11月5号"归一化写成 hint"11月5日":号/日互换变体须过闸门
        let verdict = ExtractDateAuditor.audit(
            hint: "11月5日", modelDate: date(2026, 11, 5),
            transcript: "11月5号复查", anchor: wednesdayAnchor, calendar: calendar
        )
        XCTAssertEqual(verdict.outcome, .agree)
    }

    // MARK: - auditAndApply(开关两档)

    private func mismatchTodo() -> ExtractedTodo {
        ExtractedTodo(
            title: "交房租",
            dueDate: date(2026, 11, 8),
            dueHint: "明天",
            dueDateBasis: .userExplicit
        )
    }

    func testAuditAndApply_observeMode_doesNotMutate() {
        let outcome = telemetrySpy { sink in
            ExtractDateAuditor.audited(
                [mismatchTodo()], transcript: "明天交房租", locale: Locale(identifier: "zh-CN"),
                anchor: wednesdayAnchor, calendar: calendar,
                overrideEnabled: false, sink: sink
            )
        }
        // 纯观察:返回值与输入一致(dueDate 原样 11-08)
        XCTAssertEqual(outcome.todos[0].dueDate.map { calendar.dateComponents([.day], from: $0).day }, 8)
        // 遥测照记:一条 mismatch,overrideApplied=false
        XCTAssertEqual(outcome.events.count, 1)
        XCTAssertEqual(outcome.events[0].outcome, "mismatch")
        XCTAssertEqual(outcome.events[0].dayDelta, "-3")
        XCTAssertEqual(outcome.events[0].overrideApplied, "false")
        XCTAssertEqual(outcome.events[0].locale, "zh")
    }

    func testAuditAndApply_overrideMode_correctsClosedSet() {
        let input = [
            mismatchTodo(),
            ExtractedTodo(title: "已对齐", dueDate: date(2026, 11, 5), dueHint: "明天", dueDateBasis: .userExplicit),
            ExtractedTodo(title: "闭集外", dueDate: date(2026, 11, 30), dueHint: "月底", dueDateBasis: .userExplicit)
        ]
        let outcome = telemetrySpy { sink in
            ExtractDateAuditor.audited(
                input, transcript: "明天交房租,月底前再检查", locale: Locale(identifier: "zh-CN"),
                anchor: wednesdayAnchor, calendar: calendar,
                overrideEnabled: true, sink: sink
            )
        }
        XCTAssertEqual(outcome.events.count, 3)
        // mismatch 条被覆盖为复算值 11-05;agree/observed 条原样
        XCTAssertEqual(outcome.todos[0].dueDate.map { calendar.dateComponents([.day], from: $0).day }, 5)
        XCTAssertEqual(outcome.todos[1].dueDate.map { calendar.dateComponents([.day], from: $0).day }, 5)
        XCTAssertEqual(outcome.todos[2].dueDate.map { calendar.dateComponents([.day], from: $0).day }, 30)
        // dueHint 保留(用户仍能看到 AI 原始判断)
        XCTAssertEqual(outcome.todos[0].dueHint, "明天")
        // overrideApplied 只有 mismatch 条为 true
        XCTAssertTrue(outcome.events.contains { $0.outcome == "mismatch" && $0.overrideApplied == "true" })
        XCTAssertTrue(outcome.events.contains { $0.outcome == "agree" && $0.overrideApplied == "false" })
        XCTAssertTrue(outcome.events.contains { $0.outcome == "observed" && $0.overrideApplied == "false" })
    }

    func testAuditAndApply_emptyTodos_noEvents() {
        let outcome = telemetrySpy { sink in
            ExtractDateAuditor.audited(
                [], transcript: "嗯", locale: Locale(identifier: "zh-CN"),
                anchor: wednesdayAnchor, calendar: calendar, sink: sink
            )
        }
        XCTAssertTrue(outcome.events.isEmpty)
        XCTAssertTrue(outcome.todos.isEmpty)
    }

    func testDefaultConfig_isObserveMode() {
        // 保守起步的钉子:默认开关必须关(纯观察上线)
        XCTAssertFalse(ExtractDateAuditorConfig.overrideEnabled)
    }

    // MARK: - 遥测捕获

    private struct CapturedEvent {
        let outcome: String
        let dayDelta: String?
        let overrideApplied: String
        let locale: String
    }

    private func telemetrySpy(_ body: ((TelemetryEvent) -> Void) -> [ExtractedTodo])
        -> (todos: [ExtractedTodo], events: [CapturedEvent]) {
        var captured: [CapturedEvent] = []
        let todos = body { event in
            guard case let .parseDateAudit(locale, outcome, _, _, dayDelta, overrideApplied) = event else { return }
            captured.append(CapturedEvent(
                outcome: outcome,
                dayDelta: dayDelta.map(String.init),
                overrideApplied: String(overrideApplied),
                locale: locale
            ))
        }
        return (todos, captured)
    }
}
