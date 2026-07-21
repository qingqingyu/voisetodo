import SwiftUI

/// Unscheduled 底部抽屉:Calendar tab 选中日视图的底部 fixed 容器。
///
/// 折叠态:只露 grabber + header(标题 + count + chevron.up)
/// 展开态:grabber + header + ScrollView(渲染 unscheduled tasks)
///
/// **功能范围**:
/// - 卡片 `.draggable`:拖到 DayTimeline bucket slot 排程(dueDate + bucket)
/// - drawer `.dropDestination`:从 timeline 反向拖回 → 清 dueDate 回 unscheduled
/// - 折叠态命中 drop 时自动展开,让用户看清释放点
/// - 卡片不挂 swipe delete(用 tap 进详情页删除代替)
/// - 折叠/展开只走点击 chevron(不做 drag 手势,简化)
///
/// **定位**:调用方在外层 `ZStack(alignment: .bottom)` 中把 drawer 作为第二个子 view 挂在
/// Timeline 之上(不是 `.overlay`)——这样 drawer 与 Timeline 共享同一个剪裁 frame,
/// 避免 drawer 超出 Calendar tab 列表区。drawer 自身不处理 safeAreaInset(VoiceFAB 占了)。
struct UnscheduledDrawer: View {
    let todos: [TodoItemData]
    @Binding var isExpanded: Bool
    @Binding var cardAppeared: Set<UUID>
    let onToggleTodo: (UUID) -> Void
    let onOpenTodo: (TodoItemData) -> Void
    /// 反向拖拽(timeline → drawer):清 dueDate 回 unscheduled。
    /// 调用方(`HomeView`)实现 `unassignTodoFromDay`。
    let onDropToUnscheduled: (UUID) -> Void
    /// 调用方(HomeView)所在 ZStack 的可用高度,等于 Calendar tab 内容区的 `listHeight`。
    /// **契约**:必须传真实 ZStack height(非 0、非 .infinity),否则小屏下 clamp 失效。
    /// drawer 内部用此值 clamp 展开态内容区,避免占满整个 timeline 视野。
    let availableHeight: CGFloat

    /// 反向拖拽命中态:整个 drawer 描边高亮。
    /// 折叠态下命中 drop 还会自动展开 `isExpanded = true`,避免释放点不可见。
    @State private var isDropTargeted = false

    /// 展开态内容区最大高度。超过则 ScrollView 滚动。
    /// 估算:~5 张卡片(72pt 含间距) + header(50pt) + grabber(15pt) ≈ 425pt,clamp 到 360。
    static let expandedMaxHeight: CGFloat = 360
    /// 折叠态总高度(grabber + header + padding)。
    /// **注意**:这是估算值(grabber ~13pt + header ~50pt + padding)。
    /// 若 `WarmFont` / `WarmSpacing` 调整,需 re-measure 并同步此值,
    /// 否则 `expandedContentMaxHeight` 的 headroom 减法会失准,
    /// drawer 展开后多占或少占几 pt。
    static let collapsedHeight: CGFloat = 68
    /// Grabber capsule 视觉高度(5pt)。`expandedTotalHeight` 计算和 grabber 渲染
    /// 共用此值,调整时两处同步。
    private static let grabberCapsuleHeight: CGFloat = 5
    /// Drawer 内容区与 ZStack 顶部之间留的缓冲,避免 drawer 顶部完全贴 timeline 第一张卡片。
    private static let expandedContentBottomGap: CGFloat = 8
    /// 展开态 drawer 占用的总垂直空间(grabber + header + 内容区上限)。
    /// 调用方用来补偿 Timeline ScrollView 的 bottom inset。
    /// 计算:grabber capsule + 上下 WarmSpacing.xs + 内容区 `expandedMaxHeight` + 底部 WarmSpacing.lg。
    static var expandedTotalHeight: CGFloat {
        expandedMaxHeight + WarmSpacing.xs + WarmSpacing.xs + grabberCapsuleHeight + WarmSpacing.lg
    }
    /// Clamp 后的展开态总高度:受 `availableHeight` 约束时,drawer 实际占用的空间。
    /// 调用方(Timeline)用此值补偿 bottom inset。补偿值略大于真实遮挡
    /// (差值 = `expandedContentBottomGap` = 8pt),让 last card 与 drawer 顶部之间
    /// 留一点缓冲,避免视觉上完全贴住。
    /// 复用 `expandedContentMaxHeight(for:)` 的计算,保证总高与内容区高同源。
    static func expandedTotalHeightClamped(to availableHeight: CGFloat) -> CGFloat {
        collapsedHeight + expandedContentMaxHeight(for: availableHeight)
    }
    /// 内容区最大高度,受 `availableHeight` 约束。static 版供 `expandedTotalHeightClamped`
    /// 复用,实例属性 `expandedContentMaxHeight` 再转发到这里。
    private static func expandedContentMaxHeight(for availableHeight: CGFloat) -> CGFloat {
        let upper = expandedMaxHeight
        let headroom = availableHeight - collapsedHeight
        let safeHeadroom = max(0, headroom - expandedContentBottomGap)
        return min(upper, safeHeadroom)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            if isExpanded {
                ScrollView {
                    VStack(spacing: WarmSpacing.xs) {
                        ForEach(Array(todos.enumerated()), id: \.element.id) { idx, todo in
                            unscheduledCard(todo, index: idx)
                        }
                    }
                    .padding(.horizontal, WarmSpacing.md)
                    .padding(.top, WarmSpacing.xs)
                    .padding(.bottom, WarmSpacing.lg)
                }
                .frame(maxHeight: expandedContentMaxHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            // 顶部圆角 22,底部直角(贴屏幕底)
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
            .fill(WarmTheme.secondaryBackground)
        )
        .shadow(color: WarmTheme.shadowMedium, radius: 24, x: 0, y: -6)
        // 反向拖拽落点:timeline 卡片拖回 drawer → 清 dueDate。
        // 命中时若折叠态自动展开,让用户看清释放区域。
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            onDropToUnscheduled(id)
            return true
        } isTargeted: { targeted in
            if targeted && !isExpanded {
                withAnimation(WarmAnimation.springSmooth) {
                    isExpanded = true
                }
            }
            withAnimation(WarmAnimation.springFast) {
                isDropTargeted = targeted
            }
        }
        .overlay {
            if isDropTargeted {
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .stroke(WarmTheme.primary, lineWidth: 2)
            }
        }
        .accessibilityIdentifier("UnscheduledDrawer")
    }

