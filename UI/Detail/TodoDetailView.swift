import SwiftUI
import UIKit
import WidgetKit

private func formattedDetailDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}

/// 下滑关闭跟手手势常量(file-private 顶层 —— TodoDetailView<Store> 是泛型,Swift 不允许泛型类型内有 static stored properties)。
/// 规格:docs/todo-detail-swipe-dismiss.md v2(方案 B,起手锁定)。
/// 两段式语义:起手时键盘弹起 → 本手势只收键盘(见 dismissDragGesture 的 onChanged);
/// 收键盘的主通道仍是点空白区(body 的 onTapGesture)。
private enum DismissDragConfig {
    /// 手势识别最小位移。要跟手就必须小,旧值 40pt 会让前 40pt 页面不动。
    /// ~10pt 同时是 UIPanGestureRecognizer 的内置 began 门槛,再小无意义。
    static let minimumDistance: CGFloat = 10
    /// 松手关闭的位移阈值。
    static let dismissTranslation: CGFloat = 120
    /// 松手关闭的速度阈值(pt/s)。位移不足但甩得快也关。
    static let dismissVelocity: CGFloat = 800
    /// 视觉插值行程:offset 到这个值时 scale/圆角/grabber 达到终点。
    static let visualTravel: CGFloat = 260
    /// 页面最小缩放。
    static let minScale: CGFloat = 0.94
    /// 页面最大圆角(= WarmRadius.sheet)。
    static let maxCornerRadius: CGFloat = WarmRadius.sheet
}

/// 顶部 chrome 常量:自绘 header + grabber 区(方案 B.6/B.7)。
private enum DetailChromeMetrics {
    /// 自绘 header 行高(对齐系统导航栏 44pt)。
    static let headerHeight: CGFloat = 44
    /// grabber 胶囊:高恒 5pt,宽随拖拽 38 → 48pt(基础规格复用 UnscheduledDrawer)。
    static let grabberHeight: CGFloat = 5
    static let grabberBaseWidth: CGFloat = 38
    static let grabberExtraWidth: CGFloat = 10
    /// grabber 不透明度曲线(B.3):静止 0.4,随 progress 插值到 0.7;
    /// 越过关闭阈值时直接跳 0.7 给离散信号(对齐 HTML 原型)。
    static let grabberBaseAlpha: CGFloat = 0.4
    static let grabberPeakAlpha: CGFloat = 0.7
    /// grabber 区高 = 胶囊 + 上下 WarmSpacing.xs(8pt) padding = 21pt。
    static var grabberZoneHeight: CGFloat { grabberHeight + WarmSpacing.xs * 2 }
    /// chrome 默认总高 = header(44) + grabber 区(21) = 65pt(标准 Dynamic Type 档)。
    /// header 行用 minHeight:44 只设下限 —— 标题字体 WarmFont.headline 随 Dynamic Type
    /// 缩放(AX4/AX5 单行行高 > 44),chrome 实际高度会更高,toast 让位量必须实测
    /// (见 body 的 measuredChromeHeight),不能锁死本常量。
    static var defaultChromeHeight: CGFloat { headerHeight + grabberZoneHeight }
    /// compact toast 顶部留白 = chrome 实际高度 + WarmSpacing.xs(8)。
    /// 标准档 = 65 + 8 = 73pt:toast(~36pt 高)落在 grabber 与标题卡之间,
    /// 内容顶 padding 仍为 48(xxxl),标题卡顶在 chrome 下 113pt,toast 底(+109pt)
    /// 与卡顶留 4pt 呼吸 —— 与旧布局(导航栏下 toast 8~44 / 卡顶 48)同构。
    /// 注:文档 B.7 曾估"padding 收到 24",实测账算不过 —— 36pt 的 toast 需要完整空隙,维持 48。
    static func toastTopPadding(chromeHeight: CGFloat) -> CGFloat { chromeHeight + WarmSpacing.xs }
}

