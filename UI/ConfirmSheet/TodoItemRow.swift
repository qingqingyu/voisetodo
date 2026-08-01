import SwiftUI

/// 横向抖动效果,用于流式期间点卡片的反馈。
/// animatableData 从旧值动画到新值,sin 函数让它左右晃 ~2 次。
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    init(attempt: Int) {
        self.animatableData = CGFloat(attempt)
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(animatableData * .pi * 4) * 6
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

/// 流式期间「暂时不能编辑」提示的显示时长常量(本文件内复用)。
/// 与 ConfirmSheetView.OperationHintFooter.visibleDurationNanos 同性质,
/// 但作用域仅本行视图,不外提至 UIConfig。
private enum StreamingHintDisplay {
    static let durationNanos: UInt64 = 1_500_000_000
}

/// 待办条目行视图。
/// 用于 ConfirmSheetView 中显示单个待办。
///
/// 重设计(2026-07):对齐 jul-redesign.html 参考。
/// - 左侧 4pt 分类色条(对齐 HTML .item::before)
/// - 时间字段改胶囊底色,颜色与色条同系(对齐 HTML .time)
/// - emoji 入场缩放动画(对齐 HTML .emoji bump)
/// - 删除按钮 28×28 圆形灰底(对齐 HTML .del)
///
/// 点击卡片就地展开成 TodoDraftEditorPanel(accordion),流式期间禁用展开
/// (避免 ExtractedTodo 实例被流式帧覆盖吃掉用户编辑)。
struct TodoItemRow: View {
    let index: Int
    @Binding var todo: ExtractedTodo
    @Binding var expandedTodoID: UUID?
    let isStreaming: Bool
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1.0
    /// 删除动画的 unstructured task 句柄。视图销毁 / 重复点击时必须 cancel,
    /// 否则 sleep 结束后仍会调 onDelete()——闭包捕获的 @Binding todo 可能已失效。
    /// 用 `Task<Void, Error>` 而非 `Never`:Task.sleep 闭包 throwing(只 throw
    /// CancellationError),Failure=Never 编译失败。
    @State private var deleteTask: Task<Void, Error>?
    /// 删除动画的 generation 计数。每次 performDelete 递增,catch 块用它判断
    /// 「自己是否还是最新 task」。
    /// **为什么不用 `Task === task`**:`Task` 是 struct,Swift 不允许 struct 用
    /// `===` 比较句柄;`Task` 也没有公开的 `id` 属性。改用整数 generation 计数,
    /// 捕获时拷贝当前值,catch 时跟 @State 当前值比较。
    @State private var deleteTaskGeneration: Int = 0
    /// 流式期间点击卡片的抖动反馈:递增触发 ShakeEffect。
    @State private var shakeAttempt: Int = 0
    /// 流式期间点击后短暂显示「解析中暂时不能编辑」提示。
    @State private var showStreamingHint: Bool = false
    /// 提示自动隐藏 task。重复点击时 cancel 重启。
    @State private var hintHideTask: Task<Void, Never>?

    private var isExpanded: Bool { expandedTodoID == todo.id }

    /// 卡片内的时间串:不传 relativeDateText(分组标题已带日期,避免冗余),
    /// 让 composer 只拼「钟点 / 模糊时段 / dueHint 兜底」。
    private var composedTimeText: String? {
        TodoTimeDisplayComposer.compose(
            recurrenceRule: todo.recurrenceRule,
            relativeDateText: nil,
            timeText: todo.dueTime,
            dueHint: todo.dueHint,
            timeBucketText: todo.timeBucket?.localizedTitle
        )
    }

    private var categoryColor: Color {
        WarmTheme.color(for: todo.categoryHint)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 左侧分类色条:4pt 宽,圆角小条,对齐 HTML .item::before
                RoundedRectangle(cornerRadius: 2)
                    .fill(categoryColor)
                    .frame(width: 4)
                    .padding(.vertical, 4)

                HStack(alignment: .center, spacing: WarmSpacing.sm) {
                    Text(todo.categoryHint.emoji)
                        .font(.system(size: 22))
                        .id(todo.id)
                        .modifier(EmojiBumpModifier())
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                        Text(todo.title)
                            .font(WarmFont.headline(16))
                            .foregroundColor(WarmTheme.textPrimary)
                            // 主内容不允许截断:用户在校对 AI 提取的内容,看全是关键。
                            // 长标题靠自然换行承接,sheet 内容可滚动。
                            .accessibilityIdentifier("TodoTitleText_\(index)")

                        // 时间行:钟点 / 模糊时段 / dueHint 兜底。
                        // 拼装逻辑抽到 TodoTimeDisplayComposer,这里只渲染。
                        if let timeText = composedTimeText {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                Text(timeText)
                                    .font(WarmFont.caption(12))
                            }
                            .foregroundColor(categoryColor)
                            .padding(.horizontal, WarmSpacing.xs)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(WarmTheme.categoryBackground(for: todo.categoryHint))
                            )
                            .accessibilityIdentifier("TodoTimeText_\(index)")
                        }
                    }

                    Spacer(minLength: WarmSpacing.xs)

                    if todo.priority == .high {
                        Text(String(localized: "confirm.urgent"))
                            .font(WarmFont.caption(11))
                            .foregroundColor(.white)
                            .padding(.horizontal, WarmSpacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: WarmRadius.chip)
                                    .fill(WarmTheme.urgent)
                            )
                            .accessibilityIdentifier("PriorityLabel")
                            .accessibilityLabel(String(localized: "a11y.high_priority"))
                    }

                    Button(action: performDelete) {
                        ZStack {
                            Circle()
                                .fill(WarmTheme.subtleControlBackground)
                                .frame(width: 28, height: 28)
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(WarmTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("DeleteTodo_\(index)")
                    .accessibilityLabel(String(localized: "a11y.delete"))
                    .accessibilityHint(String(localized: "a11y.delete_todo"))
                }
                .padding(.leading, WarmSpacing.xs)
                .padding(.trailing, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.sm)
            }
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 2, y: 1)
            )
            // 抖动只作用于卡片头部,不连带下方展开面板。
            // 流式禁用展开,两条路径互斥,但语义上 ShakeEffect 应只管「卡片」本身。
            .modifier(ShakeEffect(attempt: shakeAttempt))
            // 提示 overlay 也挂卡片头部底部,不漂到面板下方。
            .overlay(alignment: .bottom) {
                if showStreamingHint {
                    Text(String(localized: "confirm.streaming_cannot_edit"))
                        .font(WarmFont.caption(12))
                        .foregroundColor(.white)
                        .padding(.horizontal, WarmSpacing.sm)
                        .padding(.vertical, WarmSpacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.textMuted)
                        )
                        .transition(.opacity)
                }
            }

            // 展开态:卡片下方就地挂编辑面板(accordion),与卡片共用圆角背景。
            // 面板改动直接写回 @Binding todo,点 Add N 时一并提交。
            if isExpanded {
                TodoDraftEditorPanel(
                    todo: $todo,
                    index: index,
                    onCollapse: {
                        withAnimation(WarmAnimation.springStandard) {
                            expandedTodoID = nil
                        }
                    }
                )
                .padding(.leading, WarmSpacing.xs)
                .padding(.trailing, WarmSpacing.md)
                .padding(.bottom, WarmSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: WarmRadius.card)
                        .fill(WarmTheme.cardBackground)
                        // 与卡片同 shadow:展开态卡片 + 面板视觉上拼接成一张抬升的纸面,
                        // 若只卡片有 shadow 而面板没有,拼接处会出现阴影断层。
                        .shadow(color: WarmTheme.shadowLight, radius: 2, y: 1)
                )
                .transition(.opacity)
            }
        }
        .offset(x: offset)
        .opacity(opacity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("TodoRow_\(index)")
        .accessibilityHint(String(localized: "a11y.expand_todo"))
        .onTapGesture {
            // 流式未结束禁用展开:ExtractedTodo 实例会被流式帧覆盖,
            // 此时展开的编辑会被吃掉(决策:流式禁用而非 carry over)。
            // 反馈:抖一下 + 短暂提示,让用户知道点到了但当前不可操作。
            guard !isStreaming else {
                withAnimation(WarmAnimation.springFast) {
                    shakeAttempt += 1
                    showStreamingHint = true
                }
                hintHideTask?.cancel()
                hintHideTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: StreamingHintDisplay.durationNanos)
                    } catch is CancellationError {
                        // 重复点击或视图销毁时 cancel 重启——预期路径,直接返回。
                        // 与本文件 deleteTask 的 catch is CancellationError 模式一致,
                        // 不用 try? 吞 CancellationError(符合 CLAUDE.md 错误显式传播)。
                        return
                    } catch {
                        // 不可达:Task.sleep 只 throw CancellationError。但 Task<Void, Never>
                        // 闭包签名 non-throwing,do/catch 需穷尽否则整体 throws 编译失败。
                        return
                    }
                    withAnimation(WarmAnimation.springFast) {
                        showStreamingHint = false
                    }
                }
                return
            }
            withAnimation(WarmAnimation.springStandard) {
                expandedTodoID = (expandedTodoID == todo.id) ? nil : todo.id
            }
        }
        .onDisappear {
            deleteTask?.cancel()
            hintHideTask?.cancel()
        }
    }

    // MARK: - Actions

    private func performDelete() {
        // 重复点击或动画途中再次触发:cancel 旧 task(旧 task 的 catch 会判断
        // "自己是否还是 deleteTask 最新值",是才复位视觉状态,避免与新 task 的
        // 动画打架),再起新 task。保持删除动画可打断 + 不累积多个 onDelete 调用。
        deleteTask?.cancel()
        deleteTaskGeneration += 1
        let generation = deleteTaskGeneration
        let task = Task { @MainActor in
            withAnimation(WarmAnimation.springFast) {
                offset = 300
                opacity = 0
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(UIConfig.deleteAnimationDuration * 1_000_000_000))
            } catch is CancellationError {
                // 不静默吞(违反 CLAUDE.md 错误显式传播),显式 catch CancellationError。
                // 仅当当前 generation 仍是最新值(即视图未销毁且未被新 performDelete
                // 覆盖)时才复位视觉状态:若已被新 task 覆盖,让新 task 的 withAnimation 独占,
                // 避免连击时旧 task 的复位与新 task 的位移动画互相打架。
                guard deleteTaskGeneration == generation else { return }
                withAnimation(WarmAnimation.springFast) {
                    offset = 0
                    opacity = 1
                }
                return
            }
            // 双重 guard:await 后视图可能已销毁(虽然 onDisappear cancel 了 task,
            // 但 cancel 信号送达有窗口),用 Task.isCancelled 兜底防止调用已失效闭包。
            guard !Task.isCancelled else { return }
            onDelete()
        }
        deleteTask = task
    }
}