    /// 展开态内容区高度上限,受可用空间 `availableHeight` 约束:
    /// 小屏 / Dynamic Type AX 档位下,ZStack 内容区可能比 `expandedMaxHeight` 还小,
    /// 不 clamp 会让 drawer 占满整个 timeline 视野。转发到 static 版以复用计算。
    private var expandedContentMaxHeight: CGFloat {
        Self.expandedContentMaxHeight(for: availableHeight)
    }

    // MARK: - Toggle

    /// 集中折叠/展开切换,grabber / header 两处共用。
    private func toggleExpanded() {
        withAnimation(WarmAnimation.springSmooth) {
            isExpanded.toggle()
        }
    }

    // MARK: - Grabber

    /// 顶部小条:视觉指示「这里可以拉开/收起」。点击同 header(扩大点击热区)。
    /// 用 Button + .buttonStyle(.plain) 而非裸 onTapGesture,让 VoiceOver
    /// 把 grabber 识别为可操作控件(带 accessibilityLabel),而不是无名装饰元素。
    private var grabber: some View {
        Button {
            toggleExpanded()
        } label: {
            Capsule()
                .fill(WarmTheme.sketch.opacity(0.4))
                .frame(width: 38, height: Self.grabberCapsuleHeight)
                .padding(.top, WarmSpacing.xs)
                .padding(.bottom, WarmSpacing.xs)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded
                            ? String(localized: "a11y.drawer.collapse")
                            : String(localized: "a11y.drawer.expand"))
    }

    // MARK: - Header

    private var header: some View {
        Button {
            toggleExpanded()
        } label: {
            HStack(spacing: WarmSpacing.xs) {
                Text(String(localized: "home.week.unscheduled"))
                    .font(WarmFont.headline(15))
                    .foregroundColor(WarmTheme.textPrimary)

                Text("\(todos.count)")
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.primaryDark)
                    .padding(.horizontal, WarmSpacing.xs)
                    .padding(.vertical, WarmSpacing.xxs)
                    .background(Capsule().fill(WarmTheme.primary.opacity(0.12)))

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WarmTheme.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("UnscheduledDrawerToggle")
        .accessibilityLabel(isExpanded
                            ? String(localized: "a11y.drawer.collapse")
                            : String(localized: "a11y.drawer.expand"))
    }

    // MARK: - Cards

    /// Unscheduled 卡片。复用 WarmTodoCard,挂 `.draggable` 拖到 timeline bucket slot 排程。
    /// 删除走详情页(不挂 swipeActions,本阶段简化)。
    /// 拖拽预览用 emoji + 标题的紧凑 capsule,跟 HomeSelectedDayListView 现有风格一致。
    @ViewBuilder
    private func unscheduledCard(_ todo: TodoItemData, index: Int) -> some View {
        WarmTodoCard(
            index: index,
            todo: todo,
            onToggle: { onToggleTodo(todo.id) },
            onTap: { onOpenTodo(todo) }
        )
        .cardEntrance(id: todo.id, index: index, cardAppeared: $cardAppeared)
        .draggable(todo.id.uuidString) {
            HStack(spacing: WarmSpacing.xxs) {
                Text(todo.category.emoji)
                Text(todo.title).lineLimit(1)
            }
            .font(WarmFont.caption(13))
            .padding(.horizontal, WarmSpacing.sm)
            .padding(.vertical, WarmSpacing.xs)
            .background(Capsule().fill(WarmTheme.secondaryBackground))
        }
    }
}
