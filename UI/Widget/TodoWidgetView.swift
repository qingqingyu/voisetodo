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
            SmallWidgetView(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        case .systemMedium:
            MediumWidgetView(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        case .systemLarge, .systemExtraLarge:
            LargeWidgetView(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        case .accessoryRectangular:
            LockscreenRectangularWidget(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        case .accessoryCircular:
            LockscreenCircularWidget(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        case .accessoryInline:
            LockscreenInlineWidget(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        @unknown default:
            MediumWidgetView(todos: entry.todos, loadState: entry.loadState, interactionError: entry.interactionError)
        }
    }
}

enum WidgetAnimation {
    static func spring(enabled: Bool) -> Animation? {
        enabled ? .spring(duration: 0.25, bounce: 0.18) : nil
    }

    static func ease(enabled: Bool) -> Animation? {
        enabled ? .easeInOut(duration: 0.22) : nil
    }

    static func rowTransition(enabled: Bool) -> AnyTransition {
        enabled ? .push(from: .bottom) : .identity
    }

    static func errorTransition(enabled: Bool) -> AnyTransition {
        enabled ? .move(edge: .top).combined(with: .opacity) : .identity
    }

    static func toggleTransition(enabled: Bool) -> AnyTransition {
        enabled ? .scale(scale: 0.86).combined(with: .opacity) : .identity
    }

    static func opacityContent(enabled: Bool) -> ContentTransition {
        enabled ? .opacity : .identity
    }

    static func numericContent(enabled: Bool) -> ContentTransition {
        enabled ? .numericText() : .identity
    }
}

// MARK: - Small Widget

