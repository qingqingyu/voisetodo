import Foundation

/// 详情页时间卡「日期行」的呈现策略。
///
/// **背景**:引擎层(TodoQueryActor / TodoStore / WidgetTodoFilter / ToggleTodoIntent)
/// 对 `dueDate` 的语义早就统一了——
///
///     if let rule = todo.recurrenceRule {
///         let start = todo.dueDate ?? todo.createdAt
///         for day in days where rule.occurs(on: day, startDate: start) { ... }
///     } else if let dueDate = todo.dueDate {
///         // 单次 occurrence
///     }
///
/// 也就是说,**有 `recurrenceRule` 时,`dueDate` 是「起始锚点」而不是「截止日」**。
/// 同样的 `dueDate ?? createdAt` 锚点语义还散落在
/// `Store/TodoStore.swift`、`Protocols/Domain/WidgetTodoFilter.swift`、
/// `App/Intents/ToggleTodoIntent.swift`、`UI/MockStore.swift`,以及
/// `RecurrenceRule.occurs(on:startDate:)` 自身。
///
/// 展示层也早就跟上了:`TodoTimeDisplayComposer.compose` 在 `recurrenceRule != nil`
/// 时主动跳过 `relativeDateText`,只渲染 `rule.displayTextWithEndDate` + 钟点/时段。
///
/// 唯一站出来打架的是详情页 UI——它把 `dueDate` 标成「日期」,读起来像一次性截止日,
/// 跟下面的「重复」卡互斥。本 helper 把三种呈现形态显式化,让详情页对齐引擎语义。
enum RecurrenceAnchorPolicy {
    /// 详情页时间卡的日期行形态。
    enum DateRowMode: Equatable {
        /// 无重复:`dueDate` 就是截止日,显示「日期」DatePicker + ✕(清空回到无日期)。
        case dueDate
        /// 双周/三周(weekly `interval > 1`):锚点决定 `occurs(on:startDate:)` 的
        /// `weekDiff % interval`,清掉会退回 `createdAt`,用户既看不见也控制不了
        /// 「从哪一周开始」——所以显示「起始日期」DatePicker,**不允许清空**。
        case startAnchor
        /// 每天 / 每周(interval==1) / 每月:锚点只是下界,或靠 `dayOfMonth` 自锚,
        /// 暴露出来只会跟重复卡语义打架——**整行隐藏**。
        case hidden
    }

    /// 判定日期行的呈现形态。
    /// - frequency == nil → `.dueDate`(单次任务)
    /// - weekly + interval > 1 → `.startAnchor`(含 AI fallback 的 interval >= 4)
    /// - daily / weekly(interval==1) / monthly → `.hidden`
    static func dateRowMode(frequency: RecurrenceFrequency?, interval: Int) -> DateRowMode {
        switch frequency {
        case nil:
            return .dueDate
        case .weekly:
            return interval > 1 ? .startAnchor : .hidden
        case .daily, .monthly:
            return .hidden
        }
    }

    /// 时段区「添加钟点」按钮是否可见。
    ///
    /// 原行为:`editedDueDate != nil` 才显示。现在锚点可能在 `recurrenceModeButton`
    /// 里被自动补齐(双周/三周 case),也可能因重复规则存在而隐式有效(锚点是 createdAt),
    /// 所以判定收紧成「**有 dueDate 或有重复规则**」——任何重复档位下都能加钟点。
    ///
    /// 当前实现等价于 `dueDate != nil || frequency != nil`。函数存在的意义是把这条
    /// 领域规则显式化,未来若新增「无 recurrenceRule 但仍不能加钟点」的领域约束,只改这一处。
    static func canAddClockTime(dueDate: Date?, frequency: RecurrenceFrequency?) -> Bool {
        return dueDate != nil || frequency != nil
    }

    /// 重复卡底部摘要是否要带「从 X 起」前缀。
    ///
    /// - `.startAnchor` 恒带:双周/三周的锚点决定从哪一周开始,必须显式可见。
    /// - `.dueDate` 恒不带:无重复,锚点就是截止日本身,「从 X 起」语义错误。
    /// - `.hidden`:仅当锚点在未来才带(锚点在今天/过去时不重复说「从今天起」,
    ///   减少噪声;锚点在未来时才对用户有信息量,例如「从 8月15日起 · 每天 · 15:00」)。
    static func showsAnchorPrefix(
        mode: DateRowMode,
        anchor: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch mode {
        case .startAnchor:
            return true
        case .dueDate:
            return false
        case .hidden:
            guard let anchor else { return false }
            return calendar.startOfDay(for: anchor) > calendar.startOfDay(for: now)
        }
    }
}
