import WidgetKit
import SwiftUI

/// Widget Bundle
/// 注册所有 Widget 样式（包括待办 Widget 和 Live Activity）
@main
struct TodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodoWidget()
        RecordingLiveActivity()
    }
}

/// 主 Widget 定义
struct TodoWidget: Widget {
    let kind: String = "TodoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodoTimelineProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.display_name"))
        .description(String(localized: "widget.description"))
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