// MARK: - Helper:Delete Wrapper

/// 辅助视图:处理待办删除逻辑。从原 ConfirmSheetView.swift 移入,
/// 让删除逻辑与 row 视图同文件管理。
/// 透传 expandedTodoID/isStreaming 给 TodoItemRow;删除正在展开的卡片时
/// 把 expandedTodoID 置 nil,收起面板。
struct TodoItemRowWithDelete: View {
    let index: Int
    @Binding var todo: ExtractedTodo
    @Binding var todos: [ExtractedTodo]
    @Binding var expandedTodoID: UUID?
    let isStreaming: Bool

    var body: some View {
        TodoItemRow(
            index: index,
            todo: $todo,
            expandedTodoID: $expandedTodoID,
            isStreaming: isStreaming,
            onDelete: {
                if expandedTodoID == todo.id {
                    withAnimation(WarmAnimation.springStandard) {
                        expandedTodoID = nil
                    }
                }
                withAnimation(.easeOut(duration: UIConfig.deleteAnimationDuration)) {
                    todos.removeAll { $0.id == todo.id }
                }
            }
        )
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var todo1 = ExtractedTodo(
            title: "完成周报",
            detail: "",
            dueHint: "今天",
            priority: .normal,
            categoryHint: .work
        )
        @State var todo2 = ExtractedTodo(
            title: "准备面试",
            detail: "",
            dueHint: "周三前",
            priority: .high,
            categoryHint: .work
        )
        @State var expandedTodoID: UUID?

        var body: some View {
            VStack(spacing: 12) {
                TodoItemRow(index: 0, todo: $todo1, expandedTodoID: $expandedTodoID, isStreaming: false, onDelete: {})
                TodoItemRow(index: 1, todo: $todo2, expandedTodoID: $expandedTodoID, isStreaming: false, onDelete: {})
            }
            .padding()
            .background(WarmTheme.background)
        }
    }

    return PreviewWrapper()
}