/// 待办详情页 - 温暖主题风格
/// 支持编辑标题、备注、分类、优先级、日期（DatePicker）、重复，以及标记完成/删除
struct TodoDetailView<Store: TodoListReadable>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var store: Store
    /// 编辑基准。@State 持有:每次 debounce 自动保存成功后同步此值,
    /// 避免「保存后继续编辑」时 checkForChanges 用旧基准误判(用户改回原值会被认为没改)。
    /// 历史问题:原为 `let todo`,onDisappear 一次性保存;改为实时保存后必须可写。
    ///
    /// **@State 语义注意**:SwiftUI @State 在 `init` 设置初始值后,父视图刷新传新值时
    /// **不会重新初始化**此 @State。这意味着:如果父视图(HomeView)中该 todo 被其他流程
    /// (Siri Intent / Widget toggle)更新,Detail 页看到的仍是旧值。
    /// 当前业务下详情页是 modal push,生命周期短,接受此权衡。如果未来出现"详情页常驻 +
    /// 外部数据源可变"场景,需要改用 ObservableObject ViewModel 包装。
    @State private var todo: TodoItemData

    @State private var editedTitle: String
    @State private var editedDetail: String
    @State private var editedCategory: TodoCategory
    @State private var editedPriority: Priority
    @State private var editedDueDate: Date?
    @State private var editedHasDueTime: Bool
    @State private var editedTimeBucket: TimeBucket?
    /// 提醒提前量(nil = 准时)。仅带钟点时有意义;清钟点时 persistChanges 会一并清掉。
    @State private var editedReminderOffsetMinutes: Int?
    @State private var editedRecurrenceFrequency: RecurrenceFrequency?
    @State private var editedWeekdays: Set<Int>
    /// weekly 重复的 interval:1=每周、2=双周、3=三周、≥4=fallback。
    /// 跟 frequency/weekdays 同级独立 @State:详情页 chip 暴露"双周/三周"两个独立选项,
    /// 选中时同时设 frequency=.weekly + interval=N。原来没有这个字段,
    /// 导致 AI 返回的 interval=2/3 待办进详情页再保存时被静默重置为 1。
    @State private var editedInterval: Int
    @State private var editedDayOfMonth: Int
    /// 重复任务结束日期(nil = 无限循环)。对应 RecurrenceRule.endDate 持久化字段。
    /// AI 走 RecurrenceEnd 归一化分类(5 种 kind)经 RecurrenceEndResolver 算出具体 Date 写入此字段;
    /// 用户编辑走绝对日期(Toggle + DatePicker),不归一化。
    @State private var editedEndDate: Date?
    @State private var hasChanges = false
    @State private var showDeleteConfirmation = false
    /// 防抖保存 task。用户每次改字段都会 cancel + 重启;800ms 内无新改动才真正写库。
    /// onDisappear 时 cancel 并立即静默保存,保证用户离开时一定落盘。
    @State private var saveTask: Task<Void, Never>?

    /// 软件键盘是否弹起。由 keyboardWillShow/Hide 通知驱动(与 HomeView.keyboardHeight 同套路)。
    /// 仅作「下滑手势」两段式语义的判定源:键盘弹起 → 下滑只收键盘不关页
    /// (见 dismissDragGesture 的 onChanged 起手快照)。
    /// 收键盘的主通道是点页面非功能空白区(body 的 onTapGesture),
    /// 左上角 chevron.down 按钮恒为「关闭页面」,不参与收键盘。
    /// 用键盘通知而非 @FocusState 判定:硬件键盘连接时焦点在但键盘不出现,
    /// 此时下滑直接走关闭语义,不会被隐形焦点劫持成无视觉反馈的 no-op。
    @State private var isKeyboardVisible = false

    // MARK: - 下滑关闭跟手(方案 B,起手锁定;规格 docs/todo-detail-swipe-dismiss.md v2)

    /// 跟手位移(pt)。0 = 静止;正值 = 页面下移。上滑 clamp 到 0。
    @State private var dismissDragOffset: CGFloat = 0
    /// 本手势是否激活(首帧 onChanged 置位,onEnded/onCancelled 复位)。
    /// 起手语义快照只在此刻捕获 —— 不能用 `dismissDragOffset == 0` 当"起手"信号:
    /// 回弹动画进行中 offset ≠ 0 时再抓,键盘判定会被跳过,出现"键盘挂着页面却跟手"。
    @State private var isDragActive = false
    /// 起手锁定快照:手势门控闭包首次被 UIKit 问询时记录的「起手时 ScrollView 是否在顶」。
    /// nil = 无进行中手势。true/false 一经锁定,整段手势沿用 —— 起手不在顶的手势
    /// 门控恒 false,整段交回系统 ScrollView(保留其 bounce/惯性),本页不跟手。
    @State private var dragGateLockedAtTop: Bool?
    /// 本次手势是否只用于收键盘(起手时键盘弹起)。为 true 时不驱动 offset。
    @State private var dragGestureKeyboardOnly = false
    /// 是否已越过关闭阈值(haptic 只在上升沿触发一次,回落复位后可再触发)。
    @State private var didCrossDismissThreshold = false
    /// chrome(自绘 header + grabber)实测高度。header 标题随 Dynamic Type 缩放,
    /// AX4/AX5 下行高超过 44pt 下限 → chrome 高于默认 65pt;compact toast 的让位量
    /// 用实测值才能在所有字号档位避开 grabber(旧系统导航栏高度自适应,无此问题)。
    /// onGeometryChange 首帧前用默认值兜底,首帧后持续跟随(字体档位/语言切换)。
    @State private var measuredChromeHeight: CGFloat = DetailChromeMetrics.defaultChromeHeight

    init(store: Store, todo: TodoItemData) {
        self.store = store
        _todo = State(initialValue: todo)
        _editedTitle = State(initialValue: todo.title)
        _editedDetail = State(initialValue: todo.detail ?? "")
        _editedCategory = State(initialValue: todo.category)
        _editedPriority = State(initialValue: todo.priority)
        _editedDueDate = State(initialValue: todo.dueDate)
        _editedHasDueTime = State(initialValue: todo.hasDueTime)
        _editedTimeBucket = State(initialValue: todo.timeBucket)
        _editedReminderOffsetMinutes = State(initialValue: todo.reminderOffsetMinutes)
        _editedRecurrenceFrequency = State(initialValue: todo.recurrenceRule?.frequency)
        _editedWeekdays = State(initialValue: Set(todo.recurrenceRule?.weekdays ?? []))
        _editedInterval = State(initialValue: todo.recurrenceRule?.interval ?? 1)
        // 默认值用当前日:与 recurrenceModeButton 切到 .monthly 时的 fallback 一致。
        // 模型 dayOfMonth 1...31, Picker 也限制 1...31, 永远合法 —— 不再需要 validation。
        _editedDayOfMonth = State(initialValue: todo.recurrenceRule?.dayOfMonth ?? Calendar.current.component(.day, from: Date()))
        // endDate 跟 AI 提取的 recurrence_end 解析后写入的字段对齐(RecurrenceEnd.swift 注释:
        // "解析后写入 RecurrenceRule.endDate 这一单一真相")。详情页让用户改 endDate 是绝对日期,
        // 不走 RecurrenceEnd 归一化分类(那是 AI 自动设置的语义路径)。
        _editedEndDate = State(initialValue: todo.recurrenceRule?.endDate)
    }

    private var categoryColor: Color { WarmTheme.color(for: editedCategory) }

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                VStack(spacing: WarmSpacing.lg) {
                    // 标题
                    VStack(alignment: .leading) {
                        HStack(spacing: WarmSpacing.xs) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(categoryColor)
                                .frame(width: 4, height: WarmSpacing.xl)
                            Text(String(localized: "detail.section.title"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                        }
                        TextField(String(localized: "detail.title_placeholder"), text: $editedTitle, axis: .vertical)
                            // 20pt：比 Notes(14pt) 拉开明显级差，确立标题是页面视觉重心
                            // （原先 18pt vs Notes 16pt 太接近，两者读起来重量差不多）。
                            .font(WarmFont.headline(20))
                            .foregroundColor(WarmTheme.textPrimary)
                            .lineLimit(1...2)
                            .onChange(of: editedTitle) { _, _ in checkForChanges() }
                    }
                    .padding(WarmSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.sheet)
                            .fill(Color.white)
                            .shadow(color: WarmTheme.shadowMedium, radius: 10, x: 0, y: 5)
                    )

                    // 备注（issue 3：新增 Notes 字段）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.notes"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            // 14pt：比 Title(20pt) 明显降一级，正文不再跟标题抢视觉重量；
                            // 字号收小后满宽文本块的视觉密度也随之减轻（原 16pt 显得笨重）。
                            TextField(String(localized: "detail.notes_placeholder"), text: $editedDetail, axis: .vertical)
                                .font(WarmFont.body(14))
                                .foregroundColor(WarmTheme.textPrimary)
                                .lineLimit(1...3)
                                .onChange(of: editedDetail) { _, _ in checkForChanges() }
                        }
                    }

                    // 时间(日期 + 时段合并):一个整体卡,日期区在上、Divider、时段区在下。
                    // 之前是两个独立 detailCard,违背语音场景「下午提醒我」的语义完整性——
                    // 用户要分两步理解「哪天 + 什么时段」,合并后一眼看到完整时间。
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.time"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)

                            // 日期区形态由重复档位派生(RecurrenceAnchorPolicy.dateRowMode):
                            // - .dueDate(无重复):「日期」DatePicker + ✕ / 「添加日期」按钮 —— 原行为不变
                            // - .startAnchor(双周/三周):「起始日期」DatePicker,无 ✕ —— 锚点决定 occurs() 的
                            //   weekDiff % interval,清掉会退回 createdAt 让用户看不见也控制不了「从哪一周开始」
                            // - .hidden(daily/weekly(interval==1)/monthly):整行不渲染 —— 锚点只是下界或
                            //   靠 dayOfMonth 自锚,暴露出来只会跟重复卡语义打架
                            let dateRowMode = RecurrenceAnchorPolicy.dateRowMode(
                                frequency: editedRecurrenceFrequency,
                                interval: editedInterval
                            )
                            if dateRowMode == .dueDate {
                                if editedDueDate != nil {
                                    HStack {
                                        TodoDatePopoverTrigger(date: $editedDueDate, onEdit: checkForChanges)
                                        Spacer()
                                        Button {
                                            editedDueDate = nil
                                            editedHasDueTime = false
                                            checkForChanges()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(WarmTheme.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else {
                                    Button {
                                        self.editedDueDate = DayClock.startOfUserDay(for: Date())
                                        checkForChanges()
                                    } label: {
                                        HStack(spacing: WarmSpacing.xs) {
                                            Image(systemName: "calendar")
                                                .font(.system(size: 15))
                                            Text(String(localized: "detail.add_date"))
                                                .font(WarmFont.body(16))
                                        }
                                        .foregroundColor(WarmTheme.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else if dateRowMode == .startAnchor {
                                // 双周/三周锚点不可清空 —— 进这个 mode 时 recurrenceModeButton
                                // action 已在 interval>1 && editedDueDate==nil 时补今天。
                                // datePopoverTrigger 的任何 set 都会把 nil → 具体日期,所以 binding
                                // 的 get 用 popoverFallbackAnchor / startOfUserDay 仅作显示兜底;
                                // 真正的不变式由 set 路径保证。
                                HStack(spacing: WarmSpacing.xs) {
                                    Text(String(localized: "detail.start_date"))
                                        .font(WarmFont.caption(12))
                                        .foregroundColor(WarmTheme.textSecondary)
                                    TodoDatePopoverTrigger(date: $editedDueDate, onEdit: checkForChanges)
                                    Spacer()
                                }
                                .accessibilityIdentifier("DetailStartDatePicker")
                            }
                            // .hidden:整行不渲染(EmptyView 在 ViewBuilder 中被忽略)

                            // 语音原文备注(保留但不编辑)
                            if let hint = todo.dueHint, !hint.isEmpty {
                                Text(String(format: String(localized: "detail.voice_hint_format"), hint))
                                    .font(WarmFont.caption(12))
                                    .foregroundColor(WarmTheme.textMuted)
                            }

                            // 时段区:任何重复档位下都可用。原 if editedDueDate != nil 分支
                            // 会把「钟点 / 时段」跟 dueDate 绑死,但引擎层(TodoQueryActor)
                            // 在 recurrenceRule != nil 时用 dueDate ?? createdAt 作锚点,
                            // 锚点为 nil 时仍能调度,所以 UI 也应该解耦。
                            //
                            // - hasDueTime=true:钟点 picker + 派生 TimeBucket 只读 + 清除钟点按钮
                            // - hasDueTime=false:「添加钟点」按钮(canAddClockTime 守门)+ TimeBucket 胶囊恒显示
                            Divider()
                            TodoClockTimeRow(
                                dueDate: $editedDueDate,
                                hasDueTime: $editedHasDueTime,
                                timeBucket: timeBucketBinding,
                                recurrenceFrequency: editedRecurrenceFrequency,
                                onEdit: checkForChanges
                            )
                            // 清钟点时同步清 edited 态的提前量:persistChanges 会把库里
                            // 偏移清成 nil,若 @State 仍留旧值,hasChanges 的
                            // `editedReminderOffsetMinutes != todo.reminderOffsetMinutes`
                            // 从此恒为 true——之后任意编辑都触发一次 no-op 全量写库 + toast。
                            //
                            // 补钟点(false→true)时反向:未选过提前量则回填全局默认——
                            // 补钟点 = 新的提醒设置。清掉再补会重新吃到默认,接受此语义。
                            .onChange(of: editedHasDueTime) { _, hasTime in
                                if !hasTime {
                                    editedReminderOffsetMinutes = nil
                                } else if editedReminderOffsetMinutes == nil {
                                    editedReminderOffsetMinutes = ReminderOffsetConfig.effectiveDefaultOffset()
                                }
                            }

                            // 提前提醒行:只在带钟点时出现(无钟点无到点提醒可言)。
                            if editedHasDueTime {
                                Divider()
                                TodoReminderOffsetRow(
                                    offsetMinutes: $editedReminderOffsetMinutes,
                                    onEdit: checkForChanges
                                )
                            }
                        }
                    }

                    recurrenceEditorCard

                    // 分类（自适应网格：7 个分类按屏宽换行，避免横向滚动藏起「其他」）
                    // minimum 64pt：去掉 emoji 后每列只需容纳文字本身宽度，
                    // 64pt 足够放下 13pt 字体的 "Finance"/"Social"，
                    // 配合 chip 内 lineLimit(1) + minimumScaleFactor 兜底 Dynamic Type 最大档。
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.category"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            TodoCategoryGrid(selection: $editedCategory, onEdit: checkForChanges)
                        }
                    }

                    // 优先级（issue 7：绿色改橙色系；issue 8：统一实心填充）
                    detailCard {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            Text(String(localized: "detail.section.priority"))
                                .font(WarmFont.caption(13))
                                .foregroundColor(WarmTheme.textSecondary)
                            TodoPriorityPicker(selection: $editedPriority, onEdit: checkForChanges)
                        }
                    }

                    // 删除:文字链接样式(无背景填充)。
                    // 保留二次确认 alert —— 危险操作必须有,但视觉上弱化避免误点。
                    // 热区:.contentShape(Rectangle()) + .frame(maxWidth: .infinity, minHeight: 44)
                    //   把"透明背景"也纳入点击区,保证 iOS HIG 44pt 触摸目标。
                    //   文字本身只有 ~17pt 高、~50pt 宽,不撑满会变成难点的居中小按钮。
                    //   撑满后视觉上仍是"居中文字链接"(背景透明),但整行可点。
                    Button(action: { showDeleteConfirmation = true }) {
                        HStack(spacing: WarmSpacing.xxs) {
                            Image(systemName: "trash")
                            Text(String(localized: "detail.delete_button"))
                        }
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.urgent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, WarmSpacing.xxl) // 跟上方 recurrence 卡片拉开留白,危险操作单独成段

                    // 元信息（issue 9：降为底部小字，不做卡片）
                    VStack(spacing: WarmSpacing.xxs) {
                        if todo.needsAIProcessing {
                            HStack(spacing: WarmSpacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(WarmTheme.warning)
                                Text(String(localized: "detail.needs_ai"))
                                    .font(WarmFont.body(13))
                                    .foregroundColor(WarmTheme.warning)
                            }
                        }
                        Text(String(localized: "detail.created_at_value \(formattedDetailDate(todo.createdAt))"))
                            .font(WarmFont.caption(12))
                            .foregroundColor(WarmTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, WarmSpacing.sm)
                }
                .padding(.horizontal, WarmSpacing.xl)
                // 顶部 padding = 48pt(xxxl):chrome(自绘 header 44 + grabber 21)之下,
                // 给详情页专用 compact toast(高 ~36pt,chrome 下 +8~44pt 区段)让出完整空隙。
                // 标题卡顶在 chrome 下 113pt,与 toast 底部(+109pt)留 4pt 呼吸,不遮挡。
                // 注:方案文档 B.7 曾估收到 24pt,但 36pt 的 toast 需要完整空隙,维持 48
                // (账见 DetailChromeMetrics.toastTopPadding 注释)。
                .padding(.top, WarmSpacing.xxxl)
                .padding(.bottom, 40)
            }
            // 顶部 chrome(自绘 header + grabber):必须在根 ZStack 内 —— 整页作为一张卡片
            // 参与跟手变换,header 不在其中就会钉死在顶。safeAreaInset 让内容从 chrome
            // 之下开始排布,不钻到 header 底下。
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    detailHeaderRow
                    dismissGrabber
                }
                // chrome 实际高度上报:toast 让位量(topPadding)读它 —— header 随
                // Dynamic Type 增高时(AX4/AX5)常量 73 会压住 grabber,实测值全档位安全。
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, newHeight in
                    if newHeight != measuredChromeHeight {
                        measuredChromeHeight = newHeight
                    }
                }
            }
        }
        // 跟手变换(B.6):圆角/scale/offset 挂根 ZStack,整页(含 chrome)读作
        // 「一张正在脱离屏幕的卡片」。露出区底色 = WarmTheme.background(offset 不改变
        // 布局 frame,background 固定在原位填满整屏)。
        // 顺序约束:clipShape 必须在 scaleEffect 之内 —— scaleEffect 不改变布局 frame,
        // 挂在外层的 clipShape 会以未缩放的整屏 bounds 为裁剪区,scale(0.94) 后的可见
        // 内容完全落在裁剪矩形内部,圆角永远裁不到像素(等价于 CSS 把 border-radius
        // 写在 transform 外层)。clip 在内则圆角随内容一起被缩放变换,静态时 radius=0
        // 无副作用。
        .clipShape(RoundedRectangle(cornerRadius: dismissCornerRadius))
        .scaleEffect(dismissScale, anchor: .top)
        .offset(y: dismissDragOffset)
        .background(WarmTheme.background.ignoresSafeArea())
        // ↓ 以下全部挂在变换层之外:toast 不随卡片缩放位移,手势命中区不跟着跑。
        // 点空白收键盘:点页面非功能区(卡片留白、分区标题、纸纹背景等非交互区域)收起键盘。
        // 这是收键盘的主通道 —— iOS 26 起系统砍掉了键盘上方的 Done 工具条,
        // 点空白还原系统惯例(替代曾经的「关闭按钮两段式」方案)。
        // onTapGesture 不吞内层交互控件:SwiftUI 手势按视图层级深者优先,
        // TextField / Button / Toggle / Picker 各自认领 touch,此手势只在点到非交互区域时触发。
        // 硬件键盘连接(软件键盘不出现)时点空白同样 resign 焦点,无副作用。
        .onTapGesture {
            dismissKeyboard()
        }
        // 下滑关闭手势(B.5,起手锁定):独立于 chevron.down 的通道,按钮恒为直接关页。
        // 两段式 —— 键盘弹起的手势只收键盘;判定与门控快照见 dismissDragGesture。
        .gesture(dismissDragGesture)
        // 下滑两段式语义的键盘状态源:详情页所有 first responder 都在本页两个 TextField 内,
        // 页面又是 fullScreenCover 独立窗口层级,不存在跨页键盘串扰。
        // willShow/Hide 在动画起始帧发出,下滑手势 onEnded 时状态立即可读,无动画期竞态。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        // 自动保存:用户每次改字段会 schedule debounce,onDisappear 时 cancel 并立即静默保存兜底。
        // 这样用户改完停 0.8s 看到顶部「已保存 ✓」反馈,或在用户离开页面时静默落盘。
        // 不再用旧版「返回时一次性保存」(saveIfChanged) ——反馈缺失,用户不知道改的存了没。
        //
        // cancel + 置 nil 是协作式取消的最佳实践:Task.sleep 会 throw CancellationError(被 try? 吞掉),
        // guard !Task.isCancelled 让 Task 尽早退出而不是空等 800ms。
        //
        // 关于并发安全:即使 Task 已越过 sleep 进入 persistChanges 同步段(onDisappear 的 cancel
        // 无法中断正在执行的同步代码),两次 persistChanges 也是严格串行的 ——
        // Task 内执行完毕置 hasChanges = false,紧接的 onDisappear persistChanges 会命中
        // `guard hasChanges else { return }` 提前退出。没有真正的并发写。
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            if hasChanges {
                persistChanges(feedback: .none)
            }
        }
        .alert(String(localized: "detail.confirm_delete"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "detail.cancel"), role: .cancel) {}
            Button(String(localized: "detail.delete"), role: .destructive) { deleteTodo() }
        } message: {
            Text(String(localized: "detail.delete_warning"))
        }
        // 详情页靠 fullScreenCover 呈现 —— 它是独立窗口层级,VoiceTodoApp.mainView 上的
        // .toast overlay 被整页盖住,详情页里调 coordinator.showToast 时反馈不可见。
        // 这里在详情页内再挂一份,复用同一组 coordinator 状态,反馈就能在详情页顶部出现。
        // dismiss 后若 toast 未消失,主 overlay 接管显示,不会丢反馈。
        //
        // compact + chrome 让位 topPadding:详情页专用优化。
        // 默认 `.top` 用 48pt 顶部间距 + 64pt 高度的大 toast,在详情页里会压住第一张标题卡片。
        // compact 把 toast 缩到 ~36pt 高;topPadding = chrome 实测高度 + 8(标准档 73),
        // toast 占据 chrome 下 +8~44pt 区段;配合内容顶 padding 48(xxxl),标题卡顶在
        // chrome 下 113pt,toast 完整装在 grabber 与标题卡之间的空隙,不遮挡内容
        // (账见 DetailChromeMetrics;AX4/AX5 下 chrome 增高由 measuredChromeHeight 跟随)。
        .toast(
            message: coordinator.toastMessage,
            style: coordinator.toastStyle,
            isPresented: $coordinator.showToast,
            topPadding: DetailChromeMetrics.toastTopPadding(chromeHeight: measuredChromeHeight),
            compact: true,
            actionTitle: coordinator.toastActionTitle,
            action: coordinator.toastAction
        )
    }

    // MARK: - Dismiss Drag(方案 B:起手锁定 + 跟手;规格 docs/todo-detail-swipe-dismiss.md v2)

    /// 跟手视觉插值进度:0(静止)→ 1(visualTravel 处到达终点)。
    private var dismissProgress: CGFloat {
        min(1, max(0, dismissDragOffset) / DismissDragConfig.visualTravel)
    }

    /// 页面缩放(1.0 → minScale),anchor = .top,挂在 body 的 scaleEffect 上。
    private var dismissScale: CGFloat {
        1 - dismissProgress * (1 - DismissDragConfig.minScale)
    }

    /// 页面圆角(0 → maxCornerRadius)。
    private var dismissCornerRadius: CGFloat {
        dismissProgress * DismissDragConfig.maxCornerRadius
    }

    /// 阈值 haptic(B.4):offset 首次跨过 dismissTranslation 触发一次 light 触感,
    /// 回落复位后可再次触发。这是"暗示"的正解 —— 在用户正在拖的那一刻告诉他
    /// 「松手就关了」,比任何引导动画都直接。
    private func updateThresholdHaptic() {
        let crossed = dismissDragOffset > DismissDragConfig.dismissTranslation
        if crossed && !didCrossDismissThreshold {
            HapticFeedback.light()
        }
        didCrossDismissThreshold = crossed
    }

    /// 复位手势内状态。onEnded / onCancelled 双调用点 —— 门控判负时本页 recognizer
    /// 被 ScrollView 判 .failed 也会走 onCancelled,漏复位会让起手锁定快照跨手势泄漏,
    /// 污染下一手势的判定。
    private func resetDragGestureState() {
        isDragActive = false
        dragGateLockedAtTop = nil
        dragGestureKeyboardOnly = false
        didCrossDismissThreshold = false
    }

    /// 下滑关闭手势(B.5)。SimultaneousDragGesture 绕开 iOS 26 原生 DragGesture 回归
    /// (FB18199844;首页折叠手势同款包装)。
    ///
    /// **起手锁定**在门控闭包落地:首次被 UIKit 问询时快照 contentOffset,整段手势沿用 ——
    /// 起手不在顶的手势门控恒 false,整段交回系统 ScrollView(保留 bounce/惯性),页面不跟手;
    /// 想关闭必须抬手,再从顶部下拉(对齐「滚到顶 → 抬手 → 再下滑才关」的二次确认心智)。
    private var dismissDragGesture: SimultaneousDragGesture {
        SimultaneousDragGesture(
            minimumDistance: DismissDragConfig.minimumDistance,
            direction: .vertical,
            onChanged: { drag in
                // 首帧:捕获起手语义快照。键盘判定只看此刻 —— 键盘弹起的手势
                // 只收键盘不关页(用户想「把键盘滑下去」,直接 dismiss 会连同编辑页一起退出)。
                if !isDragActive {
                    isDragActive = true
                    dragGestureKeyboardOnly = isKeyboardVisible
                    if dragGestureKeyboardOnly { dismissKeyboard() }
                }
                guard !dragGestureKeyboardOnly, dragGateLockedAtTop ?? true else { return }
                // 扣掉 minimumDistance:UIKit 首帧 onChanged 已带满 10pt 位移,
                // 不扣会 0→10pt 瞬跳(首页折叠手势同款处理,HomeView 折叠手势注释)。
                dismissDragOffset = max(0, drag.translation.height - DismissDragConfig.minimumDistance)
                updateThresholdHaptic()
            },
            onEnded: { drag in
                defer { resetDragGestureState() }
                guard isDragActive, !dragGestureKeyboardOnly, dragGateLockedAtTop ?? true else { return }
                // 位移或速度任一达标即关 —— 快扫 60pt(位移不足)也能关。
                let travel = max(0, drag.translation.height - DismissDragConfig.minimumDistance)
                let shouldDismiss = travel > DismissDragConfig.dismissTranslation
                    || drag.velocity.dy > DismissDragConfig.dismissVelocity
                if shouldDismiss {
                    dismiss()
                } else {
                    withAnimation(WarmAnimation.springSmooth) { dismissDragOffset = 0 }
                }
            },
            onCancelled: {
                // 手势被系统中断(来电/系统边缘手势/被 ScrollView 判负):
                // 复位快照与视觉,否则 offset 卡中途、页面永久歪着
                // (契约见 SimultaneousDragGesture.swift 的 onCancelled 文档)。
                resetDragGestureState()
                withAnimation(WarmAnimation.springSmooth) { dismissDragOffset = 0 }
            },
            allowSimultaneousWithScrollViewPan: { scrollView, pan in
                // 起手锁定:首问快照,整段沿用。闭包会被 UIKit 多次调用(含手势中途),
                // 快照防止「中段起手滚到顶后,本手势中途变成可关闭」。
                if dragGateLockedAtTop == nil {
                    dragGateLockedAtTop = scrollView.contentOffset.y <= 0
                }
                return dragGateLockedAtTop == true
                    && scrollView.contentOffset.y <= 0
                    && pan.velocity(in: scrollView).y > 0
            }
        )
    }

    // MARK: - 顶部 Chrome(自绘 header + grabber,B.6/B.7)

    /// 自绘 header(44pt,对齐系统导航栏高度):左 chevron.down 关闭按钮 + 居中标题。
    /// 替代 .toolbar —— 系统导航栏由外层 NavigationStack 渲染、不在本页根 ZStack 内,
    /// 跟手变换时它会钉死在顶,内容从它下面滑走。
    /// 图标沿用旧 toolbar 的语义论证:chevron.down 是 iOS 17+ 标准 modal dismiss 语义,
    /// 纯导航语义,不暗示保存/取消,匹配 autosave 行为(xmark 有"放弃改动"歧义,
    /// checkmark 会跟完成勾选框视觉重复)。
    private var detailHeaderRow: some View {
        Text(String(localized: "detail.title"))
            .font(WarmFont.headline(17))
            .foregroundColor(WarmTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: DetailChromeMetrics.headerHeight)
            .overlay(alignment: .leading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(WarmTheme.primary)
                        .frame(width: DetailChromeMetrics.headerHeight, height: DetailChromeMetrics.headerHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "panel.close"))
                .accessibilityIdentifier("TodoDetailCloseButton")
            }
    }

    /// grabber:视觉指示「整页可下拉」。宽度/不透明度随拖拽 progress 变化
    /// (38→48pt / 0.4→0.7;越过阈值直接跳 0.7 给离散信号,对齐 HTML 原型)。
    /// 不可点 —— 它是指示器不是控件,关闭动作由 header 的 chevron.down 承担;
    /// VoiceOver 隐藏(按钮已承担 a11y 出口)。
    private var dismissGrabber: some View {
        let progress = dismissProgress
        let alpha = didCrossDismissThreshold
            ? DetailChromeMetrics.grabberPeakAlpha
            : DetailChromeMetrics.grabberBaseAlpha
                + (DetailChromeMetrics.grabberPeakAlpha - DetailChromeMetrics.grabberBaseAlpha) * progress
        return Capsule()
            .fill(WarmTheme.sketch.opacity(alpha))
            .frame(
                width: DetailChromeMetrics.grabberBaseWidth + progress * DetailChromeMetrics.grabberExtraWidth,
                height: DetailChromeMetrics.grabberHeight
            )
            .padding(.vertical, WarmSpacing.xs)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// 主动收起键盘:全局 resign first responder。
    /// SwiftUI TextField 的焦点不跟随视图状态变化,必须显式 resign
    /// (与 HomeView.dismissKeyboard 同一 UIKit 通道;两处各留私有实现,
    /// 不为此单一动作抽公共工具)。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    // MARK: - Card Wrapper

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(WarmSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section)
                    .fill(Color.white)
                    .shadow(color: WarmTheme.shadowLight, radius: 4, x: 0, y: 2)
            )
    }

    // MARK: - Recurrence Editor

    private var recurrenceEditorCard: some View {
        detailCard {
            VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                Text(String(localized: "detail.section.recurrence"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)

                chipRow {
                    recurrenceModeButton(nil, title: String(localized: "recurrence.none"))
                    recurrenceModeButton(.daily, title: String(localized: "recurrence.daily"))
                    recurrenceModeButton(.weekly, interval: 1, title: String(localized: "recurrence.weekly_short"))
                    recurrenceModeButton(.weekly, interval: 2, title: String(localized: "recurrence.biweekly_short"))
                    recurrenceModeButton(.weekly, interval: 3, title: String(localized: "recurrence.triweekly_short"))
                    recurrenceModeButton(.monthly, title: String(localized: "recurrence.monthly_short"))
                }

                if editedRecurrenceFrequency == .weekly {
                    weekdayGrid
                }

                if editedRecurrenceFrequency == .monthly {
                    // wheel picker 高度由 .frame 强制 —— 不给 frame 会撑满父容器。
                    // 80×100:3 行可见,够 iOS HIG wheel 触摸目标,又不喧宾夺主。
                    // 文字「每月 / 号」放在 picker 同行,垂直居中视觉对齐。
                    HStack(spacing: WarmSpacing.sm) {
                        Text(String(localized: "recurrence.monthly_day_prefix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        Picker("", selection: $editedDayOfMonth) {
                            ForEach(1...31, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 80, height: 100)
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "recurrence.monthly_day_placeholder"))
                        .onChange(of: editedDayOfMonth) { _, _ in checkForChanges() }
                        Text(String(localized: "recurrence.monthly_day_suffix"))
                            .font(WarmFont.body(15))
                            .foregroundColor(WarmTheme.textSecondary)
                        Spacer()
                    }
                }

                if let recurrenceSummary {
                    // 重复生效后的完整语义摘要,把「起始锚点 / 周期 / 钟点」拼成一行,
                    // 让被隐藏的起始锚点(尤其 .startAnchor / .hidden 模式下)不再是黑盒。
                    // 校验失败时(每周未选星期)也在这里显示,内嵌"这条规则不会生效"提示。
                    // 改设计(2026-08):12pt 灰色脚注 → 14pt 主文字色,变量加粗主色。
                    // AttributedString markdown 解析不会注入 font run 属性,
                    // Text 上的 .font 修饰作为整体应用,styledSummary 只改 foregroundColor。
                    Text(recurrenceSummary)
                        .font(WarmFont.body(14))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("DetailRecurrenceSummary")
                }

                if editedRecurrenceFrequency != nil {
                    recurrenceEndDateEditor
                }
            }
        }
    }

    /// 重复任务结束日期编辑器。Toggle 控制「无限循环 vs 有截止」,on 时显示日期 popover trigger。
    /// 复用 `TodoDatePopoverTrigger`(与 Time 卡片「日期」入口一致):点文本弹 `.graphical` 日历,
    /// 选定后 ~0.18s 自动收起 popover,带 haptic 反馈。
    /// 默认 +1 月(跟 AI「未来一个月」语义对齐),用户可任意改。
    /// 不强制阻止 endDate 早于 today/startDate —— 允许用户表达「这个重复已经结束」。
    /// startOfDay 归一化交给 `RecurrenceRule.init`(`Protocols/Domain/RecurrenceRule.swift`),
    /// trigger 内 `DatePicker(.graphical)` 写回的"中午 12:00"会在落盘时被统一归零,UI 不重复处理。
    private var recurrenceEndDateEditor: some View {
        VStack(spacing: WarmSpacing.xs) {
            Toggle(isOn: Binding(
                get: { editedEndDate != nil },
                set: { isOn in
                    if isOn {
                        // 优先恢复原 endDate(todo 初值),避免手滑关再开丢失自定义日期;
                        // 原值为 nil(无限循环)时才 fallback +1 月(对齐 AI 语义)。
                        editedEndDate = todo.recurrenceRule?.endDate
                            ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())
                    } else {
                        editedEndDate = nil
                    }
                    checkForChanges()
                }
            )) {
                Text(String(localized: "recurrence.end_date.toggle"))
                    .font(WarmFont.body(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if editedEndDate != nil {
                // 复用 Time 卡片的日期 trigger —— 视觉/交互与"Time 区日期"完全一致。
                // a11y label 通过入参传给组件(trigger 已 `.accessibilityElement(children: .ignore)`
                // 合并成单 element,label 必须在内部贴才生效),让 VoiceOver 读出"结束日期"语义。
                TodoDatePopoverTrigger(
                    date: $editedEndDate,
                    accessibilityLabel: String(localized: "recurrence.end_date.label"),
                    onEdit: checkForChanges
                )
            }
        }
    }

    private func recurrenceModeButton(
        _ frequency: RecurrenceFrequency?,
        interval: Int = 1,
        title: String
    ) -> some View {
        // weekly 三档(每周/双周/三周)共用 frequency=.weekly,必须再比对 interval
        // 才能区分 —— 否则三档会被同时判定为选中。
        // non-weekly(daily/monthly/nil)忽略 interval。
        let isSelected: Bool = {
            guard editedRecurrenceFrequency == frequency else { return false }
            return frequency == .weekly ? editedInterval == interval : true
        }()
        return Button {
            withAnimation(WarmAnimation.springFast) {
                editedRecurrenceFrequency = frequency
                if frequency == .weekly {
                    editedInterval = interval
                    // interval==1(每周)强制默认周几,避免触发 weekly_required 校验;
                    // interval>1(双周/三周)保留已有 weekdays:用户可能从 AI 返回的
                    // "双周周一"进来,点 chip 确认时不应丢失周几锚定。displayText
                    // 会显示完整"双周 周一",chip 标签"双周"只表达周期,两者互补。
                    if interval == 1 && editedWeekdays.isEmpty {
                        editedWeekdays = [Calendar.current.component(.weekday, from: Date())]
                    }
                    // 双周/三周靠起始锚点决定「从哪一周开始」(occurs 的 weekDiff % interval);
                    // 无 dueDate 时补今天,既给 occurs() 确定基准,也让「起始日期」行有值可显示。
                    // 这跟 .startAnchor 形态强耦合:进 .startAnchor 必须有锚点,否则日期行空白。
                    if interval > 1 && editedDueDate == nil {
                        editedDueDate = DayClock.startOfUserDay(for: Date())
                    }
                } else if frequency == nil {
                    // 切回「无重复」时,若 editedDueDate 是切到 startAnchor 模式时被自动补的
                    // (基准:进入详情页时 todo.dueDate == nil,且用户没设过钟点),
                    // 把它清掉 —— 否则这个用户从未主动指定的日期会从「锚点」悄悄变成
                    // 「截止日」,语义错位。用户原本就有 dueDate 的场景不动。
                    if todo.dueDate == nil && !editedHasDueTime {
                        editedDueDate = nil
                    }
                }
                // monthly: editedDayOfMonth 是 Int,init 时已设默认值(当前日或 todo.dayOfMonth),
                // 切换时无需 fallback —— 用户切换走再切回应保留之前选择,不应被 reset。
                checkForChanges()
            }
        } label: {
            // 选中态:无描边 + 浅底 + 主色字 weight 500。
            //  - 非默认值(每天/每周/双周/三周/每月):primary.opacity(0.11) 浅底 + primaryText 深橙字
            //  - 默认值(「不重复」frequency==nil):subtleControlBackground 中性灰底 + textPrimary 黑字
            //    —— 「默认值安静,改过的值才发亮」(设计规范)。
            // 未选态:透明底 + 1px sketch 描边 + textSecondary 灰字。
            // 圆角 WarmRadius.chipEmphasis(9pt):介于 chip(8)和 segmentedTrack(10),
            // 选中态视觉重量略升但不超过 card。
            //
            // 历史:原实心 primary + 白字视觉重量过高,跟页面其他选中态(时段 segmented 浅底)
            // 打架。改浅底方案统一设计语言。
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected
                    ? (frequency == nil ? WarmTheme.textPrimary : WarmTheme.primaryText)
                    : WarmTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, WarmSpacing.sm)
                .padding(.vertical, WarmSpacing.xs)
                .background {
                    let shape = RoundedRectangle(cornerRadius: WarmRadius.chipEmphasis)
                    if isSelected {
                        shape.fill(frequency == nil
                            ? WarmTheme.subtleControlBackground
                            : WarmTheme.primary.opacity(0.11))
                    } else {
                        shape.strokeBorder(WarmTheme.sketch.opacity(0.4), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// chip 容器:FlowLayout 自适应换行。默认档位 4 chip 一行;AX5 / 长词撑破
    /// 屏宽时自动换行到 2 行 / 3 行,所有 chip 完整可见不滚动、不缩字、不截断。
    /// chip 自身已用 fixedSize 暴露稳定 intrinsic 宽度,FlowLayout 按内容算行宽。
    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        FlowLayout(horizontalSpacing: WarmSpacing.xs, verticalSpacing: WarmSpacing.xs) {
            content()
        }
    }

    /// weekday 7 button 的容器:强制单行 7 等分,列间距 6pt,永远不换行。
    /// 历史:原 AX1+ 切 4+3 两行布局,但违反规范"一行七列"语义 → 删 dynamicTypeSize
    /// 分支,统一单行。AX5 大字号下靠 weekdayButton 内的 `minimumScaleFactor(0.7)`
    /// 允许字号缩放兜底(用户已确认接受)。
    private var weekdayGrid: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { weekday in weekdayButton(weekday) }
        }
    }

    private func weekdayButton(_ weekday: Int) -> some View {
        let isSelected = editedWeekdays.contains(weekday)
        return Button {
            if isSelected { editedWeekdays.remove(weekday) } else { editedWeekdays.insert(weekday) }
            checkForChanges()
        } label: {
            Text(shortWeekdayName(weekday))
                // system 12pt 比 Repeat chip 的 14pt 小两档,视觉层级清晰:
                // Repeat 是主选择,weekday 是次级补选。字重统一 .medium(跟分类 chip 一致)。
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? WarmTheme.primaryText : WarmTheme.textSecondary)
                // lineLimit(1) + minimumScaleFactor(0.7):AX5 大字号下"周三"/"Wed"
                // 单行装不下,允许缩到 70% 字号兜底,不截断(用户决策,见 weekdayGrid 注释)。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(minHeight: WarmSpacing.xxl)
                // 选中态:无描边 + primary 浅底 + primaryText(跟 Repeat chip 选中态一致)。
                // 未选态:透明底 + 1px sketch 描边。
                .background {
                    let shape = RoundedRectangle(cornerRadius: WarmRadius.chip)
                    if isSelected {
                        shape.fill(WarmTheme.primary.opacity(0.11))
                    } else {
                        shape.strokeBorder(WarmTheme.sketch.opacity(0.4), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func shortWeekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "home.week.sun")
        case 2: return String(localized: "home.week.mon")
        case 3: return String(localized: "home.week.tue")
        case 4: return String(localized: "home.week.wed")
        case 5: return String(localized: "home.week.thu")
        case 6: return String(localized: "home.week.fri")
        default: return String(localized: "home.week.sat")
        }
    }

    /// 重复卡底部摘要文本(AttributedString,变量加粗主色)。
    ///
    /// 视觉重设计(2026-08):从 12pt 灰色脚注升级到 14pt 主文字色 + 变量加粗主色。
    /// 句式按 frequency 变(不套模板),让用户真的知道自己设了什么。
    /// 校验失败(.weekly interval=1 + 无 weekdays)也在这里显示,不再用独立 Text。
    ///
    /// 模板用 markdown `**...**` 标记加粗段,`styledSummary` 解析后扫 run 把
    /// stronglyEmphasized 部分上色为 primaryText(加粗由 markdown 解析的
    /// inlinePresentationIntent 自然携带,不需要 styledSummary 复设 font weight)。
    ///
    /// 句式:
    /// - nil(不重复):  只在 **{date}** 这一天
    /// - .daily:        从 **{date}** 起,**每天**
    /// - .monthly:      从 **{date}** 起,**每月 {N} 号**
    /// - .weekly:       从 **{date}** 起,每 {周期词} **{周一、周二}**
    /// - .weekly(interval>1 + 空 weekdays): 从 **{date}** 起,每 {周期词}(无"on 哪几天"语义)
    /// - .weekly(校验失败): 还没选星期,**这条规则不会生效**
    private var recurrenceSummary: AttributedString? {
        // 校验失败优先(.weekly interval=1 + 无 weekdays)——
        // 不静默:让用户看到"这条规则不会生效",承担行内校验职责。
        if editedRecurrenceFrequency == .weekly,
           editedInterval == 1,
           editedWeekdays.isEmpty {
            return styledSummary(String(localized: "recurrence.summary.invalid"))
        }

        guard let anchor = editedDueDate else { return nil }
        let dateText = TodoRelativeDateFormatter.format(anchor)

        let raw: String
        switch editedRecurrenceFrequency {
        case nil:
            raw = String(format: String(localized: "recurrence.summary.none"), dateText)
        case .daily:
            raw = String(format: String(localized: "recurrence.summary.daily"), dateText)
        case .monthly:
            raw = String(format: String(localized: "recurrence.summary.monthly"),
                         dateText,
                         editedDayOfMonth)
        case .weekly:
            let intervalWord: String
            switch editedInterval {
            case 2:  intervalWord = String(localized: "recurrence.summary.weekly_interval_bi")
            case 3:  intervalWord = String(localized: "recurrence.summary.weekly_interval_tri")
            default: intervalWord = String(localized: "recurrence.summary.weekly_interval_single")
            }
            // interval>1(双周/三周)允许空 weekdays —— 语义是"从起始日每 interval*7 天一次",
            // 没有"on 哪几天"这个概念。空 weekdays 走另一条模板,避免主模板空 %3$@ 渲染成 ****。
            if editedWeekdays.isEmpty {
                raw = String(format: String(localized: "recurrence.summary.weekly_no_weekday"),
                             dateText, intervalWord)
            } else {
                let weekdaysText = editedWeekdays
                    .sorted()
                    .map { shortWeekdayName($0) }
                    .joined(separator: String(localized: "recurrence.summary.weekday_separator"))
                raw = String(format: String(localized: "recurrence.summary.weekly"),
                             dateText, intervalWord, weekdaysText)
            }
        }
        return styledSummary(raw)
    }

    /// 把带 markdown `**...**` 标记的本地化字符串解析成 AttributedString,
    /// 扫描 stronglyEmphasized run 上色为 primaryText(规范:变量加粗主色)。
    /// 加粗由 markdown 解析的 inlinePresentationIntent 自然带;字号由 Text 上的
    /// `.font(WarmFont.body(14))` 统一设置,不在这里复设(避免 AttributedString 内部
    /// font 属性覆盖 Text 修饰)。
    /// markdown 解析失败时降级为普通 AttributedString(保持文本可见,不静默吞)。
    private func styledSummary(_ raw: String) -> AttributedString {
        var parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: raw)
        } catch {
            parsed = AttributedString(raw)
        }
        for run in parsed.runs {
            let isBold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            parsed[run.range].foregroundColor = isBold ? WarmTheme.primaryText : WarmTheme.textPrimary
        }
        return parsed
    }

    private var editedRecurrenceRule: RecurrenceRule? {
        switch editedRecurrenceFrequency {
        case .daily: return RecurrenceRule(frequency: .daily, endDate: editedEndDate)
        case .weekly:
            // interval==1(每周)必须有 weekdays 才有效(否则 isValid 会判 false);
            // interval>1(双周/三周)允许空 weekdays —— 对齐 AI 返回的"每两周"语义。
            guard editedInterval > 1 || !editedWeekdays.isEmpty else { return nil }
            return RecurrenceRule(
                frequency: .weekly,
                interval: editedInterval,
                weekdays: Array(editedWeekdays),
                endDate: editedEndDate
            )
        case .monthly:
            // Picker 1...31 已限制范围,editedDayOfMonth 永远合法,直接构造。
            return RecurrenceRule(frequency: .monthly, dayOfMonth: editedDayOfMonth, endDate: editedEndDate)
        case nil: return nil
        }
    }

    private var recurrenceValidationMessage: String? {
        switch editedRecurrenceFrequency {
        case .weekly:
            // 仅"每周"需要强制选周几;"双周/三周"允许空 weekdays。
            return (editedInterval == 1 && editedWeekdays.isEmpty)
                ? String(localized: "recurrence.validation.weekly_required")
                : nil
        // monthly:Picker 1...31 已限制,无需 validation。
        case .monthly, .daily, nil: return nil
        }
    }

    private var recurrenceStateChanged: Bool {
        if editedRecurrenceFrequency != todo.recurrenceRule?.frequency { return true }
        // endDate 变化独立于 frequency —— 用户开/关 Toggle 或改 DatePicker 都要触发保存。
        if editedEndDate != todo.recurrenceRule?.endDate { return true }
        switch editedRecurrenceFrequency {
        case .weekly:
            // 同时比对 interval 和 weekdays:interval 变化(每周↔双周↔三周)也算结构变化。
            // 不比 interval 会导致 AI 返回 interval=2 的待办进详情页随便编辑一下就被静默重置为 1。
            let oldInterval = todo.recurrenceRule?.interval ?? 1
            let oldWeekdays = Set(todo.recurrenceRule?.weekdays ?? [])
            return editedInterval != oldInterval || editedWeekdays != oldWeekdays
        case .monthly:
            // todo 不是 monthly 时,frequency 已变化会先在第一行 return true,
            // 这里的 fallback 实际走不到 —— 用 1 仅作占位,任意值都不影响判定结果。
            // 不用 `Calendar.current.component(.day, ...)` 是为了避免 computed property
            // 每次访问重新取值,在跨午夜停留 Detail 页的极端场景产生漂移。
            return editedDayOfMonth != (todo.recurrenceRule?.dayOfMonth ?? 1)
        case .daily, nil: return false
        }
    }

    // MARK: - Actions

    /// 时段选择的双向绑定，套一层协同逻辑：
    /// 选了非 `.anytime` 时段 + 当前没有任何日期/钟点 → 把 `editedDueDate` 补成今天。
    ///
    /// 与 `TodoScheduleDefaults.effectiveDueDate` 同源（"时段⇒今天"），但原逻辑只在 todo 创建时
    /// 生效（`TodoItemData.init` / `SwiftDataModels`），编辑路径不走它。这里把同一规则补到编辑路径。
    /// 不补的后果：用户在「稍后」分组点开 todo 选「上午」，写库后 `timeBucket=.morning + dueDate=nil`，
    /// 被 `HomeCalendarState` 的 `hasTimeSignal` 过滤扔进「待定日期」分组 —— 与用户意图不符。
    ///
    /// **反向不清**：从「上午」切回「随时」时不擦 `editedDueDate`。语义上「随时」是「不挑时段」，
    /// 不是「不要日期」；用户可能就是想把任务保留在某天但不卡时段。同源规则也只补不清。
    private var timeBucketBinding: Binding<TimeBucket?> {
        Binding(
            get: { editedTimeBucket },
            set: { newValue in
                editedTimeBucket = newValue
                if let bucket = newValue, bucket != .anytime,
                   editedDueDate == nil, !editedHasDueTime {
                    editedDueDate = Calendar.current.startOfDay(for: Date())
                }
            }
        )
    }

    /// 计算 `hasChanges` 并在检测到改动时触发防抖保存。
    ///
    /// 设计说明:把「检测变化」和「调度保存」放在一起是有意的取舍 ——
    /// 当前所有调用点(8 处 onChange / chip / button)都是「检测到变化就该保存」,
    /// 没有只检测不保存的用例。拆分会扩散到所有调用点(每处都加 scheduleAutosave),
    /// 反而降低可读性。如果未来出现「只检测不保存」场景,再拆分为纯查询 + 调用方显式调度。
    private func checkForChanges() {
        hasChanges = editedTitle != todo.title ||
                     editedDetail != (todo.detail ?? "") ||
                     editedCategory != todo.category ||
                     editedPriority != todo.priority ||
                     editedDueDate != todo.dueDate ||
                     editedHasDueTime != todo.hasDueTime ||
                     editedTimeBucket != todo.timeBucket ||
                     editedReminderOffsetMinutes != todo.reminderOffsetMinutes ||
                     recurrenceStateChanged
        // 有改动就 schedule 防抖保存:用户停 800ms 不动 → 自动写库 + 显示 toast。
        // 防抖避免每次 keystroke 都触发 SwiftData 写入。
        if hasChanges {
            scheduleAutosave()
        }
    }

    /// 防抖保存:每次有改动就 cancel 旧 task,重启 800ms 倒计时。
    /// 用户连续改字段不会触发多次保存,只有真正停下才落盘。
    ///
    /// **时序边界**:Task 的 cancellation 是协作式的 —— `cancel()` 只设置 flag,无法中断
    /// 已越过 sleep 进入 persistChanges 同步段的代码。极端情况下用户快速 swipe back 然后立刻
    /// 重新进入同一 todo 详情,可能短暂存在两个 Task。`guard !Task.isCancelled` + `hasChanges`
    /// 守卫保证不会真正并发写库,但 toast 可能出现两次。可接受(用户感知极小)。
    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistChanges(feedback: .toast)
        }
    }

    /// 保存反馈模式。
    /// - `.toast`:debounce 自动保存走这条 —— 用户改完看到「已保存 ✓」反馈,确认改动落盘。
    /// - `.none`:onDisappear 兜底走这条 —— 页面已退出,toast 显示在父视图反而打扰用户。
    private enum SaveFeedback {
        case none
        case toast
    }

    /// 把当前 edited* 字段写入 store,并同步本地基准 `todo`。
    /// 同步基准是关键:不同步的话,保存后继续编辑会让 checkForChanges 用旧 todo 比对,
    /// 出现「用户改回原值却显示无变化」的 bug(因为 todo 还是初始值)。
    ///
    /// recurrence 验证失败时整体 abort(不降级保存):
    /// - validation 只在 recurrence 编辑过程中失败(.weekly 未选周几 / .monthly 日期非法),
    ///   这表示用户「正在设置 recurrence,还没完成」——属于未完成编辑,不应当作可保存状态。
    /// - 降级保存(保留旧 recurrence)会让 UI 显示 .weekly 但 store 仍是 nil,重新打开详情页
    ///   用户会看到 recurrence 没存住,数据 vs UI 不一致。
    /// - debounce 路径下 feedback == .toast 会显示 warning,提示用户完成编辑;用户不完成就不保存,
    ///   符合「in-progress 不持久化」的心智模型。
    /// - onDisappear 路径下 feedback == .none 不提示(页面已退出,toast 打扰用户),
    ///   用户重新进入时会看到 edited* 的中间态丢失、恢复到上次成功保存的基准 —— 这是
    ///   「未完成编辑 = 弃掉」的预期行为。
    ///
    /// **权衡代价**:整体 abort 意味着用户同时修改了其他字段(如改了标题、备注、分类),
    /// 这些改动也会一起被丢弃。这是优先「数据一致性」的取舍 —— 比部分保存后用户看到
    /// 「标题存了但 recurrence 没存」更可预测。如果未来要支持「部分保存」,需要给每个字段
    /// 独立做 valid 校验 + 独立 hasChanged 标记,改造较大。
    private func persistChanges(feedback: SaveFeedback) {
        guard hasChanges else { return }
        guard recurrenceValidationMessage == nil else {
            if feedback == .toast {
                coordinator.showToast(message: recurrenceValidationMessage ?? ErrorMessages.storageError, style: .warning)
            }
            return
        }
        let timeMetadataChanged = editedDueDate != todo.dueDate ||
                                  editedHasDueTime != todo.hasDueTime ||
                                  editedTimeBucket != todo.timeBucket ||
                                  recurrenceStateChanged
        do {
            try coordinator.updateTodoDetail(
                todo.id,
                update: TodoDetailUpdate(
                    title: editedTitle,
                    detail: editedDetail.isEmpty ? nil : editedDetail,
                    category: editedCategory != todo.category ? editedCategory : nil,
                    priority: editedPriority != todo.priority ? editedPriority : nil,
                    dueDate: editedDueDate,
                    hasDueTime: editedHasDueTime,
                    timeBucket: editedTimeBucket,
                    dueHint: timeMetadataChanged ? "" : nil,
                    recurrenceRule: editedRecurrenceRule,
                    // 三态契约:有钟点时 nil(准时)显式传 0 清除;清钟点则一并清提醒偏移。
                    reminderOffsetMinutes: editedHasDueTime ? (editedReminderOffsetMinutes ?? 0) : 0
                ),
                // 详情页直改 dueDate 的推迟埋点记 origin = .detail(区别于首页快捷操作 .app)
                origin: .detail
            )
            // 同步基准:把 edited* 写回 todo,下次 checkForChanges 以新基准比对。
            // editedHasDueTime / editedTimeBucket 由 UI 层归一化(用户取消日期时 UI 自己清 hasDueTime),
            // 这里直接赋值即可,不再做二次归一化。
            todo.title = editedTitle
            todo.detail = editedDetail.isEmpty ? nil : editedDetail
            todo.category = editedCategory
            todo.priority = editedPriority
            todo.dueDate = editedDueDate
            todo.hasDueTime = editedHasDueTime
            todo.timeBucket = editedTimeBucket
            todo.reminderOffsetMinutes = editedHasDueTime ? editedReminderOffsetMinutes : nil
            todo.recurrenceRule = editedRecurrenceRule
            if timeMetadataChanged {
                todo.dueHint = ""
            }
            hasChanges = false
            if feedback == .toast {
                coordinator.showToast(message: ErrorMessages.todoSaved, style: .success)
            }
        } catch {
            // 保存失败时保留 hasChanges = true —— 用户下次显式改动(checkForChanges 重算)
            // 会重新触发 scheduleAutosave 自动重试。debounce 机制天然限制重试频率:
            // 用户必须停下来 800ms 才会触发下一次保存,不会刷屏。
            // feedback == .none(onDisappear)时不 toast —— 页面已退出,toast 显示在父视图打扰用户。
            // 副作用:用户停止编辑后 hasChanges 保持 true,但无新 keystroke 就不会 scheduleAutosave,
            // 数据最终没保存。接受此权衡:静默失败比刷屏 toast 更可取,用户下次编辑会再触发。
            VoiceTodoLog.store.error("ui.detail.save_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            if feedback == .toast {
                coordinator.showToast(message: ErrorMessages.storageError, style: .warning)
            }
        }
    }

    private func deleteTodo() {
        do {
            try coordinator.deleteTodo(todo.id)
            coordinator.showToast(message: ErrorMessages.todoDeleted, style: .info)
            dismiss()
        } catch {
            VoiceTodoLog.store.error("ui.detail.delete_failed id=\(todo.id.uuidString, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            coordinator.showToast(message: ErrorMessages.todoDeleteFailed, style: .warning)
        }
    }
}
