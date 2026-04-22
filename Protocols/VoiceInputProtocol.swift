import Foundation
import Combine

/// 语音输入协议
/// 只要求读取访问，实现类型自行管理内部状态变更
/// 提供 Publisher 访问器以支持 Combine 绑定
@MainActor
protocol VoiceInputProtocol: ObservableObject {
    /// 是否正在录音
    var isRecording: Bool { get }
    /// 实时转写文本
    var transcript: String { get }
    /// 错误状态
    var error: VoiceTodoError? { get }
    /// 当前语音识别使用的 locale（用于选择匹配的 AI prompt）
    var currentLocale: Locale { get }

    /// Publisher 访问器（用于外部订阅）
    var isRecordingPublisher: AnyPublisher<Bool, Never> { get }
    var transcriptPublisher: AnyPublisher<String, Never> { get }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { get }

    /// 开始录音
    func startRecording() async throws
    /// 停止录音（立即终止，用于中断/错误恢复场景）
    func stopRecording()
    /// 通知识别器音频输入结束，等待最终识别结果后自动停止
    /// 适用于用户手动停止场景，确保获取最终识别结果
    func finishRecording()
}
