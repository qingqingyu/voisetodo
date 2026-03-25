import WidgetKit
import SwiftUI

/// Widget Bundle
/// 注册所有 Widget 样式
@main
struct TodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodoWidget()
    }
}

/// 主 Widget 定义
struct TodoWidget: Widget {
    let kind: String = "TodoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodoTimelineProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("待办事项")
        .description("查看最近的待办")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}
