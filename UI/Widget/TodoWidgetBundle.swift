import WidgetKit
import SwiftUI
import Intents

/// Widget Bundle（Agent D 实现）
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
        IntentConfiguration(
            kind: kind,
            intent: ConfigurationIntent.self,
            provider: TodoTimelineProvider()
        ) { entry in
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

/// 配置 Intent（用于 Widget 配置选项，V1 可暂时为空）
class ConfigurationIntent: Intent {
    init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // V2 可以添加配置选项，比如：
    // - 显示已完成/未完成
    // - 按分类筛选
    // - 自定义显示数量
}
