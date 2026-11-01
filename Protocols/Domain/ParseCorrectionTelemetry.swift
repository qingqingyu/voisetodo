import Foundation

// MARK: - 枚举与明细数据

/// 被修正的字段(只记日期和时间——准确率的核心;其他字段只在 parse_confirmed 里计数)。
enum ParseCorrectionField: String, Sendable {
    case date
    case time
}

/// 修正方式。
enum ParseCorrectionChange: String, Sendable {
    /// 原来有、改成别的。
    case changed
    /// 原来没有、用户补上。
    case added
    /// 原来有、用户删掉。
    case removed
}

/// `parse_field_corrected` 的 stage 取值(集中成常量避免调用方手拼字符串漂移)。
enum ParseCorrectionStage {
    /// 确认面板里改(解析结果出来后、点确认前)。
    static let confirmSheet = "confirm_sheet"
    /// 确认保存后不久,在详情页又改了日期或时间。
    static let afterSave = "after_save"
}

/// 一条待办一个字段的一次修正(纯数据,不含任何用户内容——PII 红线见 TELEMETRY.md)。
struct FieldCorrection: Equatable, Sendable {
    var field: ParseCorrectionField
    var change: ParseCorrectionChange
    /// 仅 `field == .date` 且 `change == .changed`:改后日期 − 原日期的用户日差,截断 ±60。
    var dayDelta: Int?
    /// 仅 `field == .time` 且 `change == .changed`:改后 − 原时间的分钟差,截断 ±1440。
    var minuteDelta: Int?
    /// 原始时间说法的类型(手机本地归类;`dueHint` 原文不进本结构)。
    var expressionKind: ParseExpressionKind
    /// 原始解析的 `dueDateBasis`(没有就不带,序列化为 nil)。
    var basis: DueDateBasis?
    /// 这条是不是重复任务(确认/修改后的最终状态)。
    var recurring: Bool
}

/// 确认面板一次确认的对比汇总(`parse_confirmed` 的数据源,纯数据)。
struct ConfirmSheetParseDiff: Equatable, Sendable {
    var extracted = 0
    var kept = 0
    var dropped = 0
    var added = 0
    var edited = 0
    var dateEdited = 0
    var timeEdited = 0
    var titleEdited = 0
    var recurrenceEdited = 0
    var reminderEdited = 0
    var categoryEdited = 0
    /// 被改日期/时间的明细(`parse_field_corrected` 的 confirm_sheet 数据源)。
    var fieldCorrections: [FieldCorrection] = []
    /// 保存条目按原始说法类型的计数(`kinds` 参数的源数据,分语言错误率的分母)。
    var keptKinds: [ParseExpressionKind: Int] = [:]

    /// `kinds` 参数的紧凑编码(如 `{"weekday":2,"none":1}`),按枚举声明顺序稳定输出,
    /// 只含枚举名和数字。用 JSON 对象串而非 `weekday:2,none:1` 裸串:D1 侧
    /// `json_each(json_extract(params,'$.kinds'))` 可直接拆键值,服务端零代码
    /// (与任务书示例的差异见 results 文档)。
    var kindsEncoding: String {
        let pairs = ParseExpressionKind.allCases.compactMap { kind -> String? in
            guard let count = keptKinds[kind], count > 0 else { return nil }
            return "\"\(kind.rawValue)\":\(count)"
        }
        return "{\(pairs.joined(separator: ","))}"
    }
}

// MARK: - 公共口径

/// 解析准确率埋点的公共口径(stage 常量、locale 编码)。
enum ParseCorrectionTelemetry {
    /// 语言标识 → 遥测 locale 参数:只取语言代码(`zh` / `en` / `ja` / `other`)。
    /// zh-Hant / zh-Hans-CN 等变体都归 `zh`。
    static func localeCode(from identifier: String?) -> String {
        guard let identifier,
              let code = Locale(identifier: identifier).language.languageCode?.identifier else {
            return "other"
        }
        switch code {
        case "zh", "en", "ja": return code
        default: return "other"
        }
    }
}

