import SwiftUI
import Combine

// MARK: - 状态机(v6 §2 第 5 步:「状态机 + 两种外观」的状态机半)
//
// 原 `ReviewMicRow` 内联的录音状态(isRecording 镜像 / liveText /
// pendingAdopt / E10 部分转写、错误显式传播)整体抽成 `@MainActor` 模型,
// 两种外观共用,逻辑零改动:
// - `ReviewMicRow`:行式外观(拆小 sheet 与第 5 步旧版),**外观不变**;
// - `ReviewMicInputOverlay`:输入框内嵌外观(第 5 步「问问自己」,v6 A2)。
//
/// 采纳目标由外观注入(`bind` 的 onAdopt);E10(永不丢话先例):
/// `onAdoptPartialOnError` 非空时,录音中断/错误的**部分转写**交给调用方
/// 预填(转写失败降级手打=S2,但已说出的话不丢);拆小场景保持旧行为
/// (nil = 部分转写不采纳,如实报错——切条输入不容垃圾)。
@MainActor
final class ReviewMicSession: ObservableObject {
    /// isRecording 的本地镜像(bind 时播种 + publisher 同步)。
    @Published private(set) var isRecording = false
    /// 本次监听期间累积的转写。不直接读 `voiceInput.transcript`——那里可能
    /// 留着首页上一次录音的旧文本,只有监听开始后的 publisher 事件才是本次的。
    @Published private(set) var liveText = ""

    private var wasListening = false
    /// 录音停止后的待采纳转写(error 事件在下一个 runloop 前可将其清空作废)。
    private var pendingAdoptText: String?
    private var cancellables = Set<AnyCancellable>()
    private var hasBound = false

    private let voiceInput: any VoiceInputProtocol
    private var onError: ((Error) -> Void)?
    private var onAdopt: ((String) -> Void)?
    private var onAdoptPartialOnError: ((String) -> Void)?
    private var ensureConsent: (() async -> Bool)?

    init(voiceInput: any VoiceInputProtocol) {
        self.voiceInput = voiceInput
    }

    /// 外观视图 onAppear 时绑定(重复调用只刷新回调,订阅只建一次)。
    /// E6:录音起步前过同意 gate(与首页 startRecording 同口径)——
    /// 未同意本次不录,不静默;按钮还在,用户随时可再试。
    func bind(
        onError: @escaping (Error) -> Void,
        onAdopt: @escaping (String) -> Void,
        onAdoptPartialOnError: ((String) -> Void)? = nil,
        ensureConsent: (() async -> Bool)? = nil
    ) {
        self.onError = onError
        self.onAdopt = onAdopt
        self.onAdoptPartialOnError = onAdoptPartialOnError
        self.ensureConsent = ensureConsent
        guard !hasBound else { return }
        hasBound = true
        // 行可能出现在录音已开始之后(如候选加载完成时):播种当前态。
        isRecording = voiceInput.isRecording

        voiceInput.isRecordingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self else { return }
                self.isRecording = recording
                if recording {
                    self.wasListening = true
                    self.liveText = ""
                    self.pendingAdoptText = nil
                } else if self.wasListening {
                    // 结束(手动停/静音自动停):进入待采纳态。VoiceInputManager
                    // 的错误路径(中断/watchdog)是先置 isRecording=false 再设
                    // error——同一个调用栈里 error 事件会紧跟着到,这里延后一个
                    // runloop 再决定采纳还是报错,避免把不完整转写当结果、又把
                    // 错误吞掉。
                    self.wasListening = false
                    let final = self.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.liveText = ""
                    guard !final.isEmpty else { return }
                    self.pendingAdoptText = final
                    DispatchQueue.main.async { [weak self] in
                        guard let text = self?.pendingAdoptText else { return } // error 路径已清空
                        self?.pendingAdoptText = nil
                        self?.onAdopt?(text)
                    }
                }
            }
            .store(in: &cancellables)

        voiceInput.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, self.wasListening else { return }
                self.liveText = text
            }
            .store(in: &cancellables)

        voiceInput.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                // 录音出错(含停止后紧跟的错误事件):如实上报(错误显式传播,
                // 不静默);E10:部分转写不丢——onAdoptPartialOnError 在场时预填。
                guard let error, self.wasListening || self.pendingAdoptText != nil else { return }
                // 恢复源必须含 pendingAdoptText:中断/watchdog 路径
                // (VoiceInputManager 先置 isRecording=false 再设 error,同栈)里,
                // 上面的 isRecording=false 处理器已把部分转写搬进 pendingAdoptText
                // 并清空 liveText——只读 liveText 会让 E10 在最典型的中断场景反而丢话。
                let partial = (self.pendingAdoptText ?? self.liveText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.wasListening = false
                self.liveText = ""
                self.pendingAdoptText = nil
                if !partial.isEmpty {
                    self.onAdoptPartialOnError?(partial)
                }
                self.onError?(error)
            }
            .store(in: &cancellables)
    }

    /// 点按麦克风:未在录 → 过同意 gate 后开录;在录 = 现有「说完了」
    /// (finishRecording)。
    func toggleRecording() {
        if isRecording {
            voiceInput.finishRecording()
        } else {
            Task { @MainActor in
                if let ensureConsent, await !ensureConsent() { return }
                do {
                    try await voiceInput.startRecording()
                } catch {
                    onError?(error)
                }
            }
        }
    }

    /// 取消(不留痕)。
    func cancelByUser() {
        voiceInput.cancelRecordingByUser()
        wasListening = false
        liveText = ""
        pendingAdoptText = nil
        isRecording = false
    }
}

// MARK: - 外观一:行式(拆小 sheet,外观不变)

