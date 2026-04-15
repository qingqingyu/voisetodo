import WidgetKit
import SwiftUI

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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.primary.opacity(0.4))
            Text("暂无待办")
                .font(.system(size: 14))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let todos: [TodoItemData]

    var body: some View {
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.primary.opacity(0.4))
            Text("暂无待办")
                .font(.system(size: 16))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large Widget

struct LargeWidgetView: View {
    let todos: [TodoItemData]

    var body: some View {
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.primary.opacity(0.4))
            Text("暂无待办")
                .font(.system(size: 18))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        Text(todo.category.emoji)
                            .font(.system(size: 12))
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
                    Text("待办")
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
            Text("暂无待办")
        }
    }
}

// MARK: - Widget Item Row

struct TodoWidgetItemRow: View {
    let todo: TodoItemData

    var body: some View {
        // 使用 Link 实现点击跳转
        let destination = URL(string: "voicetodo://todo/\(todo.id.uuidString)") ?? URL(string: "voicetodo://")!
        Link(destination: destination) {
            HStack(spacing: 8) {
                // 分类 emoji
                Text(todo.category.emoji)
                    .font(.system(size: 16))

                // 标题
                Text(todo.title)
                    .font(.system(size: 15, weight: todo.priority == .high ? .semibold : .regular))
                    .foregroundColor(.primary.opacity(0.65))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)

                Spacer()

                // 时间标签
                if let dueHint = todo.dueHint {
                    Text(dueHint)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.65))
                }

                // 优先级标签
                if todo.priority == .high {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
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