// MARK: - 对比引擎(纯函数)

/// 原始解析结果 vs 用户确认/修改结果的对比。全部纯函数,单测友好。
///
/// 「改了」的判断与 UI 实际能改的字段一致(任务书 §4.2):标题去首尾空白比较;
/// 提醒按规范化后的值(排序 + 空数组 ≡ nil)比较,字段顺序不产生误报。
enum ParseCorrectionDiff {

    // MARK: 确认面板

    /// 对比原始解析与确认后的结果(按 `id` 配对)。
    /// - Parameters:
    ///   - originals: 解析流结束后展示的原始条目(`AppCoordinator.extractedTodos` 快照)。
    ///   - confirmed: 用户点确认时提交的条目。
    ///   - locale: 内容语言(说法分类用)。
    ///   - calendar: 日历(用户日差计算用)。
    static func confirmSheet(
        originals: [ExtractedTodo],
        confirmed: [ExtractedTodo],
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> ConfirmSheetParseDiff {
        var diff = ConfirmSheetParseDiff()
        diff.extracted = originals.count
        let confirmedByID = Dictionary(confirmed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let originalIDs = Set(originals.map(\.id))

        for original in originals {
            guard let final = confirmedByID[original.id] else {
                // 在确认面板里删掉:只进 dropped,不进任何字段统计。
                diff.dropped += 1
                continue
            }
            diff.kept += 1
            // 说法类型算一次,kinds 分母与字段修正明细共用(全套正则,不重复跑)
            let kind = expressionKind(of: original, locale: locale)
            diff.keptKinds[kind, default: 0] += 1

            var editedFields = 0
            if let correction = dateCorrection(original: original, final: final, kind: kind, calendar: calendar) {
                diff.dateEdited += 1
                diff.fieldCorrections.append(correction)
                editedFields += 1
            }
            if let correction = timeCorrection(original: original, final: final, kind: kind, calendar: calendar) {
                diff.timeEdited += 1
                diff.fieldCorrections.append(correction)
                editedFields += 1
            }
            if titleChanged(original: original, final: final) {
                diff.titleEdited += 1
                editedFields += 1
            }
            if original.recurrenceRule != final.recurrenceRule {
                diff.recurrenceEdited += 1
                editedFields += 1
            }
            if reminderChanged(original: original, final: final) {
                diff.reminderEdited += 1
                editedFields += 1
            }
            if original.categoryHint != final.categoryHint {
                diff.categoryEdited += 1
                editedFields += 1
            }
            if editedFields > 0 { diff.edited += 1 }
        }

        // 确认面板当前不支持手动新增条目;若未来支持,新增的不是 AI 解析结果,
        // 只进 added 计数,不进上面任何一项。
        diff.added = confirmed.filter { !originalIDs.contains($0.id) }.count
        return diff
    }

    // MARK: 保存后(详情页改)

    /// 详情页一次更新前后快照的日期/时间修正明细。
    /// - Parameters:
    ///   - oldDueDate / oldHasDueTime: 变更前的落库值。
    ///   - newDueDate / newHasDueTime: 变更后的值(`TodoDetailUpdate` 已归一化 hasDueTime)。
    ///   - oldDueHint: 变更前持久化的原始说法(只在本地分类,绝不外发)。
    ///   - recurring: 变更后的最终重复状态。
    static func afterSaveCorrections(
        oldDueDate: Date?,
        oldHasDueTime: Bool,
        newDueDate: Date?,
        newHasDueTime: Bool,
        oldDueHint: String?,
        recurring: Bool,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> [FieldCorrection] {
        let kind = ParseExpressionClassifier.classify(
            dueHint: oldDueHint,
            hasDate: oldDueDate != nil,
            hasTime: oldHasDueTime,
            locale: locale
        )
        var result: [FieldCorrection] = []

        switch (oldDueDate, newDueDate) {
        case (nil, nil):
            break
        case (nil, .some):
            result.append(FieldCorrection(
                field: .date, change: .added, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: nil, recurring: recurring
            ))
        case (.some, nil):
            result.append(FieldCorrection(
                field: .date, change: .removed, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: nil, recurring: recurring
            ))
        case (.some(let old), .some(let new)):
            if let delta = userDayDelta(from: old, to: new, calendar: calendar), delta != 0 {
                result.append(FieldCorrection(
                    field: .date, change: .changed, dayDelta: delta, minuteDelta: nil,
                    expressionKind: kind, basis: nil, recurring: recurring
                ))
            }
        }

        // 有钟点的判定:dueDate 存在且 hasDueTime 为真(两端口径一致)。
        let oldTimed = oldDueDate != nil && oldHasDueTime
        let newTimed = newDueDate != nil && newHasDueTime
        switch (oldTimed, newTimed) {
        case (false, false):
            break
        case (false, true):
            result.append(FieldCorrection(
                field: .time, change: .added, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: nil, recurring: recurring
            ))
        case (true, false):
            result.append(FieldCorrection(
                field: .time, change: .removed, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: nil, recurring: recurring
            ))
        case (true, true):
            // oldTimed / newTimed 已保证两端 dueDate 非 nil;guard 绑定只为去掉强解包
            guard let old = oldDueDate, let new = newDueDate else { break }
            let delta = minuteDelta(
                from: minuteOfDay(of: old, calendar: calendar),
                to: minuteOfDay(of: new, calendar: calendar)
            )
            if delta != 0 {
                result.append(FieldCorrection(
                    field: .time, change: .changed, dayDelta: nil, minuteDelta: delta,
                    expressionKind: kind, basis: nil, recurring: recurring
                ))
            }
        }
        return result
    }

    // MARK: - after_save 判定(任务书 §2.3)

    /// after_save 记录的四条前置判定(全满足才可能是解析纠错):
    /// 1. 详情页直改(首页「移到明天」/ 复盘排期是改计划,不算);
    /// 2. AI 解析来的(语音/键盘/Siri 的 `.parsed` 条目;手动卡片与日历导入不算);
    /// 3. 距创建 ≤ 120 分钟;
    /// 第 4 条「该字段第一次被改」由 `ParseCorrectionReportedSet` 把关。
    enum Rules {
        /// 距创建的判定窗口(分钟)。
        static let afterSaveWindowMinutes = 120

        static func isAfterSaveCandidate(
            origin: TaskEventOrigin,
            source: TodoSource,
            extractionOutcome: ExtractionOutcome,
            createdAt: Date,
            now: Date
        ) -> Bool {
            guard origin == .detail else { return false }
            guard source == .voice, extractionOutcome == .parsed else { return false }
            return now.timeIntervalSince(createdAt) <= TimeInterval(afterSaveWindowMinutes * 60)
        }
    }

    // MARK: - 私有:字段级比较

    private static func expressionKind(of todo: ExtractedTodo, locale: Locale) -> ParseExpressionKind {
        ParseExpressionClassifier.classify(
            dueHint: todo.dueHint,
            hasDate: todo.dueDate != nil,
            hasTime: todo.dueTime != nil,
            locale: locale
        )
    }

    private static func dateCorrection(
        original: ExtractedTodo,
        final: ExtractedTodo,
        kind: ParseExpressionKind,
        calendar: Calendar
    ) -> FieldCorrection? {
        switch (original.dueDate, final.dueDate) {
        case (nil, nil):
            return nil
        case (nil, .some):
            return FieldCorrection(
                field: .date, change: .added, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        case (.some, nil):
            return FieldCorrection(
                field: .date, change: .removed, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        case (.some(let old), .some(let new)):
            guard let delta = userDayDelta(from: old, to: new, calendar: calendar), delta != 0 else { return nil }
            return FieldCorrection(
                field: .date, change: .changed, dayDelta: delta, minuteDelta: nil,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        }
    }

    private static func timeCorrection(
        original: ExtractedTodo,
        final: ExtractedTodo,
        kind: ParseExpressionKind,
        calendar: Calendar
    ) -> FieldCorrection? {
        switch (original.dueTime, final.dueTime) {
        case (nil, nil):
            return nil
        case (nil, .some):
            return FieldCorrection(
                field: .time, change: .added, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        case (.some, nil):
            return FieldCorrection(
                field: .time, change: .removed, dayDelta: nil, minuteDelta: nil,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        case (.some(let old), .some(let new)):
            guard let oldMinutes = TodoDueTimeResolver.parse(old).map({ $0.hour * 60 + $0.minute }),
                  let newMinutes = TodoDueTimeResolver.parse(new).map({ $0.hour * 60 + $0.minute }) else { return nil }
            let delta = minuteDelta(from: oldMinutes, to: newMinutes)
            guard delta != 0 else { return nil }
            return FieldCorrection(
                field: .time, change: .changed, dayDelta: nil, minuteDelta: delta,
                expressionKind: kind, basis: original.dueDateBasis, recurring: final.recurrenceRule != nil
            )
        }
    }

    private static func titleChanged(original: ExtractedTodo, final: ExtractedTodo) -> Bool {
        original.title.trimmingCharacters(in: .whitespacesAndNewlines)
            != final.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提醒比较:多时间点排序后比较(空数组 ≡ nil),外加提前量变化。
    private static func reminderChanged(original: ExtractedTodo, final: ExtractedTodo) -> Bool {
        let originalTimes = (original.reminderTimes ?? []).sorted()
        let finalTimes = (final.reminderTimes ?? []).sorted()
        if originalTimes != finalTimes { return true }
        return original.reminderOffsetMinutes != final.reminderOffsetMinutes
    }

    // MARK: - 私有:差值计算

    /// 用户日差(改后 − 原日期),按 `DayClock.startOfUserDay` 取两端日界,
    /// DST 安全(用 dateComponents 而非秒数除法),截断 ±60。
    private static func userDayDelta(from old: Date, to new: Date, calendar: Calendar) -> Int? {
        guard let days = calendar.dateComponents(
            [.day],
            from: DayClock.startOfUserDay(for: old, calendar: calendar),
            to: DayClock.startOfUserDay(for: new, calendar: calendar)
        ).day else { return nil }
        return min(60, max(-60, days))
    }

    /// 一天内的分钟数(钟点字段比较用)。
    private static func minuteOfDay(of date: Date, calendar: Calendar) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// 分钟差(改后 − 原时间),截断 ±1440。
    private static func minuteDelta(from oldMinutes: Int, to newMinutes: Int) -> Int {
        min(1440, max(-1440, newMinutes - oldMinutes))
    }
}

// MARK: - 「已上报过的 待办id+字段」集合

/// after_save 去重集合:App Group UserDefaults 存储,条目 48 小时过期,
/// 上限 500 条,超出删最旧的。只由主 App 进程写(详情页路径),无跨进程竞争。
struct ParseCorrectionReportedSet {
    static let maxEntries = 500
    static let expiry: TimeInterval = 48 * 3600
    static let defaultKey = "VoiceTodoParseCorrectionReported"

    private let defaults: UserDefaults?
    private let key: String

    init(defaults: UserDefaults?, key: String = ParseCorrectionReportedSet.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// 该 待办id+字段 是否已上报过(过期条目视同未上报,顺带清理)。
    func contains(todoID: UUID, field: ParseCorrectionField, now: Date) -> Bool {
        guard let timestamp = load()[entryKey(todoID: todoID, field: field)] else { return false }
        return now.timeIntervalSince(timestamp) < Self.expiry
    }

    /// 登记一次上报(写入时顺带做过期清理与容量裁剪)。
    func mark(todoID: UUID, field: ParseCorrectionField, now: Date) {
        var entries = pruned(now: now)
        entries[entryKey(todoID: todoID, field: field)] = now
        if entries.count > Self.maxEntries {
            // 删时间戳最旧的条目;并列时删哪个无所谓,只影响去重窗口的边缘。
            let overflow = entries.count - Self.maxEntries
            for key in entries.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
        save(entries)
    }

    private func entryKey(todoID: UUID, field: ParseCorrectionField) -> String {
        "\(todoID.uuidString)|\(field.rawValue)"
    }

    private func load() -> [String: Date] {
        guard let defaults,
              let raw = defaults.dictionary(forKey: key) as? [String: Date] else {
            return [:]
        }
        return raw
    }

    private func pruned(now: Date) -> [String: Date] {
        load().filter { now.timeIntervalSince($0.value) < Self.expiry }
    }

    private func save(_ entries: [String: Date]) {
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }
}

// MARK: - after_save 上报收口

/// 详情页更新后的解析修正上报:判定 → 去重 → 事件组装,一处收口。
/// `TodoStore.updateFull` 在保存成功后调用;失败/不满足判定时无操作。
///
/// 隐私红线:`oldDueHint` 只在本地喂给 `ParseExpressionClassifier`,
/// 绝不进日志、绝不进遥测参数。
enum ParseCorrectionRecorder {
    /// after_save 判定与上报的输入(变更前后快照)。
    struct AfterSaveInput {
        let todoID: UUID
        let origin: TaskEventOrigin
        let source: TodoSource
        let extractionOutcome: ExtractionOutcome
        let createdAt: Date
        let localeIdentifier: String?
        let oldDueDate: Date?
        let oldHasDueTime: Bool
        let oldDueHint: String?
        let newDueDate: Date?
        let newHasDueTime: Bool
        let recurring: Bool
    }

    /// 记录一次 after_save 修正(满足 §2.3 四条判定的字段各记一条事件)。
    /// - Parameters:
    ///   - reportedSet: 去重集合(默认 App Group 共享存储)。
    ///   - sink: 事件出口(默认 `Telemetry.record`;测试注入捕获)。
    ///   - now / calendar: 时钟与日历(测试注入)。
    static func recordAfterSaveIfNeeded(
        _ input: AfterSaveInput,
        reportedSet: ParseCorrectionReportedSet? = nil,
        sink: (TelemetryEvent) -> Void = { Telemetry.record($0) },
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard ParseCorrectionDiff.Rules.isAfterSaveCandidate(
            origin: input.origin,
            source: input.source,
            extractionOutcome: input.extractionOutcome,
            createdAt: input.createdAt,
            now: now
        ) else { return }

        let corrections = ParseCorrectionDiff.afterSaveCorrections(
            oldDueDate: input.oldDueDate,
            oldHasDueTime: input.oldHasDueTime,
            newDueDate: input.newDueDate,
            newHasDueTime: input.newHasDueTime,
            oldDueHint: input.oldDueHint,
            recurring: input.recurring,
            // 分类与事件 locale 参数同源(取输入的 localeIdentifier),避免未来加语言
            // 特化规则时分类悄悄落到系统 locale(当前规则三语并集,行为无差异)
            locale: input.localeIdentifier.map { Locale(identifier: $0) } ?? .current,
            calendar: calendar
        )
        guard !corrections.isEmpty else { return }

        let set = reportedSet ?? ParseCorrectionReportedSet(
            defaults: UserDefaults(suiteName: WidgetConfig.appGroupIdentifier)
        )
        let locale = ParseCorrectionTelemetry.localeCode(from: input.localeIdentifier)
        let minutesSinceCreated = max(0, Int(now.timeIntervalSince(input.createdAt) / 60))

        for correction in corrections {
            guard !set.contains(todoID: input.todoID, field: correction.field, now: now) else { continue }
            set.mark(todoID: input.todoID, field: correction.field, now: now)
            sink(.parseFieldCorrected(
                stage: ParseCorrectionStage.afterSave,
                locale: locale,
                correction: correction,
                minutesSinceCreated: minutesSinceCreated
            ))
        }
    }
}
