import WidgetKit
import SwiftUI
import AppIntents

struct WidgetEmptyState: View {
    let iconSize: CGFloat
    let titleSize: CGFloat
    var spacing: CGFloat = WarmSpacing.xs

    var body: some View {
        VStack(spacing: spacing) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: iconSize * 1.9, height: iconSize * 1.9)

                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: iconSize * 1.35, height: iconSize * 1.35)

                Image(systemName: "checkmark.circle")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundColor(.primary.opacity(0.42))
            }

            Text(String(localized: "empty.widget.today"))
                .font(.system(size: titleSize, weight: .medium))
                .foregroundColor(.primary.opacity(0.48))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(WarmSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WidgetEmptyState")
    }
}

struct WidgetStateView: View {
    let systemName: String
    let title: String
    let iconSize: CGFloat
    let titleSize: CGFloat
    var spacing: CGFloat = WarmSpacing.xs

    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .light))
                .foregroundColor(.primary.opacity(0.42))

            Text(title)
                .font(.system(size: titleSize, weight: .medium))
                .foregroundColor(.primary.opacity(0.52))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(WarmSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WidgetStateView")
    }
}

struct WidgetInteractionErrorView: View {
    let error: WidgetInteractionError
    var compact = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    var body: some View {
        Label(String(localized: LocalizedStringResource(stringLiteral: error.messageKey)), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundColor(.orange.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .contentTransition(WidgetAnimation.opacityContent(enabled: animationsEnabled))
            .transition(WidgetAnimation.errorTransition(enabled: animationsEnabled))
            .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: error)
            .invalidatableContent()
    }
}

// MARK: - Lockscreen Widgets

struct LockscreenRectangularWidget: View {
    let todos: [TodoItemData]
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    private var visibleTodos: [TodoItemData] {
        Array(todos.prefix(WidgetConfig.lockscreenItemCount))
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                lockscreenState(systemName: "hourglass", title: String(localized: "widget.loading"))
            case .empty:
                VStack(spacing: WarmSpacing.xxs) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16))
                    Text("VoiceTodo")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary.opacity(0.4))
            case .error:
                lockscreenState(systemName: "exclamationmark.triangle", title: String(localized: "widget.load_failed"))
            case .success:
                // 三行统一字号:从阶梯最大档往下取第一个能让所有标题单行放下的档位。
                // 旧实现是每行独立 minimumScaleFactor(0.8),长标题行自行缩小,
                // 导致三条字号不一致;阶梯方案保证同字号且永不出现 …。
                ViewThatFits(in: .horizontal) {
                    lockscreenRows(fontSize: 16)
                    lockscreenRows(fontSize: 15)
                    lockscreenRows(fontSize: 14)
                    lockscreenRows(fontSize: 13)
                    lockscreenRows(fontSize: 12)
                    lockscreenRows(fontSize: 11)
                }
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    /// 一个"三行同字号"的候选视图,配合外层 ViewThatFits 按阶梯尝试。
    /// 标题 Text 用 fixedSize(horizontal:) 让 ideal width 等于单行完整宽度,
    /// ViewThatFits 以此判定该档位能否放下;被选中的档位所有行同字号、不截断。
    /// 极端超长标题(连 11pt 都放不下)会溢出到组件边缘被裁切,而非显示 …。
    private func lockscreenRows(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let interactionError {
                WidgetInteractionErrorView(error: interactionError, compact: true)
            }

            ForEach(visibleTodos) { todo in
                Toggle(isOn: todo.isCompleted, intent: ToggleTodoIntent(todoId: todo.id.uuidString)) {
                    HStack(spacing: WarmSpacing.xs) {
                        Text(todo.title)
                            .font(.system(size: fontSize, weight: .medium))
                            .strikethrough(todo.isCompleted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(WidgetAnimation.opacityContent(enabled: animationsEnabled))
                            .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: todo.isCompleted)
                            .invalidatableContent()

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .toggleStyle(WidgetTodoToggleStyle(iconSize: 13, uncheckedOpacity: 0.6, animationsEnabled: animationsEnabled, hitTarget: nil))
                .id(todo)
                .transition(WidgetAnimation.rowTransition(enabled: animationsEnabled))
            }
        }
        .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: visibleTodos)
        .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
    }

    private func lockscreenState(systemName: String, title: String) -> some View {
        VStack(spacing: WarmSpacing.xxs) {
            Image(systemName: systemName)
                .font(.system(size: 15))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundColor(.primary.opacity(0.45))
    }
}

