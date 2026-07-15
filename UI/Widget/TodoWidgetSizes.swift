import WidgetKit
import SwiftUI
import AppIntents

struct SmallWidgetView: View {
    let todos: [TodoItemData]
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    private var visibleTodos: [TodoItemData] {
        Array(todos.prefix(1))
    }

    private var extraTodoCount: Int {
        max(todos.count - visibleTodos.count, 0)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                WidgetStateView(systemName: "hourglass", title: String(localized: "widget.loading"), iconSize: 24, titleSize: 13)
            case .empty:
                emptyState
            case .error:
                WidgetStateView(systemName: "exclamationmark.triangle", title: String(localized: "widget.load_failed"), iconSize: 24, titleSize: 13)
            case .success:
                VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                    if let interactionError {
                        WidgetInteractionErrorView(error: interactionError, compact: true)
                    }

                    ForEach(visibleTodos) { todo in
                        TodoWidgetItemRow(todo: todo)
                            .id(todo)
                            .transition(WidgetAnimation.rowTransition(enabled: animationsEnabled))
                    }

                    if extraTodoCount > 0 {
                        Text("+\(extraTodoCount)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary.opacity(0.5))
                            .contentTransition(WidgetAnimation.numericContent(enabled: animationsEnabled))
                            .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: extraTodoCount)
                            .invalidatableContent()
                    }

                    Spacer(minLength: 0)
                }
                .padding()
                .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: visibleTodos)
                .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
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
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    private var visibleTodos: [TodoItemData] {
        Array(todos.prefix(WidgetConfig.mediumItemCount))
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                WidgetStateView(systemName: "hourglass", title: String(localized: "widget.loading"), iconSize: 28, titleSize: 15)
            case .empty:
                emptyState
            case .error:
                WidgetStateView(systemName: "exclamationmark.triangle", title: String(localized: "widget.load_failed"), iconSize: 28, titleSize: 15)
            case .success:
                VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                    if let interactionError {
                        WidgetInteractionErrorView(error: interactionError)
                    }

                    ForEach(visibleTodos) { todo in
                        TodoWidgetItemRow(todo: todo)
                            .id(todo)
                            .transition(WidgetAnimation.rowTransition(enabled: animationsEnabled))
                    }

                    Spacer(minLength: 0)
                }
                .padding()
                .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: visibleTodos)
                .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
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
    let loadState: TodoWidgetLoadState
    let interactionError: WidgetInteractionError?
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var animationsEnabled: Bool {
        !isLuminanceReduced
    }

    private var visibleTodos: [TodoItemData] {
        Array(todos.prefix(WidgetConfig.largeItemCount))
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                WidgetStateView(systemName: "hourglass", title: String(localized: "widget.loading"), iconSize: 36, titleSize: 17, spacing: WarmSpacing.sm)
            case .empty:
                emptyState
            case .error:
                WidgetStateView(systemName: "exclamationmark.triangle", title: String(localized: "widget.load_failed"), iconSize: 36, titleSize: 17, spacing: WarmSpacing.sm)
            case .success:
                VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                    if let interactionError {
                        WidgetInteractionErrorView(error: interactionError)
                    }

                    ForEach(visibleTodos) { todo in
                        TodoWidgetItemRow(todo: todo)
                            .id(todo)
                            .transition(WidgetAnimation.rowTransition(enabled: animationsEnabled))
                    }

                    Spacer(minLength: 0)
                }
                .padding()
                .animation(WidgetAnimation.spring(enabled: animationsEnabled), value: visibleTodos)
                .animation(WidgetAnimation.ease(enabled: animationsEnabled), value: interactionError)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var emptyState: some View {
        WidgetEmptyState(iconSize: 40, titleSize: 18, spacing: WarmSpacing.sm)
    }
}

