import SwiftUI

/// 复盘流程通用麦克风行(v5 D8 拍板:同款复用——与拆小 sheet 同一交互,
/// 点按开始 / 说完了 / 取消 / 静音自动停,时长上限沿用 VoiceInputManager 的
/// maxDuration,不另设)。原 `SplitMicRow`(ReviewStepTriage 私有)抽公用,
/// T4「问问自己」麦克风同款接入。
///
/// 采纳目标由调用方注入(`onAdopt`);`hint` 行内提示文案随语境
/// (拆小=「自动切成几条」/笔记=「直接进笔记框」),其余文案键共用
/// (review.flow.split.mic.say/done/cancel/listening)——同一交互同一套话。
///
/// E10(永不丢话先例):`onAdoptPartialOnError` 非空时,录音中断/错误的
/// **部分转写**交给调用方预填(转写失败降级手打=S2,但已说出的话不丢);
/// 拆小场景保持旧行为(nil = 部分转写不采纳,如实报错——切条输入不容垃圾)。
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

    /// isRecording 的本地镜像(onAppear 播种 + publisher 同步)。
    @State private var isRecording = false
    /// 本次监听期间累积的转写。不直接读 `voiceInput.transcript`——那里可能留着
    /// 首页上一次录音的旧文本,只有监听开始后的 publisher 事件才是本次的。
    @State private var liveText = ""
    @State private var wasListening = false
    /// 录音停止后的待采纳转写(error 事件在下一个 runloop 前可将其清空作废)。
    @State private var pendingAdoptText: String?

    var body: some View {
        Group {
            if isRecording {
                listeningRow
            } else {
                idleRow
            }
        }
        .onAppear {
            // 行可能出现在录音已开始之后(如候选加载完成时):播种当前态
            isRecording = voiceInput.isRecording
        }
        .onReceive(voiceInput.isRecordingPublisher) { recording in
            isRecording = recording
            if recording {
                wasListening = true
                liveText = ""
                pendingAdoptText = nil
            } else if wasListening {
                // 结束(手动停/静音自动停):进入待采纳态。VoiceInputManager 的错误路径
                // (中断/watchdog)是先置 isRecording=false 再设 error——同一个调用栈里
                // error 事件会紧跟着到,这里延后一个 runloop 再决定采纳还是报错,
                // 避免把不完整转写当结果、又把错误吞掉。
                wasListening = false
                let final = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                liveText = ""
                guard !final.isEmpty else { return }
                pendingAdoptText = final
                DispatchQueue.main.async {
                    guard let text = pendingAdoptText else { return } // error 路径已清空
                    pendingAdoptText = nil
                    onAdopt(text)
                }
            }
        }
        .onReceive(voiceInput.transcriptPublisher) { text in
            guard wasListening else { return }
            liveText = text
        }
        .onReceive(voiceInput.errorPublisher) { error in
            // 录音出错(含停止后紧跟的错误事件):如实上报(错误显式传播,不静默);
            // E10:部分转写不丢——onAdoptPartialOnError 在场时预填给调用方。
            guard let error, wasListening || pendingAdoptText != nil else { return }
            // 恢复源必须含 pendingAdoptText:中断/watchdog 路径(VoiceInputManager
            // 先置 isRecording=false 再设 error,同栈)里,上面的 isRecording=false
            // 处理器已把部分转写搬进 pendingAdoptText 并清空 liveText——只读
            // liveText 会让 E10 在最典型的中断场景反而丢话。
            let partial = (pendingAdoptText ?? liveText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            wasListening = false
            liveText = ""
            pendingAdoptText = nil
            if !partial.isEmpty, let adoptPartial = onAdoptPartialOnError {
                adoptPartial(partial)
            }
            onError(error)
        }
    }

    private var idleRow: some View {
        Button {
            Task { @MainActor in
                // E6:未同意先弹披露卡(挂起→同意后无缝继续本次录音);拒绝则
                // 本次不录,不静默——按钮还在,用户随时可再试。
                if let ensureConsent, await !ensureConsent() { return }
                do {
                    try await voiceInput.startRecording()
                } catch {
                    onError(error)
                }
            }
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
                Text(verbatim: liveText.isEmpty
                    ? String(localized: "review.flow.split.mic.listening")
                    : liveText)
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                HStack(spacing: WarmSpacing.md) {
                    // 手动「说完了」:等 isFinal 最终转写后自动停止 → 采纳
                    Button(String(localized: "review.flow.split.mic.done")) {
                        voiceInput.finishRecording()
                    }
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .buttonStyle(.plain)

                    Button(String(localized: "review.flow.split.mic.cancel")) {
                        voiceInput.cancelRecordingByUser()
                        wasListening = false
                        liveText = ""
                        pendingAdoptText = nil
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
