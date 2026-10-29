import Foundation

/// `extract_outcome` 的分段计时(任务书 docs/extract-latency-monitoring-task.md §5):
/// 「说完话 → 出清单」拆成 4 个时间点,全部取**单调时钟**(`ContinuousClock`),
/// 不用系统时间相减(用户改时钟 / NTP 跳变不会污染差值)。
///
/// | 时间点 | 含义 | 写入点(见各处 mark 调用) |
/// |---|---|---|
/// | T0 `speechEnd` | 用户说完(录音结束,手动停/静音自动/达上限,全部经 `finishRecording()`) | `VoiceInputManager.finishRecording` |
/// | T1 `requestSent` | 解析请求发出(URLSession 即将拿到字节流) | `NetworkClient`(流式/非流式各一处) |
/// | T2 `firstTodo` | 第一条待办流式到达并 yield 给确认面板 | `TodoExtractorService.extractStreaming` 首次 yield |
/// | T3 `done` | 解析完成(流结束最终解析 / 非流式响应返回) | `TodoExtractorService` extract_outcome 落账点 |
///
/// 只有 **live_voice** 路径(刚录完马上解析)有 T0;离线补解析 / Siri / 键盘输入
/// 没有 T0,不带 3 个差值参数,只带 `path` 区分来源——避免把补解析的排队等待
/// 算进「说完话到出清单」。

/// `path` 参数取值。live_voice / keyboard 由 AppCoordinator 建 tracker 时显式给出;
/// 无 tracker 的路径(补解析/Siri/重新解析)从 `VoiceTodoLog.requestPath` 映射。
enum ExtractPath {
    /// 刚录完马上解析(有 T0)。
    static let liveVoice = "live_voice"
    /// 键盘输入走 AI 解析(无 T0)。
    static let keyboard = "keyboard"
    /// 前台恢复时的离线补解析(无 T0,等待时长不该进总耗时统计)。
    static let pendingRecovery = "pending_recovery"
    /// Siri 添加(无 T0)。
    static let siri = "siri"
    /// 手动卡片「重新解析」/ 详情页重新提取(无 T0)。
    static let reextract = "reextract"
    /// 兜底:主路径未细分(如离线降级 fallbackExtract,从未发请求)。
    static let main = "main"

    /// `VoiceTodoLog.requestPath` → `path` 参数。tracker 缺席时用。
    static func fromRequestPath(_ requestPath: String) -> String {
        switch requestPath {
        case "pending_batch": return pendingRecovery
        case "siri": return siri
        case "reextract", "edit_reextract": return reextract
        default: return main
        }
    }
}

/// 一次提取的计时状态。引用类型,跨 Voice → Coordinator → Extractor → NetworkClient
/// 传递;写入点在不同任务(NetworkClient 的流任务 / extractor 的重试循环),用
/// NSLock 保护 first-write-wins 语义(`@unchecked`:可变状态全部经 lock 访问)。
final class ExtractTimingTracker: @unchecked Sendable {
    /// T0:录音结束时刻。nil = 本路径没有「说完话」起点(不产出差值参数)。
    let speechEnd: ContinuousClock.Instant?
    /// 来源标记(live_voice / keyboard)。
    let path: String

    private let lock = NSLock()
    private var _requestSent: ContinuousClock.Instant?
    private var _firstTodo: ContinuousClock.Instant?

    init(speechEnd: ContinuousClock.Instant?, path: String) {
        self.speechEnd = speechEnd
        self.path = path
    }

    /// T1:请求发出。重试只记第一次(用户体感是首请求的等待)。
    func markRequestSent(_ instant: ContinuousClock.Instant) {
        lock.lock()
        defer { lock.unlock() }
        if _requestSent == nil { _requestSent = instant }
    }

    /// T2:第一条待办 yield。只在从 0 → 1 时记一次。
    /// - Returns: 是否是第一条(调用方可据此只记一次日志)。
    @discardableResult
    func markFirstTodo(_ instant: ContinuousClock.Instant) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _firstTodo == nil else { return false }
        _firstTodo = instant
        return true
    }

    /// T1/T2 快照(extract_outcome 落账时读)。
    func snapshots() -> (requestSent: ContinuousClock.Instant?, firstTodo: ContinuousClock.Instant?) {
        lock.lock()
        defer { lock.unlock() }
        return (_requestSent, _firstTodo)
    }
}

/// `extract_outcome` 的计时参数(全部毫秒整数;缺失即不带)。
struct ExtractTimingInfo: Equatable, Sendable {
    let path: String
    let speechToRequestMS: Int?
    let speechToFirstTodoMS: Int?
    let speechToDoneMS: Int?

    /// 纯函数:由 4 个时间点推导差值。任一端缺失(T0 没有 / 对应事件没发生)
    /// 对应参数为 nil——「没有出现任何待办就不带 speechToFirstTodoMS」由
    /// firstTodo 传 nil 表达。T0 缺失时三个差值全 nil(补解析路径不进总耗时统计)。
    static func resolve(
        speechEnd: ContinuousClock.Instant?,
        requestSent: ContinuousClock.Instant?,
        firstTodo: ContinuousClock.Instant?,
        done: ContinuousClock.Instant?,
        path: String
    ) -> ExtractTimingInfo {
        func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
            let duration = to - from
            // Duration → 毫秒:seconds*1000 + attoseconds/1e15(不经过 Double,无精度损失)
            return Int(duration.components.seconds) * 1000
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }
        return ExtractTimingInfo(
            path: path,
            speechToRequestMS: (speechEnd != nil && requestSent != nil) ? ms(speechEnd!, requestSent!) : nil,
            speechToFirstTodoMS: (speechEnd != nil && firstTodo != nil) ? ms(speechEnd!, firstTodo!) : nil,
            speechToDoneMS: (speechEnd != nil && done != nil) ? ms(speechEnd!, done!) : nil
        )
    }

    /// extract_outcome 落账点调用:读当前任务域的 tracker(VoiceTodoLog.extractTiming,
    /// 由 TranscriptProcessingFlow 绑定,AppCoordinator 建 tracker 后传入)解出参数。
    /// 无 tracker 的路径(补解析 PendingRecoveryFlow/Siri/重新解析/离线兜底,直接调
    /// extract(from:) 不经 binding)只带 path(从 requestPath 映射)。
    ///
    /// - Parameter doneAt: T3 解析完成时刻;取消/失败路径传 nil(取消不是完成,不带
    ///   speechToDoneMS)。
    static func resolveCurrentOutcomeTiming(doneAt: ContinuousClock.Instant?) -> ExtractTimingInfo {
        let tracker = VoiceTodoLog.extractTiming
        let path = tracker?.path ?? ExtractPath.fromRequestPath(VoiceTodoLog.requestPath)
        let snapshot = tracker?.snapshots()
        return resolve(
            speechEnd: tracker?.speechEnd,
            requestSent: snapshot?.requestSent,
            firstTodo: snapshot?.firstTodo,
            done: doneAt,
            path: path
        )
    }
}
