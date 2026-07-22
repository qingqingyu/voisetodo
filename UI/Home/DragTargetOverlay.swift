import SwiftUI

/// 任务卡片拖拽期间叠在 timeline 上方的 4 条等高横向条带 overlay。
///
/// 设计意图(用户原话):拖拽时**底层布局不动**,overlay 提供 4 个等大落点
/// (Anytime/Morning/Afternoon/Evening),每条 90-110pt,覆盖整个 timeline 区域。
/// 底层卡片透过 65% 不透明背景隐约可见(原位置参考),overlay 条带是真实 drop target。
///
/// **数据来源**:`taskCount` 走 `HomeCalendarState.indexedUncompletedOccurrences(in:)`。
/// 这是"hover 到这个 bucket 时能看到当前已有 N 个任务"的反馈信息,帮助用户判断
/// 拥挤程度(比如 Morning 已经有 5 个,可能不想再加)。
///
/// **Haptic 反馈**:
/// - 进入条带瞬间 → `.selection`(轻提示,跟 picker 滚动同款)
/// - 释放成功落位 → `.success`(在 `dropDestination` action 里触发)
///
/// **交互边界**:每条 strip 是独立的 `.dropDestination(for: String.self)`,载荷是
/// UUID 字符串(`.draggable(todo.id.uuidString)`)。落位回调由调用方(HomeView)
/// 实现为 `assignTodoToBucket`。
struct DragTargetOverlay: View {
    let state: HomeCalendarState
    let onDropToBucket: (UUID, TimeBucket) -> Void

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            ForEach(TimeBucket.chronologicalOrder, id: \.self) { bucket in
                DropStrip(
                    bucket: bucket,
                    taskCount: state.indexedUncompletedOccurrences(in: bucket).count,
                    onDrop: { id in onDropToBucket(id, bucket) }
                )
            }
        }
        .padding(.horizontal, WarmSpacing.xl)
        .padding(.vertical, WarmSpacing.sm)
        // 60-70% 不透明背景,让底层卡片"隐约可见" —— 用户能看到原位置参考,
        // 但 overlay 主导视觉。0.65 是经验值:再透底卡片干扰判断,再不透失去参考意义。
        .background(WarmTheme.background.opacity(0.65))
        // 入场/退场动画:opacity 渐变,跟底层 dim 同步。
        .transition(.opacity)
    }
}

/// 单条 drop 落点条带。
struct DropStrip: View {
    let bucket: TimeBucket
    let taskCount: Int
    let onDrop: (UUID) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: WarmSpacing.xs) {
                // 不挂时段图标(☀️/🌤/🌙):任务卡片左侧已有分类彩色图标,
                // 时段属于结构层,引入第二套图标系统会重复且不协调(Anytime 无合适符号)。
                // bucket 标题文字独立承担识别,跟 DayTimelineView section header 一致。
                Text(bucket.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isTargeted ? WarmTheme.primary : .secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WarmSpacing.sm)
                // Task count badge:让用户判断"这个时段多满"。
                // 0 个时仍显示数字(不隐藏)—— 否则空 bucket 看起来像无 drop 能力。
                Text("\(taskCount)")
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textSecondary)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(
                        Capsule().fill(
                            isTargeted ? WarmTheme.primary.opacity(0.18) : WarmTheme.sketch.opacity(0.2)
                        )
                    )
            }

            Spacer(minLength: 0)

            // Hover 提示:只在 isTargeted 时显示 "Release to drop",避免静态噪音。
            if isTargeted {
                Text(String(localized: "drop.release_here"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.primary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.sm)
        // 4 条等高:fixed 90-110pt 区间,idealHeight 100。
        // 用户原话「4 个 90-110pt 的条带」,这里用 flexible range 让 SwiftUI 在小屏下
        // 可微调,但不低于 90(否则 hover 提示 + count badge 挤不下)。
        .frame(maxWidth: .infinity, minHeight: 90, idealHeight: 100, maxHeight: 110)
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
                .fill(isTargeted ? WarmTheme.primary.opacity(0.12) : WarmTheme.secondaryBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
                .stroke(
                    isTargeted ? WarmTheme.primary : WarmTheme.sketch.opacity(0.35),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        // .dropDestination 接收 .draggable 发来的 UUID 字符串。
        // isTargeted 闭包驱动高亮 + haptic。
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first,
                  let id = UUID(uuidString: idString) else { return false }
            HapticFeedback.success()
            onDrop(id)
            return true
        } isTargeted: { targeted in
            // edge trigger:只在 false → true 的瞬间触发 selection haptic,
            // 避免 true → true 持续触发(理论上不会发生,但防御)。
            if targeted && !isTargeted {
                HapticFeedback.selection()
            }
            withAnimation(WarmAnimation.springFast) {
                isTargeted = targeted
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "a11y.drop_strip"), bucket.localizedTitle, taskCount))
        .accessibilityHint(String(localized: "a11y.drop_strip.hint"))
    }
}