/// 复盘流程通用麦克风行(v5 D8 拍板:同款复用——与拆小 sheet 同一交互,
/// 点按开始 / 说完了 / 取消 / 静音自动停,时长上限沿用 VoiceInputManager 的
/// maxDuration,不另设)。v6:状态迁入 `ReviewMicSession`,本视图只剩行式
/// 外观——拆小 sheet 的外观与行为不变。
struct ReviewMicRow: View {
    let voiceInput: any VoiceInputProtocol
    /// 行内提示(语境化,调用方传本地化字符串)。
    let hint: String
    let onError: (Error) -> Void
    let onAdopt: (String) -> Void
    /// 录音中断/错误时的部分转写预填(E10)。nil = 旧行为(不采纳)。
    var onAdoptPartialOnError: ((String) -> Void)? = nil
    /// AI 同意 gate(E6:录音的终点是转写进 AI 处理链,起步前先取得同意——
    /// 与首页 startRecording 同口径)。nil = 调用方环境无 coordinator(单测)。
    var ensureConsent: (() async -> Bool)? = nil

    @StateObject private var session: ReviewMicSession

    init(
        voiceInput: any VoiceInputProtocol,
        hint: String,
        onError: @escaping (Error) -> Void,
        onAdopt: @escaping (String) -> Void,
        onAdoptPartialOnError: ((String) -> Void)? = nil,
        ensureConsent: (() async -> Bool)? = nil
    ) {
        self.voiceInput = voiceInput
        self.hint = hint
        self.onError = onError
        self.onAdopt = onAdopt
        self.onAdoptPartialOnError = onAdoptPartialOnError
        self.ensureConsent = ensureConsent
        _session = StateObject(wrappedValue: ReviewMicSession(voiceInput: voiceInput))
    }

    var body: some View {
        Group {
            if session.isRecording {
                listeningRow
            } else {
                idleRow
            }
        }
        .onAppear {
            session.bind(
                onError: onError,
                onAdopt: onAdopt,
                onAdoptPartialOnError: onAdoptPartialOnError,
                ensureConsent: ensureConsent
            )
        }
    }

    private var idleRow: some View {
        Button {
            session.toggleRecording()
        } label: {
            HStack(spacing: WarmSpacing.sm) {
                Label(String(localized: "review.flow.split.mic.say"), systemImage: "mic.fill")
                    .font(WarmFont.headline(13))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: WarmSpacing.xs)

                Text(hint)
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            .padding(WarmSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                    .fill(WarmTheme.cardBackground)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ReviewMicRowStart")
    }

    private var listeningRow: some View {
        HStack(spacing: WarmSpacing.sm) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16))
                .foregroundColor(WarmTheme.urgentText)

            VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                Text(verbatim: session.liveText.isEmpty
                    ? String(localized: "review.flow.split.mic.listening")
                    : session.liveText)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                HStack(spacing: WarmSpacing.md) {
                    // 手动「说完了」:等 isFinal 最终转写后自动停止 → 采纳
                    Button(String(localized: "review.flow.split.mic.done")) {
                        session.toggleRecording()
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .buttonStyle(.plain)

                    Button(String(localized: "review.flow.split.mic.cancel")) {
                        session.cancelByUser()
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(WarmSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.chip, style: .continuous)
                .fill(WarmTheme.cardBackground)
        )
    }
}

// MARK: - 外观二:输入框内嵌(第 5 步「问问自己」,v6 A2)

/// 麦克风的输入框内嵌外观(v6 §2 第 5 步):输入框右下角的珊瑚色实心圆
/// 按钮(48pt,≥44 点击区);点一下开始录音(经 ensureConsent),按钮变
/// 停止键并有脉冲外圈;输入框左下显示「在听…」+「取消」;再点一下 =
/// 现有「说完了」。静音自动停、错误降级、部分转写预填(E10)全部沿用
/// `ReviewMicSession`,只换外观。
struct ReviewMicInputOverlay: View {
    @ObservedObject var session: ReviewMicSession

    /// 脉冲外圈缩放(录音中 1.2s 循环)。
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        HStack(alignment: .bottom) {
            if session.isRecording {
                HStack(spacing: WarmSpacing.md) {
                    Text(String(localized: "review.flow.split.mic.listening"))
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Button(String(localized: "review.flow.split.mic.cancel")) {
                        session.cancelByUser()
                    }
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)
                    .buttonStyle(.plain)
                }
                .padding(.leading, WarmSpacing.sm)
                .padding(.bottom, WarmSpacing.xs + 2)
            }

            Spacer(minLength: WarmSpacing.xs)

            micButton
        }
        .onChange(of: session.isRecording) { _, recording in
            if recording {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseScale = 1.35
                }
            } else {
                withAnimation(WarmAnimation.springStandard) { pulseScale = 1.0 }
            }
        }
    }

    /// 麦克风圆钮:空闲 = mic 图标;录音中 = 停止键 + 脉冲外圈。
    private var micButton: some View {
        Button {
            session.toggleRecording()
        } label: {
            ZStack {
                if session.isRecording {
                    Circle()
                        .stroke(WarmTheme.primary.opacity(0.45), lineWidth: 5)
                        .scaleEffect(pulseScale)
                }
                Circle()
                    .fill(WarmTheme.primary)
                Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .frame(width: 48, height: 48)
            .shadow(color: WarmTheme.primary.opacity(0.35), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: session.isRecording
            ? "review.flow.split.mic.done"
            : "review.flow.note.mic.a11y"))
        .accessibilityIdentifier("ReviewFlowLedgerMic")
        .animation(WarmAnimation.springStandard, value: session.isRecording)
    }
}
