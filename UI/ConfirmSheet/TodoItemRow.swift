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
    /// 流式期间点击卡片的反馈:抖动 + 通知父级(由父级决定怎么显示提示)。
    /// 提示文案/位置/样式不在本行视图管 —— 父级 ConfirmSheetView 用底部 toast 呈现,
    /// 不在卡片上挂 overlay(避免遮挡 + 视觉重)。
    /// 抽到父级的原因:toast 状态(streamingToastVisible)归 ConfirmSheetView 持有,
    /// 与 row 的 @State 解耦,row 重建(流式帧覆盖)不会丢 toast 状态。
    let onStreamingTap: () -> Void

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
        // 单卡容器:头部(显示区) + 编辑面板(展开时) 共用同一个圆角 + 阴影 + 边框,
        // 中间 1pt 横线(WarmTheme.divider)分隔。视觉关系明确为「这个条目被展开编辑」,
        // 而非「两张卡拼接」。
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
                        // 收起态任务名 15pt(.system):比展开态 20pt 小一级,保持"展开=主对象"层级;
                        // .system 而非 WarmFont — 与编辑面板字体策略一致(中文走苹方混排更稳)。
                        Text(todo.title)
                            .font(.system(size: 15, weight: .semibold))
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
                                    .font(.system(size: 12))
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
                            // 12pt(四档下限):徽标虽是 UI 装饰,但本次视觉重设计要求字号四档化,
                            // 不引入四档外的尺寸。比旧 11pt 大 1pt,徽标略更可读。
                            .font(.system(size: 12, weight: .regular))
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
                    // 流式期间禁用 + 变淡(同一层级):与编辑入口禁用一致,
                    // 传达「这条先别操作」。不隐藏 —— 隐藏会让用户误以为
                    // 「这条不能删 = 没这条」。opacity 与 disabled 同挂 Button,
                    // 保持「视觉反馈」与「行为禁用」在同一修饰层级,后续维护一处改一处。
                    .disabled(isStreaming)
                    .opacity(isStreaming ? 0.5 : 1.0)
                    .accessibilityIdentifier("DeleteTodo_\(index)")
                    .accessibilityLabel(String(localized: "a11y.delete"))
                    .accessibilityHint(String(localized: "a11y.delete_todo"))
                }
                // 内容左右对称 16pt:leading=12 因为左侧色条已占 4pt(4+12=16=trailing)。
                // 历史:原 leading=8/trailing=16 不对称,让内容偏左;改对称强化「独立卡」感。
                .padding(.leading, WarmSpacing.sm)
                .padding(.trailing, WarmSpacing.md)
                .padding(.vertical, WarmSpacing.sm)
            }
            // 抖动只作用于卡片头部,不连带下方展开面板。
            // 流式禁用展开,两条路径互斥,但语义上 ShakeEffect 应只管「卡片」本身。
            .modifier(ShakeEffect(attempt: shakeAttempt))

            // 展开态:1pt 横线分隔显示区 / 编辑区,编辑面板就地嵌入同一张卡。
            // 用 Rectangle+WarmTheme.divider 而非 Divider:Divider 自身渲染系统灰,
            // .background(WarmTheme.divider) 不会改变它的线条色,需直接 fill。
            if isExpanded {
                Rectangle()
                    .fill(WarmTheme.divider)
                    .frame(height: 1)
                    .transition(.opacity)

                TodoDraftEditorPanel(
                    todo: $todo,
                    index: index,
                    onCollapse: {
                        withAnimation(WarmAnimation.springStandard) {
                            expandedTodoID = nil
                        }
                    }
                )
                // 编辑面板 padding 对称 16,与头部内容左右对齐(同属一张卡)。
                .padding(.leading, WarmSpacing.md)
                .padding(.trailing, WarmSpacing.md)
                .padding(.bottom, WarmSpacing.sm)
                .padding(.top, WarmSpacing.sm)
                .transition(.opacity)
            }
        }
        // 单卡统一背景:圆角 12 + 扩散阴影(radius=8 y=2)+ 浅描边(防脏边)。
        // 历史:旧 radius=2 y=1 阴影太贴近卡片形成一圈脏边,改 radius=8 让阴影更柔和;
        // 浅描边 0.06 opacity 放在 shadow 之后,确保不被阴影模糊吃掉 ——
        // 描边是「卡轮廓的最后一道边界」,必须在阴影之外可见。
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.card)
                .fill(WarmTheme.cardBackground)
        )
        .shadow(color: WarmTheme.shadowLight, radius: 8, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: WarmRadius.card)
                .strokeBorder(WarmTheme.textPrimary.opacity(0.06), lineWidth: 1)
        )
        .offset(x: offset)
        .opacity(opacity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("TodoRow_\(index)")
        .accessibilityHint(String(localized: "a11y.expand_todo"))
        .onTapGesture {
            // 流式未结束禁用展开:ExtractedTodo 实例会被流式帧覆盖,
            // 此时展开的编辑会被吃掉(决策:流式禁用而非 carry over)。
            // 反馈:抖一下 + 通知父级显示底部 toast,让用户知道点到了但当前不可操作。
            // 提示不在卡片上挂 overlay —— 遮挡内容 + 视觉重(参见 onStreamingTap 注释)。
            guard !isStreaming else {
                withAnimation(WarmAnimation.springFast) {
                    shakeAttempt += 1
                }
                onStreamingTap()
                return
            }
            withAnimation(WarmAnimation.springStandard) {
                expandedTodoID = (expandedTodoID == todo.id) ? nil : todo.id
            }
        }
        .onDisappear {
            deleteTask?.cancel()
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
    /// 流式期间被点击时触发(透传给 TodoItemRow,由 ConfirmSheetView 显示底部 toast)。
    let onStreamingTap: () -> Void

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
            },
            onStreamingTap: onStreamingTap
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
                TodoItemRow(index: 0, todo: $todo1, expandedTodoID: $expandedTodoID, isStreaming: false, onDelete: {}, onStreamingTap: {})
                TodoItemRow(index: 1, todo: $todo2, expandedTodoID: $expandedTodoID, isStreaming: false, onDelete: {}, onStreamingTap: {})
            }
            .padding()
            .background(WarmTheme.background)
        }
    }

    return PreviewWrapper()
}
