import XCTest
@testable import VoiceTodoProtocols

final class ProtocolsTests: XCTestCase {

    func testPriorityRawValue() {
        XCTAssertEqual(Priority.high.rawValue, "high")
        XCTAssertEqual(Priority.normal.rawValue, "normal")
    }

    func testTodoCategoryEmoji() {
        XCTAssertEqual(TodoCategory.work.emoji, "💼")
        XCTAssertEqual(TodoCategory.study.emoji, "📚")
        XCTAssertEqual(TodoCategory.life.emoji, "🏠")
    }

    func testExtractedTodoCreation() {
        let todo = ExtractedTodo(title: "测试任务")
        XCTAssertEqual(todo.title, "测试任务")
        XCTAssertEqual(todo.priority, .normal)
        XCTAssertEqual(todo.categoryHint, .other)
    }

    func testTodoItemDataCreation() {
        let item = TodoItemData(title: "测试")
        XCTAssertEqual(item.title, "测试")
        XCTAssertFalse(item.isCompleted)
    }

    func testTodoItemDataFromExtracted() {
        let extracted = ExtractedTodo(title: "测试", detail: "详情")
        let item = TodoItemData(from: extracted)
        XCTAssertEqual(item.title, "测试")
        XCTAssertEqual(item.detail, "详情")
    }

    func testExtractionResultDecoding() throws {
        let json = """
        {
            "todos": [{"id": "00000000-0000-0000-0000-000000000001", "title": "任务", "detail": "", "priority": "normal", "categoryHint": "work"}],
            "ignored": ""
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        XCTAssertEqual(result.todos.count, 1)
        XCTAssertEqual(result.todos[0].title, "任务")
    }

    func testVoiceTodoErrorEquality() {
        XCTAssertEqual(VoiceTodoError.networkUnavailable, .networkUnavailable)
        XCTAssertEqual(VoiceTodoError.apiTimeout, .apiTimeout)
    }
}
