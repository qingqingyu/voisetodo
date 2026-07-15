import SwiftUI
import UIKit

struct HomeMonthHeaderView: View {
    let state: HomeCalendarState
    let onShift: (Int) -> Void
    let onJumpToToday: () -> Void
    let onSelectDay: (Date) -> Void
    let onSetViewMode: (CalendarViewMode) -> Void
    /// 从 Unscheduled 拖任务到日期格时触发（UUID = 任务，Date = 格子日期）。
    var onDropTodo: ((UUID, Date) -> Void)? = nil
    /// 当前是否停在今天——true 时隐藏"回今天"按钮（此时按钮无意义）。
    var isOnToday: Bool = false
    /// 可用高度（来自 GeometryReader）。0 = 不约束，用默认行高。
    var availableHeight: CGFloat = 0

    /// 根据可用高度计算日期格行高。
    /// 固定段（导航行 + 星期表头 + spacing + padding）≈ 90pt（见 calendarFixedSectionHeight）；
    /// 剩余空间平分给网格行（月视图 6 行 / 周视图 1 行）。
    /// availableHeight = 0 时回退到默认 WarmSpacing.xxxl（48pt）。
    private var dayRowHeight: CGFloat {
        HomeLayoutMetrics.dayRowHeight(availableHeight: availableHeight, viewMode: state.viewMode)
    }

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            HStack {
                // 回今天按钮：仅在非今天时显示（已停在今天时按钮无意义，省掉一个控件）。
                if !isOnToday {
                    Button(action: onJumpToToday) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WarmTheme.primaryDark)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(WarmTheme.secondaryBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TodayMonthButton")
                    .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.today_week" : "a11y.today_month"))
                }

                Button(action: { onShift(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PreviousMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.previous_week" : "a11y.previous_month"))

                Text(state.monthTitle)
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                Button(action: { onShift(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(WarmTheme.secondaryBackground))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NextMonthButton")
                .accessibilityLabel(String(localized: state.viewMode == .week ? "a11y.next_week" : "a11y.next_month"))
            }

            HStack(spacing: WarmSpacing.xs) {
                ForEach(state.weekHeaderDays, id: \.self) { day in
                    Text(state.weekdayTitle(for: day))
                        .font(WarmFont.caption(11))
                        .foregroundColor(WarmTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: WarmSpacing.xs), count: 7), spacing: WarmSpacing.xs) {
                ForEach(state.visibleDays, id: \.self) { day in
                    HomeMonthDayButton(
                        dayState: state.dayState(for: day),
                        onSelect: onSelectDay,
                        onDropTodo: onDropTodo.map { callback in { id in callback(id, day) } },
                        rowHeight: dayRowHeight
                    )
                }
            }
        }
        // 手势切换月/周:上滑→周(放大细节),下滑→月(缩小概览)。
        // 挂在整个 VStack(导航行 + 星期表头 + 日期格),让用户在日历任意位置上下拉都能切换——
        // 不再局限于导航行那一小条。用 SimultaneousDragGesture(UIKit UIGestureRecognizer 包装)
        // 让日期格 Button tap 和拖拽共存;iOS 26 起 SwiftUI .simultaneousGesture 在含 Button 的
        // 容器内失效(FB18199844),改走 UIKit 路径恢复同时识别。
        .gesture(
            SimultaneousDragGesture(minimumDistance: HomeLayoutMetrics.viewModeDragThreshold) { drag in
                let vertical = abs(drag.translation.height)
                let horizontal = abs(drag.translation.width)
                guard vertical > horizontal else { return }
                if drag.translation.height < -HomeLayoutMetrics.viewModeDragThreshold,
                   state.viewMode != .week {
                    onSetViewMode(.week)
                } else if drag.translation.height > HomeLayoutMetrics.viewModeDragThreshold,
                          state.viewMode != .month {
                    onSetViewMode(.month)
                }
            }
        )
        // VoiceOver 用户无法做拖拽手势——提供自定义 rotor action 切换视图模式
        .accessibilityAction(named: Text(state.viewMode == .month
                                         ? String(localized: "a11y.switch_to_week")
                                         : String(localized: "a11y.switch_to_month"))) {
            onSetViewMode(state.viewMode == .month ? .week : .month)
        }
        .padding(.horizontal, WarmSpacing.lg)
        .padding(.top, WarmSpacing.xxs)
        .padding(.bottom, WarmSpacing.sm)
        .background(WarmTheme.background.opacity(0.94))
    }
}

// MARK: - Home layout constants

enum HomeLayoutMetrics {
    /// 月历区域目标上限比例（对齐 HTML 参考的 max-height:38vh）。
    static let calendarTargetHeightRatio: CGFloat = 0.38
    /// 月历表头固定段高度（导航行 + 星期表头 + VStack spacing + padding）。
    /// 拆解：navRow(32) + weekday(16) + VStack spacing(WarmSpacing.xs×2≈16)
    ///       + top/bottom padding(xxs+sm≈16) + 动态字体浮动余量(~10) ≈ 90pt 保守上限。
    /// 低估会导致 calendarHeight 算出比实际小，底部日期行被 `.clipped()` 裁切（Bug 1 根因）。
    static let calendarFixedSectionHeight: CGFloat = 90
    /// 单行日期格最小高度：优先保证 14pt 日期数字可读。
    static let dayRowMinHeight: CGFloat = 14
    /// 底部 VoiceFAB 的可视高度：FAB 直径 + 底部 padding。
    static let bottomBarHeight: CGFloat = WarmSize.fab + WarmSpacing.md
    /// 底部列表渐隐只负责贴近底部浮动操作簇的过渡，不能覆盖到中部 todo 卡片。
    static let bottomListFadeHeight: CGFloat = 40
    /// 列表底部滚动留白，用 contentMargins 作用在真实 scroll content 上，而不是追加假 Section。
    /// 组成：底部操作簇高度 + 渐隐区 + 额外呼吸空间，确保最后一项能完整停在按钮上方。
    /// 调参规则：
    /// - 改 VoiceFAB 布局（直径、padding）时必须重新测量 safeAreaInset 实占高度。
    static let listBottomInset: CGFloat = bottomBarHeight + bottomListFadeHeight + WarmSpacing.xl
    /// 空状态 top inset：加大让内容接近屏幕视觉中心（~40-45% 高度）。
    static let emptyStateTopInset: CGFloat = 80
    /// 月/周视图切换的拖拽阈值（pt）。超过此距离才判定为切换手势，
    /// 避免点击按钮或日期格时的轻微滑动误触发。同时用于 minimumDistance 和方向判定。
    static let viewModeDragThreshold: CGFloat = 40

    /// 圆点直径跟 rowHeight 自适应（改动 A）：
    /// 之前用固定 dayRowDotSize=4 + dayRowDotsVisibleThreshold=24，
    /// 但月视图实际 dayRowHeight 可能 ≈16pt，圆点跟数字挤一起。
    /// 现在按行高动态返回圆点尺寸，矮屏隐藏圆点保证数字清爽。
    /// - rowHeight < 26：返回 nil（14pt headline 的 lineHeight~19pt + 圆点3 + padding4 ≈ 26，
    ///   低于此值圆点跟数字中心距离 <5pt，视觉上挤）
    /// - 26-32：返回 3
    /// - 33-44：返回 3.5
    /// - ≥45：返回 4（周视图典型）
    static func dotSize(for rowHeight: CGFloat) -> CGFloat? {
        switch rowHeight {
        case ..<26: return nil
        case 26...32: return 3
        case 33...44: return 3.5
        default: return 4
        }
    }
    /// 周视图单行期望高度（舒适触摸目标 + 视觉留白）。
    /// 周视图只有 1 行，若套用 38% cap 会把单行撑到 128pt 过高；
    /// 这里用固定 48pt 让周视图紧凑，腾出更多空间给列表。
    static let weekDesiredRowHeight: CGFloat = 48

    /// 月历区域高度（容器封顶值，不直接决定行高）。
    /// 设计意图（对齐 HTML 参考 `max-height:38vh; overflow:hidden`）：
    ///   - **月视图**：6 行内容通常接近 38% cap，直接用 cap 让 dayRowHeight 自适应撑满。
    ///   - **周视图**：1 行内容远低于 38%，若套用 cap 会把单行撑到 128pt 过高；
    ///     改用 content-driven（header + 1 行 48pt = 178pt），列表获得更多空间。
    /// 与 `dayRowHeight` 的契约：本函数返回容器高度，`dayRowHeight` 在容器内独立计算行高
    /// （`max(dayRowMinHeight, (container - fixedSection - spacing) / rows)`）。
    /// 极矮屏（maxCap < 178）下周视图 dayRowHeight 会 < 48，容器底部可能被 `.clipped()` 裁切，
    /// 这是已知取舍（与月视图一致）：列表区至少 62% 不可妥协。
    static func calendarHeight(availableHeight: CGFloat, selectedTab: BottomTab, viewMode: CalendarViewMode) -> CGFloat {
        guard selectedTab == .calendar, availableHeight > 0 else { return 0 }
        let maxCap = availableHeight * calendarTargetHeightRatio
        switch viewMode {
        case .month:
            return maxCap
        case .week:
            let contentHeight = calendarFixedSectionHeight + weekDesiredRowHeight
            return min(maxCap, contentHeight)
        }
    }

    static func dayRowHeight(availableHeight: CGFloat, viewMode: CalendarViewMode) -> CGFloat {
        guard availableHeight > 0 else { return WarmSpacing.xxxl }
        let rows = rowCount(for: viewMode)
        let usable = max(0, availableHeight - calendarFixedSectionHeight - gridSpacing(forRows: rows))
        return max(dayRowMinHeight, usable / rows)
    }

    private static func rowCount(for viewMode: CalendarViewMode) -> CGFloat {
        switch viewMode {
        case .month:
            return 6
        case .week:
            return 1
        }
    }

    private static func gridSpacing(forRows rows: CGFloat) -> CGFloat {
        WarmSpacing.xs * max(0, rows - 1)
    }
}

struct HomeMonthDayButton: View {
    let dayState: HomeCalendarDayState
    let onSelect: (Date) -> Void
    /// 拖拽 drop 回调——从 Unscheduled 拖任务到日期格时触发。
    var onDropTodo: ((UUID) -> Void)? = nil
    var rowHeight: CGFloat = WarmSpacing.xxxl

    @State private var isDropTargeted = false

    /// 圆点尺寸跟 rowHeight 自适应（改动 A）：
    /// 月视图 18pt 行高下返回 3pt，周视图 48pt 行高下返回 4pt。
    /// 极矮屏（< 16pt）返回 nil，不渲染圆点。
    private var dotSize: CGFloat? {
        HomeLayoutMetrics.dotSize(for: rowHeight)
    }

    var body: some View {
        Button {
            onSelect(dayState.date)
        } label: {
            // 数字在 .frame(height: rowHeight) 容器里默认居中；
            // 圆点 overlay 挂在容器上（不是 Text 上），钉在 rowHeight 底部。
            // （之前挂在 Text + .frame(maxHeight: .infinity) 上——Text 实际撑不满 rowHeight，
            // overlay 底部只是 Text 高度的底部，圆点跟数字挤在一起。）
            // 纯数字（5/29 等），不用 .formatted(.dateTime.day(.twoDigits))
            // 后者在 zh locale 下产生"29日"，与日期格上下文冲突显冗余。
            // VoiceOver 文案仍走 VoiceOverLabel.monthDayText（带"6月29日"完整表达），
            // 视觉显示与无障碍朗读职责分离。
            Text("\(Calendar.current.component(.day, from: dayState.date))")
                .font(WarmFont.headline(14))
                .foregroundColor(dayState.isSelected ? .white : (dayState.isCurrentMonth ? WarmTheme.textPrimary : WarmTheme.textMuted))
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .overlay(alignment: .bottom) {
                if let dotSize, !dayState.occurrences.isEmpty {
                    let hasUncompletedOccurrence = dayState.occurrences.contains { !$0.isCompleted }
                    Circle()
                        .fill(
                            dayState.isSelected ? Color.white :
                            (hasUncompletedOccurrence ? WarmTheme.primary : WarmTheme.textMuted)
                        )
                        .frame(width: dotSize, height: dotSize)
                    .padding(.bottom, WarmSpacing.xxs)
                }
            }
            // 选中态放大：弱动画提示用户"我点对了"，但不夸张到挤压相邻格
            // （月历 7 列宽，放大太多会重叠）。Reduce Motion 时 animation 会被系统忽略。
            .scaleEffect(dayState.isSelected ? WarmAnimation.monthDaySelectedScale : WarmAnimation.monthDayDefaultScale)
            .animation(WarmAnimation.springSmooth, value: dayState.isSelected)
            // 改动 B：背景简化——
            // - 选中：实心 primary 背景 + 白字（白字在 fill 上面，靠 foregroundColor 控制）
            // - 今天未选中：primary 0.18 浅填充（视觉锚点，替代原来的 stroke 边框）
            // - 其他：裸背景（无填充、无边框、无阴影），让圆点成为主视觉标记
            // 删除的内容：Color.white.opacity(0.9/0.45) 白底、stroke 边框、shadow 阴影
            .background {
                if dayState.isSelected {
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(WarmTheme.primary)
                } else if dayState.isToday {
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(WarmTheme.primary.opacity(0.18))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceOverLabel.build(for: dayState))
        .accessibilityHint(String(localized: "a11y.day.hint"))
        .accessibilityAddTraits(dayState.isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("MonthDay_\(dayState.date.formatted(.dateTime.year().month().day()))")
        // 拖拽：从 Unscheduled 拖任务到日期格 → 赋日期
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            onDropTodo?(id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .stroke(WarmTheme.primary, lineWidth: 2)
                    .scaleEffect(1.15)
                    .padding(2)
            }
        }
        .animation(WarmAnimation.springFast, value: isDropTargeted)
    }
}

/// VoiceOver 文案构造：把日历单元格的状态翻译成完整一句话。
/// 月视图单元格视觉信息（数字、点、底色）对低视力/盲人用户没用，必须用文字补全。
/// 顺序遵循可达性惯例：身份（日期）在前，状态（非当月/今天/待办数）在后。
/// 使用 app 当前本地化语言 + gregorian 日历格式化日期，避免系统区域语言与 app 文案混读。
