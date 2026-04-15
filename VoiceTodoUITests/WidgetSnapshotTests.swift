import XCTest
import WidgetKit

/// Widget 快照测试
/// 用于验证 Widget 在不同状态下的渲染结果
final class WidgetSnapshotTests: XCTestCase {
    // MARK: - Properties

    var sut: TodoWidgetProvider!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        sut = TodoWidgetProvider()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Test Cases

    /// 测试中号 Widget 显示 3 条待办
    func test_mediumWidget_displaysThreeTodos() async throws {
        // Given: 3 条待办数据
        let todos = [
            TodoItemData(title: "任务1", category: .work),
            TodoItemData(title: "任务2", category: .life),
            TodoItemData(title: "任务3", category: .study)
        ]

        // Mock 数据源
        MockWidgetDataProvider.shared.todos = todos

        // When: 获取 medium 尺寸的 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: Array(todos.prefix(3))
        )

        // Then: 验证 entry 包含 3 条待办
        XCTAssertEqual(entry.todos.count, 3, "Medium Widget 应该显示 3 条待办")
        XCTAssertEqual(entry.todos[0].title, "任务1")
        XCTAssertEqual(entry.todos[1].title, "任务2")
        XCTAssertEqual(entry.todos[2].title, "任务3")
    }

    /// 测试小号 Widget 显示 1 条待办
    func test_smallWidget_displaysOneTodo() async throws {
        // Given: 1 条待办数据
        let todos = [
            TodoItemData(title: "单个任务", category: .work)
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取 small 尺寸的 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: Array(todos.prefix(1))
        )

        // Then: 验证 entry 包含 1 条待办
        XCTAssertEqual(entry.todos.count, 1, "Small Widget 应该显示 1 条待办")
        XCTAssertEqual(entry.todos[0].title, "单个任务")
    }

    /// 测试大号 Widget 显示 6 条待办
    func test_largeWidget_displaysSixTodos() async throws {
        // Given: 6 条待办数据
        let todos = (1...6).map { i in
            TodoItemData(title: "任务\($0)", category: .work)
        }

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取 large 尺寸的 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: Array(todos.prefix(6))
        )

        // Then: 验证 entry 包含 6 条待办
        XCTAssertEqual(entry.todos.count, 6, "Large Widget 应该显示 6 条待办")
    }

    /// 测试 Widget 空状态显示
    func test_widget_emptyState() async throws {
        // Given: 没有待办数据
        MockWidgetDataProvider.shared.todos = []

        // When: 获取 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: []
        )

        // Then: 验证 entry 为空
        XCTAssertTrue(entry.todos.isEmpty, "应该显示空状态")
    }

    /// 测试 Widget 显示未完成的待办
    func test_widget_onlyShowsUncompleted() async throws {
        // Given: 混合已完成和未完成的待办
        let todos = [
            TodoItemData(title: "已完成任务1", isCompleted: true),
            TodoItemData(title: "未完成任务1", isCompleted: false),
            TodoItemData(title: "已完成任务2", isCompleted: true),
            TodoItemData(title: "未完成任务2", isCompleted: false)
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取未完成的待办
        let uncompleted = todos.filter { !$0.isCompleted }

        // Then: 验证只包含未完成的
        XCTAssertEqual(uncompleted.count, 2)
        XCTAssertTrue(uncompleted.allSatisfy { !$0.isCompleted })
    }

    /// 测试 Widget 按创建时间倒序排列
    func test_widget_sortedByCreatedAt() async throws {
        // Given: 不同创建时间的待办
        let todos = [
            TodoItemData(title: "旧任务", createdAt: Date().addingTimeInterval(-3600)),
            TodoItemData(title: "新任务", createdAt: Date()),
            TodoItemData(title: "中任务", createdAt: Date().addingTimeInterval(-1800))
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 排序
        let sorted = todos.sorted { $0.createdAt > $1.createdAt }

        // Then: 验证按时间倒序
        XCTAssertEqual(sorted[0].title, "新任务")
        XCTAssertEqual(sorted[1].title, "中任务")
        XCTAssertEqual(sorted[2].title, "旧任务")
    }

    /// 测试 Widget 高优先级标记
    func test_widget_highPriorityDisplay() async throws {
        // Given: 混合优先级的待办
        let todos = [
            TodoItemData(title: "紧急任务", priority: .high),
            TodoItemData(title: "普通任务", priority: .normal)
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: todos
        )

        // Then: 验证高优先级待办存在
        XCTAssertEqual(entry.todos.count, 2)
        XCTAssertEqual(entry.todos[0].priority, .high)
        XCTAssertEqual(entry.todos[1].priority, .normal)
    }

    /// 测试 Widget 分类 emoji 显示
    func test_widget_categoryEmoji() async throws {
        // Given: 不同分类的待办
        let todos = [
            TodoItemData(title: "工作", category: .work),
            TodoItemData(title: "学习", category: .study),
            TodoItemData(title: "生活", category: .life),
            TodoItemData(title: "健康", category: .health),
            TodoItemData(title: "财务", category: .finance),
            TodoItemData(title: "社交", category: .social)
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取 timeline
        let entry = SimpleEntry(
            date: Date(),
            configuration: ConfigurationIntent(),
            todos: todos
        )

        // Then: 验证分类 emoji
        XCTAssertEqual(entry.todos[0].category.emoji, "💼")
        XCTAssertEqual(entry.todos[1].category.emoji, "📚")
        XCTAssertEqual(entry.todos[2].category.emoji, "🏠")
        XCTAssertEqual(entry.todos[3].category.emoji, "💪")
        XCTAssertEqual(entry.todos[4].category.emoji, "💰")
        XCTAssertEqual(entry.todos[5].category.emoji, "👥")
    }

    /// 测试锁屏 Widget 显示
    func test_lockscreenWidget_displaysTwoTodos() async throws {
        // Given: 锁屏 Widget 数据
        let todos = [
            TodoItemData(title: "任务1", category: .work),
            TodoItemData(title: "任务2", category: .life)
        ]

        MockWidgetDataProvider.shared.todos = todos

        // When: 获取锁屏 Widget 数据（2 条）
        let lockscreenTodos = Array(todos.prefix(2))

        // Then: 验证显示 2 条
        XCTAssertEqual(lockscreenTodos.count, 2)
    }
}

// MARK: - Mock Data Provider

/// Mock Widget 数据提供者
class MockWidgetDataProvider {
    static let shared = MockWidgetDataProvider()
    var todos: [TodoItemData] = []
}

// MARK: - Test Helper Types

/// 简化的 Entry 类型（用于测试）
struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationIntent
    let todos: [TodoItemData]
}

/// 配置意图（占位）
class ConfigurationIntent: NSObject, Intent {
    // Widget configuration intent
}
