import SwiftUI
import AppIntents

/// Siri 结果卡片视图
/// 在 Siri 界面展示已添加的待办列表
struct AddTodoIntentView: View {
    let todos: [ExtractedTodo]
    let isOffline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(todos.prefix(5)) { todo in
                HStack(spacing: 8) {
                    Text(todo.categoryHint.emoji)
                        .font(.system(size: 14))

                    Text(todo.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if todo.priority == .high {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if let hint = todo.dueHint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let recurrenceRule = todo.recurrenceRule {
                        Label(recurrenceRule.displayText, systemImage: "repeat")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if todos.count > 5 {
                Text(String(localized: "siri.result.more \(todos.count - 5)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if isOffline {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12))
                    Text(String(localized: "siri.result.offline"))
                        .font(.system(size: 13))
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
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
