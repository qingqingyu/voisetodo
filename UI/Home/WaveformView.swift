import SwiftUI

/// 录音波形动画：20 根竖条用 sin 函数生成自然波形跳动。
/// TimelineView(.animation) 每帧更新，iOS 17+ 可用。
/// 跟实际音量不需要联动（纯动画足够），如果要接 AudioEngine 的 meter 再改。
///
/// 通过 `isActive` 控制是否绘制——面板拆除/动画收尾期间停止 30 FPS 重绘。
struct WaveformView: View {
    private let barCount = 20
    private let barWidth: CGFloat = 3.5
    private let spacing: CGFloat = 3
    private let minHeight: CGFloat = 6
    private let maxHeight: CGFloat = 40
    private let color: Color
    private let isActive: Bool

    init(color: Color = WarmTheme.primary, isActive: Bool = true) {
        self.color = color
        self.isActive = isActive
    }

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    HStack(spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let phase = Double(i) / Double(barCount) * .pi * 2
                            // 两个频率叠加让波形更像真实语音（不是均匀跳动）
                            let wave = sin(t * 5 + phase) * 0.6 + sin(t * 3 + phase * 1.5) * 0.4
                            let normalized = (wave + 1) / 2 // 映射到 0...1
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
