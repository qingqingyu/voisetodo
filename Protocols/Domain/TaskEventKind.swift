import Foundation

/// 复盘埋点事件类型(拍板 3:只记「从 TodoItem 字段推导不出来的」三类)。
///
/// created / completed / reopened 不进事件表——三者从 `TodoItem.createdAt` /
/// `completedAt` 直接推导;尤其 completed,Widget/AppIntent 进程的完成走自己的
/// context、不经 `toggleComplete`,事件表覆盖天生残缺,记了反而比字段更不全、
/// 误导分析(见 docs/todo-review-flow-design.md §1.3)。
enum TaskEventType: String, Codable, CaseIterable, Sendable {
    /// 推迟:dueDate 往后移到更晚的用户日。
    case deferred
    /// 划掉:用户决定不做(写 `TodoItem.abandonedAt`,与 delete 分开)。
    case abandoned
    /// 拆小:任务被拆成子任务(子任务带 `parentTodoId`,原任务标 abandoned)。
    case split

    /// 从原始字符串容错构造:大小写不敏感,未知/缺失回落 `.deferred`?
    /// 不——回落无意义,直接返回 nil,让调用方决定脏数据策略(与 TodoCategory 的
    /// `.other` 兜底不同,这里没有合理的默认事件类型)。
    static func tolerant(_ raw: String?) -> TaskEventType? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return TaskEventType(rawValue: raw)
    }
}

/// 事件发生时所在的写入路径(拍板 5:集合为 app | review | detail,无 widget——
/// 已核实 widget/AppIntents 无 dueDate 写入点,deferred 不可能在 widget 进程发生)。
enum TaskEventOrigin: String, Codable, CaseIterable, Sendable {
    /// 常规 App 内操作(首页「移到明天」、改时间 popover 等)。
    case app
    /// 复盘流程里的主动排期(阶段 3 的五步流程)。**不计入推迟次数**——
    /// 用户越认真复盘,推迟数字不该越难看。
    case review
    /// 详情页直改 dueDate。
    case detail

    /// 从原始字符串容错构造:大小写不敏感,未知/缺失返回 nil。
    static func tolerant(_ raw: String?) -> TaskEventOrigin? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return TaskEventOrigin(rawValue: raw)
    }
}

/// 推迟判定的纯函数规则(供 `TodoStore.updateFull` 埋点前判断,单测友好)。
///
/// 口径(docs/todo-review-flow-design.md §1.3 + 拍板):
/// - 新 dueDate 的**用户日**(`DayClock.startOfUserDay`)严格晚于旧 dueDate 的用户日才记;
///   同一用户日内改钟点不记,往前改不记。
/// - 旧 dueDate 为 nil(从未排期 → 首次排期)不记。
/// - 任务已完成或已划掉时不记——推迟语义只对未完成的工作成立。
enum TaskEventRules {
    /// 判断一次 dueDate 变更是否构成「推迟」事件。
    /// - Parameters:
    ///   - oldDueDate: 变更前的 dueDate(nil = 从未排期,首次排期不记)。
    ///   - newDueDate: 变更后的 dueDate。
    ///   - isCompleted: 任务当前是否已完成。
    ///   - abandonedAt: 任务是否已划掉(nil = 未划掉)。
    ///   - calendar: 日历(默认 `.current`)。
    /// - Returns: true = 应记一条 `.deferred` 事件。
    static func isDeferral(
        oldDueDate: Date?,
        newDueDate: Date?,
        isCompleted: Bool,
        abandonedAt: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard !isCompleted, abandonedAt == nil else { return false }
        guard let oldDueDate, let newDueDate else { return false }
        return DayClock.startOfUserDay(for: newDueDate, calendar: calendar)
            > DayClock.startOfUserDay(for: oldDueDate, calendar: calendar)
    }
}
