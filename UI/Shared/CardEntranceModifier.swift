import SwiftUI

/// 卡片入场动画共享包装。
///
/// 把"opacity 从 0→1 + y offset 20→0 + onAppear 延迟 insert 到 cardAppeared set +
/// scale/opacity transition"这组行为集中到一个 modifier,
/// 让使用方保持单一来源,改参数只改这里。
/// 当前唯一使用方:`UnscheduledDrawer`。
///
/// **迁移状态**:`HomeSelectedDayListView` 仍保留旧的内联实现(本 PR 范围外),
/// 后续 follow-up 应迁移到本 modifier 以彻底单一来源化。
///
/// **绑定语义**:`cardAppeared` 由调用方(`HomeView`)拥有,跨子 view 共享。
/// 同一个 UUID 第一次 onAppear 时被 insert 并触发 spring 动画;后续重建
/// (切日、tab 切换)若 UUID 已在 set 中,直接显示不重放。
struct CardEntranceModifier: ViewModifier {
    let id: UUID
    let index: Int
    @Binding var cardAppeared: Set<UUID>

    func body(content: Content) -> some View {
        content
            .opacity(cardAppeared.contains(id) ? 1 : 0)
            .offset(y: cardAppeared.contains(id) ? 0 : 20)
            .onAppear {
                withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
                    _ = cardAppeared.insert(id)
                }
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.9).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            ))
    }
}

extension View {
    /// 套用 `CardEntranceModifier`。`id` 用于去重,`index` 用于 stagger delay。
    func cardEntrance(
        id: UUID,
        index: Int,
        cardAppeared: Binding<Set<UUID>>
    ) -> some View {
        modifier(CardEntranceModifier(id: id, index: index, cardAppeared: cardAppeared))
    }
}
