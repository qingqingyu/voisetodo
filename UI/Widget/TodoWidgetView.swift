import WidgetKit
import SwiftUI
import AppIntents

/// Widget 视图
/// 支持桌面和锁屏 Widget，水印风格展示
struct TodoWidgetView: View {
    var entry: TodoEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(todos: entry.todos)
        case .systemMedium:
            MediumWidgetView(todos: entry.todos)
        case .systemLarge, .systemExtraLarge:
            LargeWidgetView(todos: entry.todos)
        case .accessoryRectangular:
            LockscreenRectangularWidget(todos: entry.todos)
        case .accessoryCircular:
            LockscreenCircularWidget(todos: entry.todos)
        case .accessoryInline:
            LockscreenInlineWidget(todos: entry.todos)
        @unknown default:
            MediumWidgetView(todos: entry.todos)
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let todos: [TodoItemData]

    var body: some View {
        Group {
            if todos.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(todos.prefix(1)) { todo in
                        TodoWidgetItemRow(todo: todo)
                    }

                    if todos.count > 1 {
                        Text("+\(todos.count - 1)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary.opacity(0.5))
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var emptyState: some View {
        WidgetEmptyState(iconSize: 28, titleSize: 14)
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let todos: [TodoItemData]

    var body: some View {
        Group {
            if todos.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos.prefix(WidgetConfig.mediumItemCount)) { todo in
                        TodoWidgetItemRow(todo: todo)
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var emptyState: some View {
        WidgetEmptyState(iconSize: 32, titleSize: 16)
    }
}

// MARK: - Large Widget

struct LargeWidgetView: View {
    let todos: [TodoItemData]

    var body: some View {
        Group {
            if todos.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos.prefix(WidgetConfig.largeItemCount)) { todo in
                        TodoWidgetItemRow(todo: todo)
                    }

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var emptyState: some View {
        WidgetEmptyState(iconSize: 40, titleSize: 18, spacing: 12)
    }
}

private struct WidgetEmptyState: View {
    let iconSize: CGFloat
    let titleSize: CGFloat
    var spacing: CGFloat = 8

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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WidgetEmptyState")
    }
}

// MARK: - Lockscreen Widgets

struct LockscreenRectangularWidget: View {
    let todos: [TodoItemData]

    var body: some View {
        if todos.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16))
                Text("VoiceTodo")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.primary.opacity(0.4))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(todos.prefix(WidgetConfig.lockscreenItemCount)) { todo in
                    HStack(spacing: 6) {
                        Button(intent: ToggleTodoIntent(todoId: todo.id.uuidString)) {
                            Image(systemName: "circle")
                                .font(.system(size: 13))
                                .foregroundColor(.primary.opacity(0.6))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text(todo.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct LockscreenCircularWidget: View {
    let todos: [TodoItemData]

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            if todos.isEmpty {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                    Text("VT")
                        .font(.system(size: 10, weight: .bold))
                }
            } else {
                VStack(spacing: 2) {
                    Text("\(todos.count)")
                        .font(.system(size: 24, weight: .bold))
                        .minimumScaleFactor(0.6)
                    Text(String(localized: "widget.todo_count"))
                        .font(.system(size: 10, weight: .medium))
                }
            }
        }
    }
}

struct LockscreenInlineWidget: View {
    let todos: [TodoItemData]

    var body: some View {
        if let firstTodo = todos.first {
            Text("\(firstTodo.category.emoji) \(firstTodo.title)")
        } else {
            Text(String(localized: "widget.no_todos"))
        }
    }
}

// MARK: - Widget Item Row

struct TodoWidgetItemRow: View {
    let todo: TodoItemData

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleTodoIntent(todoId: todo.id.uuidString)) {
                Circle()
                    .stroke(Color.primary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let destination = URL(string: "voicetodo://todo/\(todo.id.uuidString)") ?? URL(string: "voicetodo://")!
            Link(destination: destination) {
                HStack(spacing: 6) {
                    Text(todo.category.emoji)
                        .font(.system(size: 16))

                    Text(todo.title)
                        .font(.system(size: 15, weight: todo.priority == .high ? .semibold : .regular))
                        .foregroundColor(.primary.opacity(0.65))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)

                    Spacer()

                    if let dueHint = todo.dueHint {
                        Text(dueHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.65))
                    }

                    if todo.priority == .high {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
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
    ])
}

#Preview(as: .systemSmall) {
    TodoWidget()
} timeline: {
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
    ])
}

#Preview(as: .accessoryRectangular) {
    TodoWidget()
} timeline: {
    TodoEntry(date: .now, todos: [
        TodoItemData(title: "完成周报", dueHint: "今天", priority: .normal, category: .work)
    ])
}
