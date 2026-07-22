import AppIntents
import SwiftUI

/// Siri 查询结果 snippet 视图。
///
/// 布局与 `AddTodoIntentView` 对齐(prefix(5) + "还有 N 条" + "在 App 中查看"链接),
/// 但因为查询可能返回**已完成**的任务,需要展示完成态(勾选 + 灰化 + 删除线)。
/// 不接受 `[ExtractedTodo]`(AddTodoIntentView 的类型),改接受 `[TodoEntity]`,
/// 因为查询返回的是持久化的 `TodoItem` 投影,不是 AI 提取结果。
struct QueryTodosIntentView: View {
    let todos: [TodoEntity]
    let status: TodoStatusFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(todos, id: \.id) { todo in
                HStack(spacing: 8) {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(todo.isCompleted ? Color.green : Color.secondary)

                    Text(todo.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(todo.isCompleted ? Color.secondary : Color.primary)
                        .strikethrough(todo.isCompleted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if todo.priority == .high && !todo.isCompleted {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if let hint = todo.dueHint, !todo.isCompleted {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if todos.isEmpty {
                Text(String(localized: "siri.query.empty"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            Divider()
                .padding(.vertical, 4)

            Link(destination: URL(string: "voicetodo://home")!) {
                HStack {
                    Spacer()
                    Text(String(localized: "siri.result.view_in_app"))
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                    Spacer()
                }
            }
        }
        .padding(12)
    }
}
