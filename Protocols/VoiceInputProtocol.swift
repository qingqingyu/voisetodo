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

    /// Publisher 访问器（用于外部订阅）
    var isRecordingPublisher: AnyPublisher<Bool, Never> { get }
    var transcriptPublisher: AnyPublisher<String, Never> { get }
    var errorPublisher: AnyPublisher<VoiceTodoError?, Never> { get }

    /// 开始录音
    func startRecording() async throws
    /// 停止录音
    func stopRecording()
}
