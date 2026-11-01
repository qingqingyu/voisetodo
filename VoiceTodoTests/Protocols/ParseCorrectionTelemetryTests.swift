import XCTest
import Foundation
#if canImport(VoiceTodoProtocols)
@testable import VoiceTodoProtocols
#else
@testable import VoiceTodo
#endif

/// 解析准确率埋点(任务书 docs/task-parse-correction-telemetry.md §6):
/// 分类函数、对比纯函数、after_save 判定/去重、PII 金丝雀。
final class ParseCorrectionTelemetryTests: XCTestCase {

    // MARK: - 固定时区日历(测试确定性,避开本机时区/DST 差异)

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var utc: Calendar { Self.utc }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        Self.date(year, month, day, hour: hour, minute: minute)
    }

    private func todo(
        id: UUID = UUID(),
        title: String = "标题",
        dueDate: Date? = nil,
        dueHint: String? = nil,
        dueTime: String? = nil,
        recurrenceRule: RecurrenceRule? = nil,
        categoryHint: TodoCategory = .other,
        dueDateBasis: DueDateBasis? = nil
    ) -> ExtractedTodo {
        ExtractedTodo(
            id: id,
            title: title,
            detail: "",
            dueDate: dueDate,
            dueHint: dueHint,
            dueTime: dueTime,
            recurrenceRule: recurrenceRule,
            categoryHint: categoryHint,
            dueDateBasis: dueDateBasis
        )
    }

    // MARK: - 1. 分类函数(§6.1:中英日各类型至少 2 个例子 + none/other/首中优先)

    private func classify(_ hint: String?, hasDate: Bool = true, hasTime: Bool = false) -> ParseExpressionKind {
        ParseExpressionClassifier.classify(dueHint: hint, hasDate: hasDate, hasTime: hasTime, locale: Locale(identifier: "zh-CN"))
    }

    func testClassifyRelativeDay() {
        XCTAssertEqual(classify("明天"), .relativeDay)
        XCTAssertEqual(classify("后天"), .relativeDay)
        XCTAssertEqual(classify("tonight"), .relativeDay)
        XCTAssertEqual(classify("tomorrow"), .relativeDay)
        XCTAssertEqual(classify("明日"), .relativeDay)
        XCTAssertEqual(classify("明後日"), .relativeDay)
    }

    func testClassifyWeekday() {
        XCTAssertEqual(classify("周五"), .weekday)
        XCTAssertEqual(classify("下周三"), .weekday)
        XCTAssertEqual(classify("本周"), .weekday)
        XCTAssertEqual(classify("next Friday"), .weekday)
        XCTAssertEqual(classify("wednesday"), .weekday)
        XCTAssertEqual(classify("来週の水曜日"), .weekday)
        XCTAssertEqual(classify("金曜"), .weekday)
    }

    func testClassifyMonthPart() {
        XCTAssertEqual(classify("月中"), .monthPart)
        XCTAssertEqual(classify("月底前"), .monthPart)
        XCTAssertEqual(classify("mid-month"), .monthPart)
        XCTAssertEqual(classify("月末"), .monthPart)
        XCTAssertEqual(classify("月半ば"), .monthPart)
    }

    func testClassifyRelativeOffset() {
        XCTAssertEqual(classify("三天后"), .relativeOffset)
        XCTAssertEqual(classify("两周后"), .relativeOffset, "「两周后」的周不是星期,负向约束必须生效")
        XCTAssertEqual(classify("in 3 days"), .relativeOffset)
        XCTAssertEqual(classify("1ヶ月後"), .relativeOffset)
        XCTAssertEqual(classify("3日後"), .relativeOffset)
    }

    func testClassifyAbsoluteDate() {
        XCTAssertEqual(classify("11月5号"), .absoluteDate)
        XCTAssertEqual(classify("11月5日"), .absoluteDate)
        XCTAssertEqual(classify("Nov 5"), .absoluteDate)
        XCTAssertEqual(classify("12/25"), .absoluteDate)
    }

    func testClassifyHoliday() {
        XCTAssertEqual(classify("国庆"), .holiday)
        XCTAssertEqual(classify("春节前回家"), .holiday)
        XCTAssertEqual(classify("Christmas"), .holiday)
        XCTAssertEqual(classify("正月"), .holiday)
    }

    func testClassifyTimeOnly() {
        XCTAssertEqual(classify("下午三点", hasDate: false), .timeOnly)
        XCTAssertEqual(classify("at 3pm", hasDate: false), .timeOnly)
        XCTAssertEqual(classify("午後3時", hasDate: false), .timeOnly)
        // 只有钟点字段、无短语无日期 → time_only
        XCTAssertEqual(classify(nil, hasDate: false, hasTime: true), .timeOnly)
    }

    func testClassifyNoneAndOther() {
        XCTAssertEqual(classify(nil, hasDate: false, hasTime: false), .none)
        // 有日期但无短语:没有说法可归类
        XCTAssertEqual(classify(nil, hasDate: true, hasTime: false), .other)
        XCTAssertEqual(classify("到时候再说吧"), .other)
    }

    func testClassifyFirstMatchWinsByTableOrder() {
        // 「下周五下午三点」:weekday 与 time_only 同时命中 → 取表序靠前的 weekday
        XCTAssertEqual(classify("下周五下午三点"), .weekday)
        // 「明天下午」:relative_day 优先
        XCTAssertEqual(classify("明天下午"), .relativeDay)
        // 「11月5号的周末」…日期与星期并存不在常见口语里,这里验证绝对日期优先于节日
        XCTAssertEqual(classify("11月5号"), .absoluteDate)
    }

    // MARK: - 2. 对比逻辑(§6.2:纯函数,喂原始/确认两组 ExtractedTodo)

    func testConfirmSheetNoChange() {
        let id = UUID()
        let original = todo(id: id, title: "买牛奶", dueDate: date(2026, 11, 6), dueHint: "明天", dueTime: "15:00")
        let confirmed = todo(id: id, title: "买牛奶", dueDate: date(2026, 11, 6), dueHint: "明天", dueTime: "15:00")
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)

        XCTAssertEqual(diff.extracted, 1)
        XCTAssertEqual(diff.kept, 1)
        XCTAssertEqual(diff.dropped, 0)
        XCTAssertEqual(diff.edited, 0)
        XCTAssertEqual(diff.dateEdited, 0)
        XCTAssertEqual(diff.timeEdited, 0)
        XCTAssertEqual(diff.titleEdited, 0)
        XCTAssertTrue(diff.fieldCorrections.isEmpty)
    }

    func testConfirmSheetDayDeltaForwardOneAndBackSeven() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 11, 30), dueHint: "11月30号")
        let plusOne = todo(id: id, dueDate: date(2026, 12, 1))
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [plusOne], calendar: utc)
        XCTAssertEqual(diff.dateEdited, 1)
        XCTAssertEqual(diff.fieldCorrections.count, 1)
        XCTAssertEqual(diff.fieldCorrections[0].field, .date)
        XCTAssertEqual(diff.fieldCorrections[0].change, .changed)
        XCTAssertEqual(diff.fieldCorrections[0].dayDelta, 1, "跨月 +1 天")
        XCTAssertEqual(diff.fieldCorrections[0].expressionKind, .absoluteDate)

        let minusSeven = todo(id: id, dueDate: date(2026, 11, 23))
        let backDiff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [minusSeven], calendar: utc)
        XCTAssertEqual(backDiff.fieldCorrections[0].dayDelta, -7)
    }

    func testConfirmSheetDayDeltaCrossYear() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 12, 31))
        let confirmed = todo(id: id, dueDate: date(2027, 1, 1))
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.fieldCorrections[0].dayDelta, 1, "跨年 +1 天")
    }

    func testConfirmSheetDayDeltaClampedTo60() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 1, 1))
        let confirmed = todo(id: id, dueDate: date(2026, 10, 1))
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.fieldCorrections[0].dayDelta, 60, "差 273 天截断到 +60")
    }

    func testConfirmSheetDateAddedAndRemoved() {
        let id = UUID()
        let noDate = todo(id: id, title: "打电话", dueHint: nil)
        let withDate = todo(id: id, dueDate: date(2026, 11, 7))
        let added = ParseCorrectionDiff.confirmSheet(originals: [noDate], confirmed: [withDate], calendar: utc)
        XCTAssertEqual(added.fieldCorrections[0].field, .date)
        XCTAssertEqual(added.fieldCorrections[0].change, .added)
        XCTAssertNil(added.fieldCorrections[0].dayDelta)
        XCTAssertEqual(added.fieldCorrections[0].expressionKind, .none, "原始无日期 → none")

        let removed = ParseCorrectionDiff.confirmSheet(originals: [withDate], confirmed: [noDate], calendar: utc)
        XCTAssertEqual(removed.fieldCorrections[0].change, .removed)
    }

    func testConfirmSheetTimeOnlyChangeMinuteDelta() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 11, 6), dueHint: "明天", dueTime: "09:30")
        let confirmed = todo(id: id, dueDate: date(2026, 11, 6), dueHint: "明天", dueTime: "11:00")
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.dateEdited, 0)
        XCTAssertEqual(diff.timeEdited, 1)
        XCTAssertEqual(diff.fieldCorrections[0].field, .time)
        XCTAssertEqual(diff.fieldCorrections[0].change, .changed)
        XCTAssertEqual(diff.fieldCorrections[0].minuteDelta, 90)
        XCTAssertEqual(diff.fieldCorrections[0].dayDelta, nil)
    }

    func testConfirmSheetDroppedNotInFieldStats() {
        let keptID = UUID(), droppedID = UUID()
        let originals = [
            todo(id: keptID, title: "买牛奶"),
            todo(id: droppedID, title: "遛狗", dueDate: date(2026, 11, 6), dueTime: "18:00"),
        ]
        let confirmed = [todo(id: keptID, title: "买牛奶")]
        let diff = ParseCorrectionDiff.confirmSheet(originals: originals, confirmed: [confirmed[0]], calendar: utc)

        XCTAssertEqual(diff.extracted, 2)
        XCTAssertEqual(diff.dropped, 1)
        XCTAssertEqual(diff.kept, 1)
        XCTAssertEqual(diff.dateEdited, 0)
        XCTAssertEqual(diff.timeEdited, 0)
        XCTAssertTrue(diff.fieldCorrections.isEmpty, "删掉的条目不进字段统计")
        XCTAssertEqual(diff.keptKinds[.none], 1)
        XCTAssertNil(diff.keptKinds[.relativeDay], "被删条目的说法不进 kinds 分母")
    }

    func testConfirmSheetAddedCountedSeparately() {
        let originalID = UUID(), newID = UUID()
        let originals = [todo(id: originalID, title: "买牛奶")]
        let confirmed = [todo(id: originalID, title: "买牛奶"), todo(id: newID, title: "新加的")]
        let diff = ParseCorrectionDiff.confirmSheet(originals: originals, confirmed: confirmed, calendar: utc)
        XCTAssertEqual(diff.extracted, 1)
        XCTAssertEqual(diff.kept, 1)
        XCTAssertEqual(diff.added, 1, "手动新增不计入 extracted/kept/edited")
        XCTAssertEqual(diff.edited, 0)
    }

    func testConfirmSheetTitleWhitespaceOnlyNotEdited() {
        let id = UUID()
        let original = todo(id: id, title: "买牛奶")
        var confirmed = todo(id: id, title: "  买牛奶 \n")
        // ExtractedTodo.init 会截断标题,这里直接改 var 验证「去首尾空白后比较」
        confirmed.title = " 买牛奶 "
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.titleEdited, 0)
        XCTAssertEqual(diff.edited, 0)
    }

    func testConfirmSheetReminderEmptyArrayVersusNilNotEdited() {
        let id = UUID()
        var original = todo(id: id)
        var confirmed = todo(id: id)
        original.reminderTimes = nil
        confirmed.reminderTimes = []
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.reminderEdited, 0, "空数组与 nil 不得误报为修改")

        // 顺序不同也不算改
        original.reminderTimes = ["15:00", "17:00"]
        confirmed.reminderTimes = ["17:00", "15:00"]
        let reordered = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(reordered.reminderEdited, 0)

        // 提前量变化算改
        var withOffset = confirmed
        withOffset.reminderOffsetMinutes = 30
        let offsetChanged = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [withOffset], calendar: utc)
        XCTAssertEqual(offsetChanged.reminderEdited, 1)
    }

    func testConfirmSheetKindsEncoding() {
        let a = todo(dueHint: "下周五")
        let b = todo(dueHint: "下周五")
        let c = todo(dueHint: nil)
        let diff = ParseCorrectionDiff.confirmSheet(
            originals: [a, b, c],
            confirmed: [a, b, c],
            calendar: utc
        )
        XCTAssertEqual(diff.kindsEncoding, "{\"none\":1,\"weekday\":2}", "按枚举声明顺序稳定输出的 JSON 对象串")
    }

    func testConfirmSheetBasisCarriedFromOriginal() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 11, 6), dueHint: "明天", dueDateBasis: .userExplicit)
        let confirmed = todo(id: id, dueDate: date(2026, 11, 7))
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        XCTAssertEqual(diff.fieldCorrections[0].basis, .userExplicit)
    }

    // MARK: - 3. after_save 判定与去重(§6.3)

    private func afterSaveInput(
        todoID: UUID = UUID(),
        origin: TaskEventOrigin = .detail,
        source: TodoSource = .voice,
        outcome: ExtractionOutcome = .parsed,
        createdMinutesAgo: Double = 10,
        oldDueDate: Date? = ParseCorrectionTelemetryTests.date(2026, 11, 6),
        oldHasDueTime: Bool = true,
        oldDueHint: String? = "下周五",
        newDueDate: Date? = ParseCorrectionTelemetryTests.date(2026, 11, 13),
        newHasDueTime: Bool = true
    ) -> ParseCorrectionRecorder.AfterSaveInput {
        let now = date(2026, 11, 1, hour: 12)
        return ParseCorrectionRecorder.AfterSaveInput(
            todoID: todoID,
            origin: origin,
            source: source,
            extractionOutcome: outcome,
            createdAt: now.addingTimeInterval(-createdMinutesAgo * 60),
            localeIdentifier: "zh-Hans-CN",
            oldDueDate: oldDueDate,
            oldHasDueTime: oldHasDueTime,
            oldDueHint: oldDueHint,
            newDueDate: newDueDate,
            newHasDueTime: newHasDueTime,
            recurring: false
        )
    }

    private func makeTemporaryDefaults() throws -> UserDefaults {
        let suiteName = "VoiceTodoTests.ParseCorrection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testAfterSaveAppAndReviewOriginsNotRecorded() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        var events: [TelemetryEvent] = []
        let now = date(2026, 11, 1, hour: 12)

        for origin in [TaskEventOrigin.app, .review] {
            ParseCorrectionRecorder.recordAfterSaveIfNeeded(
                afterSaveInput(origin: origin),
                reportedSet: set,
                sink: { events.append($0) },
                now: now, calendar: utc
            )
        }
        XCTAssertTrue(events.isEmpty, "首页「移到明天」/复盘排期是改计划,不算解析纠错")
    }

    func testAfterSaveBeyond120MinutesNotRecorded() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        var events: [TelemetryEvent] = []
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            afterSaveInput(createdMinutesAgo: 121),
            reportedSet: set,
            sink: { events.append($0) },
            now: date(2026, 11, 1, hour: 12), calendar: utc
        )
        XCTAssertTrue(events.isEmpty, "超过 120 分钟不算解析纠错")

        // 恰好 120 分钟在窗口内
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            afterSaveInput(createdMinutesAgo: 120),
            reportedSet: set,
            sink: { events.append($0) },
            now: date(2026, 11, 1, hour: 12), calendar: utc
        )
        XCTAssertEqual(events.count, 1)
    }

    func testAfterSaveManualTodosNotRecorded() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        var events: [TelemetryEvent] = []
        let now = date(2026, 11, 1, hour: 12)

        // 日历导入的
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            afterSaveInput(source: .calendarImport),
            reportedSet: set, sink: { events.append($0) }, now: now, calendar: utc
        )
        // 原文兜底的手动卡片(AI 没解析过)
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            afterSaveInput(outcome: .rawFallback),
            reportedSet: set, sink: { events.append($0) }, now: now, calendar: utc
        )
        XCTAssertTrue(events.isEmpty, "非 AI 解析条目的修改不算解析纠错")
    }

    func testAfterSaveOnlyFirstChangePerFieldRecorded() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        var events: [TelemetryEvent] = []
        let now = date(2026, 11, 1, hour: 12)
        let input = afterSaveInput()

        // 第一次:日期 11-06 → 11-13(+7)
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            input, reportedSet: set, sink: { events.append($0) }, now: now, calendar: utc
        )
        // 同一条同一字段第二次改
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            input, reportedSet: set, sink: { events.append($0) }, now: now, calendar: utc
        )
        XCTAssertEqual(events.count, 1, "同一条待办同一字段只记第一次")
        XCTAssertEqual(events[0].params["dayDelta"], "7")
        XCTAssertEqual(events[0].params["stage"], "after_save")
        XCTAssertEqual(events[0].params["minutesSinceCreated"], "10")
        XCTAssertEqual(events[0].params["expressionKind"], "weekday", "下周五 → weekday")

        // 同一条待办:时间字段是另一个 key,第一次仍要记
        let timeInput = afterSaveInput(
            todoID: input.todoID,
            oldDueDate: date(2026, 11, 6, hour: 9), newDueDate: date(2026, 11, 6, hour: 10)
        )
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            timeInput, reportedSet: set, sink: { events.append($0) }, now: now, calendar: utc
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].params["minuteDelta"], "60")
    }

    func testAfterSaveTimeAddedAndRemoved() throws {
        // 原来没钟点,用户补上
        let added = ParseCorrectionDiff.afterSaveCorrections(
            oldDueDate: date(2026, 11, 6), oldHasDueTime: false,
            newDueDate: date(2026, 11, 6), newHasDueTime: true,
            oldDueHint: "明天", recurring: false, calendar: utc
        )
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].field, .time)
        XCTAssertEqual(added[0].change, .added)

        // 原来有钟点,用户删掉(清日期会连带清钟点 → date+time 两条)
        let removed = ParseCorrectionDiff.afterSaveCorrections(
            oldDueDate: date(2026, 11, 6, hour: 15), oldHasDueTime: true,
            newDueDate: nil, newHasDueTime: false,
            oldDueHint: "明天", recurring: false, calendar: utc
        )
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(Set(removed.map(\.field)), Set([ParseCorrectionField.date, ParseCorrectionField.time]))
        XCTAssertTrue(removed.allSatisfy { $0.change == .removed })
    }

    func testReportedSetExpiry() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        let id = UUID()
        let t0 = date(2026, 11, 1)

        set.mark(todoID: id, field: .date, now: t0)
        XCTAssertTrue(set.contains(todoID: id, field: .date, now: t0.addingTimeInterval(47 * 3600)), "47h < 48h 仍在集合内")
        XCTAssertFalse(set.contains(todoID: id, field: .date, now: t0.addingTimeInterval(49 * 3600)), "49h > 48h 视同未上报")
        XCTAssertFalse(set.contains(todoID: id, field: .time, now: t0), "字段维度独立")
    }

    func testReportedSetCapacityCap() throws {
        let defaults = try makeTemporaryDefaults()
        let set = ParseCorrectionReportedSet(defaults: defaults)
        let t0 = date(2026, 11, 1)

        for i in 0..<(ParseCorrectionReportedSet.maxEntries + 20) {
            set.mark(todoID: UUID(), field: .date, now: t0.addingTimeInterval(TimeInterval(i)))
        }
        let stored = defaults.dictionary(forKey: ParseCorrectionReportedSet.defaultKey)
        XCTAssertEqual(stored?.count, ParseCorrectionReportedSet.maxEntries, "上限 500,超出删最旧")
        // 最旧的 20 条被淘汰:最早的条目时间戳应 ≥ t0 + 20s
        let timestamps = stored?.values.compactMap { $0 as? Date } ?? []
        XCTAssertEqual(timestamps.min(), t0.addingTimeInterval(20))
    }

    // MARK: - 4. PII 金丝雀(§6.4:可识别字符串不得出现在编码后的事件参数里)

    func testPIICanaryNeverAppearsInEventParams() throws {
        let canaryTitle = "PII_CANARY_买牛奶标题"
        let canaryHint = "PII_CANARY_下周五下午"
        let id = UUID()
        let original = todo(id: id, title: canaryTitle, dueDate: date(2026, 11, 6), dueHint: canaryHint, dueTime: "15:00")
        let confirmed = todo(id: id, title: canaryTitle, dueDate: date(2026, 11, 7), dueTime: "16:00")
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)

        var allEvents: [TelemetryEvent] = [
            .parseConfirmed(path: "live_voice", locale: "zh", diff: diff)
        ]
        allEvents += diff.fieldCorrections.map { correction in
            TelemetryEvent.parseFieldCorrected(stage: ParseCorrectionStage.confirmSheet, locale: "zh", correction: correction, minutesSinceCreated: nil)
        }
        // after_save 事件同样过一遍金丝雀
        let defaults = try makeTemporaryDefaults()
        ParseCorrectionRecorder.recordAfterSaveIfNeeded(
            ParseCorrectionRecorder.AfterSaveInput(
                todoID: id, origin: .detail, source: .voice, extractionOutcome: .parsed,
                createdAt: date(2026, 11, 1, hour: 11, minute: 30), localeIdentifier: "zh-Hans-CN",
                oldDueDate: date(2026, 11, 6), oldHasDueTime: true, oldDueHint: canaryHint,
                newDueDate: date(2026, 11, 7), newHasDueTime: true, recurring: false
            ),
            reportedSet: ParseCorrectionReportedSet(defaults: defaults),
            sink: { allEvents.append($0) },
            now: date(2026, 11, 1, hour: 12), calendar: utc
        )

        XCTAssertFalse(allEvents.isEmpty)
        for event in allEvents {
            let params = event.params
            // 键与值都不得出现金丝雀(值会拼进上报 JSON)
            for (key, value) in params {
                XCTAssertFalse(key.contains("PII_CANARY"), "参数键泄漏: \(key)")
                XCTAssertFalse(value.contains("PII_CANARY"), "参数值泄漏: \(value)")
                XCTAssertFalse(value.contains("买牛奶"), "标题原文泄漏: \(value)")
                XCTAssertFalse(value.contains("下周五"), "时间短语原文泄漏: \(value)")
            }
            // 编码成 JSON(上报载荷形态)再整串检查
            let json = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? ""
            XCTAssertFalse(json.contains("PII_CANARY"), "事件 \(event.name) 的 JSON 泄漏金丝雀")
            XCTAssertFalse(json.contains("买牛奶"))
            XCTAssertFalse(json.contains("下周五"))
        }
    }

    // MARK: - locale 编码

    func testLocaleCode() {
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: "zh-Hans-CN"), "zh")
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: "zh-Hant-TW"), "zh")
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: "en-US"), "en")
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: "ja-JP"), "ja")
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: "ko-KR"), "other")
        XCTAssertEqual(ParseCorrectionTelemetry.localeCode(from: nil), "other")
    }

    // MARK: - 事件参数契约

    func testParseConfirmedEventNameAndParams() {
        let id = UUID()
        let original = todo(id: id, dueDate: date(2026, 11, 6), dueHint: "明天")
        let confirmed = todo(id: id, dueDate: date(2026, 11, 8))
        let diff = ParseCorrectionDiff.confirmSheet(originals: [original], confirmed: [confirmed], calendar: utc)
        let event = TelemetryEvent.parseConfirmed(path: "keyboard", locale: "en", diff: diff)

        XCTAssertEqual(event.name, "parse_confirmed")
        let params = event.params
        XCTAssertEqual(params["path"], "keyboard")
        XCTAssertEqual(params["locale"], "en")
        XCTAssertEqual(params["extracted"], "1")
        XCTAssertEqual(params["kept"], "1")
        XCTAssertEqual(params["dropped"], "0")
        XCTAssertEqual(params["added"], "0")
        XCTAssertEqual(params["edited"], "1")
        XCTAssertEqual(params["dateEdited"], "1")
        XCTAssertEqual(params["timeEdited"], "0")
        XCTAssertEqual(params["kinds"], "{\"relative_day\":1}")
    }

    func testParseFieldCorrectedEventNameAndOptionalParams() {
        let correction = FieldCorrection(
            field: .date, change: .added, dayDelta: nil, minuteDelta: nil,
            expressionKind: .none, basis: nil, recurring: false
        )
        let event = TelemetryEvent.parseFieldCorrected(
            stage: ParseCorrectionStage.confirmSheet, locale: "ja",
            correction: correction, minutesSinceCreated: nil
        )
        XCTAssertEqual(event.name, "parse_field_corrected")
        let params = event.params
        XCTAssertEqual(params["stage"], "confirm_sheet")
        XCTAssertEqual(params["field"], "date")
        XCTAssertEqual(params["change"], "added")
        XCTAssertEqual(params["expressionKind"], "none")
        XCTAssertEqual(params["recurring"], "false")
        XCTAssertEqual(params["locale"], "ja")
        // 缺失即不带:键不存在 ≠ 0
        XCTAssertNil(params["dayDelta"])
        XCTAssertNil(params["minuteDelta"])
        XCTAssertNil(params["basis"])
        XCTAssertNil(params["minutesSinceCreated"])
    }
}