struct LockscreenCircularWidget: View {
    let todos: [TodoItemData]
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    var body: some View {
        Group {
            ZStack {
                AccessoryWidgetBackground()

                switch loadState {
                case .loading:
                    Image(systemName: "hourglass")
                        .font(.system(size: 18))
                case .empty:
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                        Text("VT")
                            .font(.system(size: 10, weight: .bold))
                    }
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18))
                case .success:
                    if interactionError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.orange.opacity(0.9))
                            .transition(WidgetAnimation.errorTransition(enabled: animationsEnabled))
                            .invalidatableContent()
                    } else {
                        VStack(spacing: 2) {
                            Text(verbatim: "\(todos.count)")
                                .font(.system(size: 24, weight: .bold))
                                .minimumScaleFactor(0.6)
                                .contentTransition(WidgetAnimation.numericContent(enabled: animationsEnabled))
                                .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: todos.count)
                                .invalidatableContent()
                            Text(String(localized: "widget.todo_count"))
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                }
            }
            .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
        }
        .containerBackground(.clear, for: .widget)
    }
}

struct LockscreenInlineWidget: View {
    let todos: [TodoItemData]
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?

    var body: some View {
        Group {
            if loadState == .loading {
                Text(String(localized: "widget.loading"))
            } else if loadState == .error {
                Text(String(localized: "widget.load_failed"))
            } else if let interactionError {
                Text(String(localized: LocalizedStringResource(stringLiteral: interactionError.messageKey)))
                    .invalidatableContent()
            } else if let firstTodo = todos.first {
                Text(verbatim: "\(firstTodo.category.emoji) \(firstTodo.title)")
            } else {
                Text(String(localized: "widget.no_todos"))
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Widget Item Row

struct TodoWidgetItemRow: View {
    let todo: TodoItemData
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    var body: some View {
        HStack(spacing: WarmSpacing.xs) {
            Toggle(isOn: todo.isCompleted, intent: ToggleTodoIntent(todoId: todo.id.uuidString)) {
                EmptyView()
            }
            .toggleStyle(WidgetTodoToggleStyle(animationsEnabled: animationsEnabled))

            let destination = URL(string: "voicetodo://todo/\(todo.id.uuidString)") ?? URL(string: "voicetodo://")!
            Link(destination: destination) {
                HStack(spacing: WarmSpacing.xs) {
                    Text(todo.category.emoji)
                        .font(.system(size: 16))

                    Text(todo.title)
                        .font(.system(size: 15, weight: todo.priority == .high ? .semibold : .regular))
                        .foregroundColor(todo.isCompleted ? .primary.opacity(0.42) : .primary.opacity(0.65))
                        .strikethrough(todo.isCompleted)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .contentTransition(WidgetAnimation.opacityContent(enabled: animationsEnabled))
                        .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: todo.isCompleted)
                        .invalidatableContent()

                    Spacer()

                    if let dueHint = todo.dueHint {
                        Text(dueHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.65))
                    }

                    if todo.priority == .high {
                        Circle()
                            .fill(Color.red)
                            .frame(width: WarmSpacing.xs, height: WarmSpacing.xs)
                    }
                }
            }
        }
        .id(todo)
        .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: todo.isCompleted)
        .invalidatableContent()
    }
}

struct WidgetTodoToggleStyle: ToggleStyle {
    var iconSize: CGFloat = 20
    var uncheckedOpacity: Double = 0.4
    var animationsEnabled = true
    /// 圆圈图标的最小 hit target。nil 表示不强制(锁屏矩形组件等空间紧张的容器);
    /// 默认 WarmSize.touch(44pt)用于桌面 widget,保证 HIG 触控热区。
    /// 注意:Toggle 整行可点击(label + 圆圈),缩小圆圈的 min frame 不影响触控可用性。
    var hitTarget: CGFloat? = WarmSize.touch

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: WarmSpacing.xs) {
            ZStack {
                if configuration.isOn {
                    toggleImage(systemName: "checkmark.circle.fill", color: .green.opacity(0.85))
                        .transition(WidgetAnimation.toggleTransition(enabled: animationsEnabled))
                } else {
                    toggleImage(systemName: "circle", color: .primary.opacity(uncheckedOpacity))
                        .transition(WidgetAnimation.toggleTransition(enabled: animationsEnabled))
                }
            }
                .frame(minWidth: hitTarget, minHeight: hitTarget)
                .contentShape(Rectangle())
                .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: configuration.isOn)
                .invalidatableContent()

            configuration.label
        }
    }

    private func toggleImage(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundColor(color)
            .contentTransition(WidgetAnimation.opacityContent(enabled: animationsEnabled))
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    TodoWidget()
} timeline: {
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work),
        TodoItemData(title: "准备面试", dueHint: "周三前", priority: .high, category: .work),
        TodoItemData(title: "去健身房", dueHint: nil, priority: .normal, category: .health)
    ], loadState: .success)
}

#Preview(as: .accessoryRectangular) {
    TodoWidget()
} timeline: {
    // 三条长短不一,验证 ViewThatFits 阶梯选中同一档位、三行同字号
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "买咖啡豆", dueHint: nil, priority: .normal, category: .life),
        TodoItemData(title: "完成周报并发给组长", dueHint: nil, priority: .normal, category: .work),
        TodoItemData(title: "下午三点和小林开产品评审会", dueHint: nil, priority: .normal, category: .work)
    ], loadState: .success)
}
