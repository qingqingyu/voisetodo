import SwiftUI

/// 录音波形动画：20 根竖条用真实音频电平驱动高度，sin 函数叠加微变让波形有呼吸感。
/// TimelineView(.animation) 每帧更新，iOS 17+ 可用。
/// audioLevel (0...1) 来自 VoiceInputManager 的归一化 RMS，静音时柱子缩到最小。
///
/// 通过 `isActive` 控制是否绘制——面板拆除/动画收尾期间停止 30 FPS 重绘。
struct WaveformView: View {
    private let barCount = 20
    private let barWidth: CGFloat = 3.5
    private let spacing: CGFloat = 3
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 32
    private let color: Color
    private let isActive: Bool
    private let audioLevel: Float

    init(color: Color = WarmTheme.primary, isActive: Bool = true, audioLevel: Float = 0) {
        self.color = color
        self.isActive = isActive
        self.audioLevel = audioLevel
    }

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    HStack(spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let phase = Double(i) / Double(barCount) * .pi * 2
                            // 真实音量为基础高度，sin 叠加 ±15% 微变让波形有呼吸感而非静态
                            let level = Double(audioLevel)
                            let variation = sin(t * 5 + phase) * 0.15 + sin(t * 3 + phase * 1.5) * 0.1
                            let normalized = min(1.0, max(0.05, level + variation))
                            let height = minHeight + (maxHeight - minHeight) * normalized
                            Capsule()
                                .fill(color)
                                .frame(width: barWidth, height: max(height, minHeight))
                        }
                    }
                    .frame(height: maxHeight)
                    .accessibilityHidden(true)
                }
            } else {
                Color.clear
                    .frame(height: maxHeight)
                    .accessibilityHidden(true)
            }
        }
    }
}

#Preview {
    WaveformView()
        .padding()
}
