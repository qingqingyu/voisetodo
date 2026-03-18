import Foundation
import Combine

/// 语音输入协议
protocol VoiceInputProtocol: ObservableObject {
    /// 是否正在录音
    var isRecording: Bool { get }
    /// 实时转写文本
    var transcript: String { get }
    /// 错误状态
    var error: VoiceTodoError? { get }

    /// 开始录音
    func startRecording() async throws
    /// 停止录音
    func stopRecording()
}
