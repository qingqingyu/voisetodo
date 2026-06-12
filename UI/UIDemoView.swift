import SwiftUI

/// UI 组件演示视图
/// 用于在开发阶段预览所有组件
struct UIDemoView: View {
    @StateObject private var store = MockStore.preview
    @State private var showConfirmSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastStyle: ToastStyle = .info
    @State private var extractedTodos: [ExtractedTodo] = []

    var body: some View {
        NavigationView {
            List {
                // MARK: - Toast 演示
                Section("Toast 组件演示") {
                    Button("显示 Info Toast") {
                        toastMessage = ErrorMessages.savedOffline
                        toastStyle = .info
                        showToast = true
                    }

                    Button("显示 Success Toast") {
                        toastMessage = ErrorMessages.addedSuccess
                        toastStyle = .success
                        showToast = true
                    }

                    Button("显示 Warning Toast") {
                        toastMessage = ErrorMessages.noTodosFound
                        toastStyle = .warning
                        showToast = true
                    }
                }

                // MARK: - EmptyState 演示
                Section("空状态演示") {
                    NavigationLink("HomeView - 空状态") {
                        HomeView(store: MockStore.empty)
                            .navigationTitle("空状态示例")
                            .environmentObject(AppCoordinator.preview)
                            .environmentObject(PermissionManager())
                    }

                    NavigationLink("HomeView - 有数据") {
                        HomeView(store: MockStore.preview)
                            .navigationTitle("有数据示例")
                            .environmentObject(AppCoordinator.preview)
                            .environmentObject(PermissionManager())
                    }
                }

                // MARK: - ConfirmSheet 演示
                Section("确认弹窗演示") {
                    Button("打开确认弹窗") {
                        extractedTodos = [
                            ExtractedTodo(title: "完成周报", detail: "", dueHint: "今天", priority: .normal, categoryHint: .work),
                            ExtractedTodo(title: "准备面试", detail: "", dueHint: "周三前", priority: .high, categoryHint: .work),
                            ExtractedTodo(title: "去健身房", detail: "", dueHint: nil, priority: .normal, categoryHint: .health)
                        ]
                        showConfirmSheet = true
                    }
                }

                // MARK: - 组件预览
                Section("组件独立预览") {
                    NavigationLink("ToastView 预览") {
                        VStack(spacing: 20) {
                            ToastView(message: "信息提示", style: .info)
                            ToastView(message: "成功提示", style: .success)
                            ToastView(message: "警告提示", style: .warning)
                        }
                        .padding()
                        .navigationTitle("ToastView")
                    }

                    NavigationLink("EmptyStateView 预览") {
                        VStack(spacing: 40) {
                            EmptyStateView.homeEmpty()
                                .frame(height: 200)
                                .border(Color.gray)

                            EmptyStateView.widgetEmpty()
                                .frame(height: 150)
                                .border(Color.gray)

                            EmptyStateView.lockscreenEmpty()
                                .frame(height: 100)
                                .border(Color.gray)
                        }
                        .padding()
                        .navigationTitle("EmptyStateView")
                    }

                    NavigationLink("TodoItemRow 预览") {
                        VStack(spacing: 12) {
                            ForEach(extractedTodos.indices, id: \.self) { index in
                                TodoItemRow(
                                    index: index,
                                    todo: $extractedTodos[index],
                                    onDelete: {
                                        extractedTodos.remove(at: index)
                                    }
                                )
                            }
                        }
                        .padding()
                        .navigationTitle("TodoItemRow")
                    }
                }

                // MARK: - Mock 数据状态
                Section("Mock 数据状态") {
                    HStack {
                        Text("总待办数")
                        Spacer()
                        Text("\(store.todos.count)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("未完成")
                        Spacer()
                        Text("\(store.todos.filter { !$0.isCompleted }.count)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("高优先级")
                        Spacer()
                        Text("\(store.todos.filter { $0.priority == .high }.count)")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("UI 组件演示")
            .sheet(isPresented: $showConfirmSheet) {
                ConfirmSheetView(
                    transcript: "明天去银行办卡，顺便买菜，晚上给老妈打电话",
                    todos: $extractedTodos,
                    onConfirm: { confirmedTodos in
                        try? store.addBatch(confirmedTodos)
                        toastMessage = "已添加 \(confirmedTodos.count) 条待办"
                        toastStyle = .success
                        showToast = true
                    },
                    onCancel: {
                        toastMessage = "已取消"
                        toastStyle = .info
                        showToast = true
                    }
                )
            }
            .toast(message: toastMessage, style: toastStyle, isPresented: $showToast)
        }
    }
}

// MARK: - Preview

#Preview {
    UIDemoView()
}

// MARK: - 使用说明

/**
 UI 组件演示使用指南：

 1. **Toast 演示**：
    - 点击按钮显示不同样式的 Toast
    - Toast 会在 2 秒后自动消失

 2. **EmptyState 演示**：
    - 查看主页空状态和有数据状态的区别
    - 对比不同场景的空状态设计

 3. **ConfirmSheet 演示**：
    - 打开确认弹窗
    - 尝试编辑、删除待办
    - 点击确认或取消

 4. **组件独立预览**：
    - 查看每个组件的独立效果
    - 测试交互和动画

 5. **Mock 数据**：
    - 查看当前 Mock 数据状态
    - 可以在 MockStore.swift 中修改预设数据

 注意：
 - 所有数据都是 Mock 数据，不会持久化
 - 真实集成需要 Agent E 完成
 - Toast 使用 ErrorMessages 常量作为文案
 */
