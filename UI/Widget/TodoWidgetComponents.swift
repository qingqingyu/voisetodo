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
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    if let interactionError {
                        WidgetInteractionErrorView(error: interactionError, compact: true)
                    }

                    ForEach(visibleTodos) { todo in
                        Toggle(isOn: todo.isCompleted, intent: ToggleTodoIntent(todoId: todo.id.uuidString)) {
                            HStack(spacing: WarmSpacing.xs) {
                                Text(todo.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .strikethrough(todo.isCompleted)
                                    .lineLimit(1)
                                    .contentTransition(WidgetAnimation.opacityContent(enabled: animationsEnabled))
                                    .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: todo.isCompleted)
                                    .invalidatableContent()

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .toggleStyle(WidgetTodoToggleStyle(iconSize: 13, uncheckedOpacity: 0.6, animationsEnabled: animationsEnabled))
                        .id(todo)
                        .transition(WidgetAnimation.rowTransition(enabled: animationsEnabled))
                    }
                }
                .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: visibleTodos)
                .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
            }
        }
        .containerBackground(.clear, for: .widget)
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
                            Text("\(todos.count)")
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
                Text("\(firstTodo.category.emoji) \(firstTodo.title)")
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
                .frame(minWidth: WarmSize.touch, minHeight: WarmSize.touch)
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

#Preview(as: .systemSmall) {
    TodoWidget()
} timeline: {
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
    ], loadState: .success)
}

#Preview(as: .accessoryRectangular) {
    TodoWidget()
} timeline: {
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
    ], loadState: .success)
}
