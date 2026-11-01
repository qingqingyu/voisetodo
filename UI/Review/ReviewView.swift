import SwiftUI
import Charts
import SwiftData

// MARK: - Period

/// 回顾页可选的时间跨度。
private enum ReviewPeriod: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .week:
            return String(localized: "review.period.week")
        case .month:
            return String(localized: "review.period.month")
        }
    }

    /// 从今天往回推算的起始日（用户日归一化）。
    func startDay(from today: Date, calendar: Calendar) -> Date {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        switch self {
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
        }
    }

    /// 区间结束日（明天用户日起点，开区间——对齐 ReviewAggregator `[start, end)` 约定）。
    /// ReviewAggregator 内部会对 endDay 再做用户日归一化，
    /// 因此传入明天起点后归一化仍为明天，确保今天被包含在区间内。
    func endDay(from today: Date, calendar: Calendar) -> Date {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
    }

    /// 用于展示的周期标签（如 "2026年7月" / "第29周"）。
    /// 月份恒用 `.abbreviated`:英文 "September 2026" → "Sep 2026",中文 "2026年9月" 不变。
    /// 与 HomeView calendarMonthTitle 保持一致,避免英文长月份名挤爆标题行。
    func periodLabel(for today: Date, calendar: Calendar) -> String {
        switch self {
        case .week:
            let weekOfYear = calendar.component(.weekOfYear, from: today)
            let year = calendar.component(.yearForWeekOfYear, from: today)
            return String(localized: "review.label.week_\(year)_\(weekOfYear)")
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return monthStart.formatted(.dateTime.year().month(.abbreviated))
        }
    }
}

// MARK: - ReviewView

/// 回顾页面——展示周/月切换的完成统计摘要。
///
/// 使用 Swift Charts 绘制分类占比饼图和每日趋势条形图。
/// 数据经 `ReviewSummaryReading.reviewWindowInputs` 在后台 `@ModelActor` 按窗
/// 查询(近 30 天 + 所选周/月),聚合成 `ReviewSummary` 缓存进 `@State`
/// (2026-10 按窗取数改造:读取量只和窗口内数据量有关,与历史总量无关;
/// 口径与改前的全量 `@Query` 逐字段一致,护栏 `ReviewWindowQueryParityTests`)。
///
/// 阶段 3 增补:复盘入口卡(2026-08-23 拍板改版为「N 件事等你决定」一行动作行,
/// 点击 fullScreenCover 呈现五步流程 `ReviewFlowView`)——非空态与空态均以底部
/// 悬浮层呈现(2026-10-24 拍板,原 10-19 的「两态置顶」废止;7 天滚动冷却期内
/// 整卡隐藏)。日常随手看统计和郑重坐下来复盘是两种心智,不混。
struct ReviewView: View {
    /// 复盘流程需要的 store 能力。nil(默认)时入口卡隐藏——settings 深链与
    /// preview 不注入也能编译渲染;HomeView 的两处 sheet 注入真实 store。
    var store: (any ReviewFlowStore)? = nil
    /// 拆小 sheet 的 AI 候选源(2026-08-23 拆小改版)。nil → sheet 直接手写降级。
    var splitter: (any TodoSplitterProtocol)? = nil
    /// 拆小 sheet 的麦克风(与首页共用同一实例)。nil → 「说一句」行隐藏。
    var voiceInput: (any VoiceInputProtocol)? = nil
    /// 笔记语义对照提取器(2026-08-23)。nil → 收尾不做 AI 分析。
    var noteAnalyzer: (any ReviewNoteAnalyzerProtocol)? = nil
    /// 深读观察器(v5 T5)。nil → 第 3 步无 AI 观察卡、第 5 步无草稿预填。
    var deepReader: (any DeepReadObservationProtocol)? = nil
    /// 是否渲染右上角 × 关闭(2026-10-24 收起可发现性)。仅 sheet 语境的调用方
    /// (HomeView.reviewSheetContent)置 true;设置深链是 NavigationLink push,
    /// 已有系统返回 chevron,再叠 × 是冗余双退出,保持默认 false 不渲染。
    var showsSheetCloseButton: Bool = false

    // MARK: 数据(2026-10 按窗取数改造,任务书 task-metrics-quota-and-review-query §2)
    //
    // 原先是三个全量 `@Query`(全部已完成 + 全部完成记录 + 全部待办),body
    // 每次重算都对整批 `.map { $0.toData() }`——读取量随历史总量线性涨,复盘
    // 内每次划卡写库还会触发全量重查。现改为后台 `@ModelActor` 按窗查询
    // (`ReviewSummaryReading.reviewWindowInputs`),读取量只和窗口内数据量有关;
    // 「还挂着」/入口卡 N 只需要开放待办,`store.todos` 工作集(全部未完成 +
    // 近期完成)内存过滤即可,同口径数字零变化(对照护栏:ReviewWindowQueryParityTests)。
    //
    // 代价:数字从同步变为异步就绪(nil = 未加载,渲染空而非闪空态文案);
    // 查询走 completedAt/createdAt/dueDate 索引,窗口外历史不再进内存。

    /// 近 30 天成绩单(Hero / Stats / 空态判定)。nil = 首次加载未完成。
    @State private var fixedSummary: ReviewSummary?
    /// 当前选中周期的图表区摘要(分类/趋势/最忙一天)。与 fixedSummary 同一批
    /// 加载、同一 tick 落位(见 `reloadSummaries`)。
    @State private var periodSummary: ReviewSummary?

    @State private var selectedPeriod: ReviewPeriod = .month
    /// 入口卡点击 → fullScreenCover 呈现五步复盘流程。
    @State private var showReviewFlow = false
    /// 「复盘笔记」时间线(2026-08-23 拍板:历次笔记随时可翻)。
    /// App Group UserDefaults(≤52 条),onAppear 与复盘流程收尾后各读一次。
    @State private var reviewNotes: [ReviewNotesEntry] = []
    /// 上次复盘完成时刻(入口卡范围标用,2026-09-07 范围标口径修正;2026-10-24
    /// 起兼作入口卡冷却判定的唯一数据源,见 `entryCardInCooldown`)。与流程侧
    /// `ReviewFlowView` 注入第 1 步的 `previousSessions.last?.completedAt` 同源;
    /// 随 `loadReviewNotes()` 的同一次 `allSessions()` 一并赋值,不单独再读。
    @State private var lastReviewDate: Date?
    /// 入口卡手动关闭时刻(2026-10-27 拍板):右上角 × 主动收卡,复用同一
    /// 7 天冷却(`entryCardCooldown`)。与 `lastReviewDate` 分开存——那是
    /// 「上次复盘完成」口径(范围标 + 流程第 1 步注入),混入关闭时刻会让
    /// 没复盘过的用户错误显示「自上次复盘以来」。onAppear 读回,重启后
    /// 冷却仍生效;曝光分母随 `entryCardVisible` 单一来源同步收窄。
    @State private var entryCardDismissedAt: Date?

    /// 内容字号判定(2026-10-19):入口卡在 xL 起切竖排——fixedSize 胶囊占宽
    /// 过大,横排会把左侧文案挤出可视区(截图实测 AX5+en 主文案被压没;CoreText
    /// 实测非 AX 的 xL/xxL 档 en/ja 主文案 2 行×0.7 缩放下限也超预算,同机制)。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// sheet 收起(2026-10-24 收起可发现性):右上角 × 的动作——本页以 sheet
    /// 呈现时的显式退出入口,与下滑手势并存;仅 showsSheetCloseButton 为 true
    /// 时渲染,push/preview 语境不出现。
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            PaperTextureBackground()

            ScrollView {
                // 2026-10-24 拍板:入口卡从两态置顶改为底部悬浮(本 ScrollView
                // 尾部的 safeAreaInset)——冷却期(7 天内已复盘)整卡隐藏,
                // 列表只留统计与笔记;下滑关闭手势维持标准 sheet 行为不变。
                // 按窗取数改造:数字异步就绪(nil = 首帧未加载,渲染空而不闪
                // 「还没有完成」的空态文案——那对有数据的老用户是错误信息)。
                VStack(spacing: WarmSpacing.lg) {
                    if let fixedWindowSummary = fixedSummary {
                        if fixedWindowSummary.total == 0 {
                            emptyState

                            // 空态也显示笔记时间线:「全量可见」拍板不因当期无完成数据
                            // 而失效——有历史笔记的老用户换期后仍要能翻到。
                            if !reviewNotes.isEmpty {
                                reviewNotesSection
                            }
                        } else if let periodSummary {
                            content(fixedWindowSummary: fixedWindowSummary, periodSummary: periodSummary)
                        }
                    }
                }
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.bottom, WarmSpacing.xxl)
            }
            // 入口卡悬浮层(2026-10-24 拍板):钉在屏幕底部、不随列表滚动,
            // 空态/非空态共用;冷却期(`entryCardInCooldown`,距上次复盘或手动
            // × 关闭不足 7 天)整卡隐藏——复盘完关掉流程回本页,底部即刻干净。safeAreaInset
            // 自动为滚动内容让出底部空间,列表末项可滚到卡上方;卡只是可点击
            // 按钮,不加任何手势,不拦截 sheet 的下滑关闭。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if entryCardVisible {
                    reviewFlowEntryCard
                        .padding(.horizontal, WarmSpacing.lg)
                        .padding(.bottom, WarmSpacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                loadReviewNotes()
                // 手动关闭时刻一并恢复(首帧即定显隐,不闪卡)。
                entryCardDismissedAt = ReviewEntryDismissStore.shared.dismissedAt()
                // 复盘漏斗 A15(v5 T1/E8):入口卡随本页常驻,页出现即曝光;
                // 按 app 会话去重——反复进出统计页不刷量。store 为 nil 时
                // 入口卡不渲染(设置深链/preview 路径),没见过入口的用户
                // 不得进曝光分母(口径=「见过入口的用户数」)。2026-10-24
                // 悬浮改版:冷却期(7 天内已复盘或已手动关闭)卡同样不可见,
                // 同步不进曝光分母——复用 `entryCardVisible` 单一来源,两处永不漂移。
                // pendingCount 走 store.todos 工作集同步可算,曝光分母不受
                // 按窗取数异步加载影响。
                if entryCardVisible {
                    let pendingCount = decidablePendingCount
                    ReviewFunnelMetrics.recordEntryImpressionOnce(hasPending: pendingCount > 0)
                }
            }
            // 按窗取数:首次出现与切换「本周 / 本月」都重查(窗口变了);
            // 查询走后台 @ModelActor,返回值类型,不阻塞渲染。
            .task(id: selectedPeriod) {
                await reloadSummaries()
            }
            // 复盘流程收尾(fullScreenCover 落下)会写入新会话——此刻重读,
            // 时间线立即出现刚写的那条;冷却翻 true 驱动悬浮卡滑出(唯一动画
            // 路径,见 `loadReviewNotes(animated:)`)。流程里划卡/拆小写过库,
            // 统计窗一并重查(拆小产生的子任务 createdAt=now 会进「新增」窗口)。
            .onChange(of: showReviewFlow) { _, shown in
                if !shown {
                    loadReviewNotes(animated: true)
                    Task { await reloadSummaries() }
                }
            }
        }
        .fullScreenCover(isPresented: $showReviewFlow) {
            if let store {
                ReviewFlowView(
                    store: store,
                    splitter: splitter,
                    voiceInput: voiceInput,
                    noteAnalyzer: noteAnalyzer,
                    deepReader: deepReader
                )
            }
        }
        .navigationTitle(String(localized: "review.nav_title"))
        .navigationBarTitleDisplayMode(.inline)
        // 右上角关闭(2026-10-24 收起可发现性):给不用下滑手势的用户兜底的
        // 明确退出入口;下滑收起照常,横条见 HomeView.reviewSheetContent。
        // a11y 文案复用 panel.close(关闭/Close/閉じる,三语现成)。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if showsSheetCloseButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(String(localized: "panel.close"))
                    .accessibilityIdentifier("ReviewSheetClose")
                }
            }
        }
    }

    // MARK: Review Flow Entry

    /// 入口卡 N 的口径(v5.1 冷启动拍板):与流程侧 `ReviewFlowState.triageInput`
    /// 同人口——已排未来用户日的不算「等你决定」(已排期=已有去向);委托同一
    /// 函数取数,谓词不二写。曝光埋点 hasPending 同用本值,单一来源防两处漂移。
    ///
    /// 数据源是 `store.todos` 工作集(全部未完成 + 近期完成)而非全量表:
    /// triageInput 的过滤条件是 `!isCompleted && abandonedAt == nil &&
    /// recurrenceRule == nil`,工作集恰好完整覆盖这个集合(完成态被过滤掉,
    /// 近期完成的窗口化不影响),内存过滤即可——同步可算,首帧就有数,
    /// 入口卡不闪「0 件事」(等价性护栏:ReviewWindowQueryParityTests)。
    private var decidablePendingCount: Int {
        guard let store else { return 0 }
        return ReviewFlowState.triageInput(from: store.todos).count
    }

    /// 入口卡冷却时长(2026-10-24 拍板):滚动 7 天窗口——距上次复盘完成或
    /// 手动关闭(2026-10-27 × 按钮,复用同一窗口)不足 7 天时悬浮入口卡隐藏,
    /// 从触发时刻起算、不锚定周一。与产品周节奏(周一 9:00 通知 / 会话容量
    /// 52 条/年)对齐,但按用户自己的节奏走:哪天触发哪天起算,保证清净整整
    /// 7 天;期间再复盘一次则重新起算。
    private static let entryCardCooldown: TimeInterval = 7 * 24 * 60 * 60

    /// 入口卡是否处于冷却期(7 天内已复盘**或**已手动关闭)。判定委托
    /// `ReviewEntryCooldown` 纯函数(单测覆盖双锚点取近)。`lastReviewDate` 随
    /// `loadReviewNotes()` 刷新(onAppear + 复盘流程 fullScreenCover dismiss),
    /// 复盘完成关掉流程的瞬间本值翻 true,悬浮卡即刻消失;首次复盘前
    /// (nil)不冷却,卡常驻。
    private var entryCardInCooldown: Bool {
        ReviewEntryCooldown.isCoolingDown(
            lastReviewCompletedAt: lastReviewDate,
            manuallyDismissedAt: entryCardDismissedAt,
            now: Date(),
            window: Self.entryCardCooldown
        )
    }

    /// 悬浮入口卡的显示条件单一来源:悬浮层挂载与 A15 曝光分母共用,
    /// 防「见到的才算曝光」与实际渲染条件两处漂移。
    private var entryCardVisible: Bool {
        store != nil && !entryCardInCooldown
    }

    /// 复盘入口卡(2026-08-23 拍板改版):一行动作行——icon + 「N 件事等你决定」
    /// + 尾部胶囊「开始复盘 →」(2026-10-19 文案改版,点明去向并与「完成复盘」
    /// 对仗)。N = `decidablePendingCount`(决定人口,拍板 4 + v5.1)。
    ///
    /// 改版动机:旧三行卡(title/pending/scope)读起来像信息展示,且「一次性任务」
    /// 是内部模型泄漏(用户没有这个分类);「回顾近 30 天」消歧义移进流程第 1 步;
    /// 「上次复盘日期」也移第 1 步(从 previousSessions 取,不再外部注入)。
    /// 位置变迁:8-23 起挂列表内 → 10-19 置顶两态 → 10-24 底部悬浮(body 的
    /// safeAreaInset;冷却期 `entryCardInCooldown` 整卡隐藏)。
    /// N == 0 时空态文案「都清完了,看看这一个月」——卡不消失(冷却期除外:
    /// 隐藏的是「时机」不是「价值」),回顾本身仍有价值。
    ///
    /// 2026-10-27:右上角 × 手动收卡——不想复盘的用户此前没有任何出口,只能
    /// 等冷却自然过期。× 与整卡 Button 平级(外层 ZStack,不嵌套),手势互不
    /// 冲突;收卡写 `ReviewEntryDismissStore`,复用同一 7 天冷却(统计条/通知
    /// 仍是复盘入口,关卡≠关功能)。关闭语义见 `entryCardDismissButton`。
    @ViewBuilder
    private var reviewFlowEntryCard: some View {
        let pendingCount = decidablePendingCount
        let hasPending = pendingCount > 0

        ZStack(alignment: .topTrailing) {
            Button {
                showReviewFlow = true
            } label: {
                RecapCard {
                    if dynamicTypeSize >= .xLarge {
                        // xL 起竖排(2026-10-19):fixedSize 胶囊占宽过大,横排会把左侧
                        // 文案挤出可视区(AX5+en 截图实测主文案被压没;CoreText 实测
                        // 393pt 下 xxL 档 en 主文案 2 行×0.7 下限 117pt > 实得 97pt,
                        // 375pt 机型 xL 即超)——竖排让文案占整行宽,胶囊换行置底。
                        // DynamicTypeSize 的 Comparable 序把 AX1-5 排在 xxxL 之上,
                        // 本门槛天然覆盖全部 AX 档。
                        VStack(alignment: .leading, spacing: WarmSpacing.sm) {
                            HStack(spacing: WarmSpacing.md) {
                                entryIcon()
                                entryTexts(hasPending: hasPending, pendingCount: pendingCount)
                            }
                            entryCapsule(hasPending: hasPending)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: WarmSpacing.md) {
                            entryIcon()
                            entryTexts(hasPending: hasPending, pendingCount: pendingCount)
                                .layoutPriority(1)

                            Spacer(minLength: WarmSpacing.xs)
                            entryCapsule(hasPending: hasPending)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ReviewFlowEntryCard")

            entryCardDismissButton
        }
    }

    /// 入口卡右上角 ×(2026-10-27 拍板):不想复盘的用户主动收卡。点击写关闭
    /// 时刻进 `ReviewEntryDismissStore`,复用同一 7 天冷却——关闭的只是「入口
    /// 时机」,复盘功能不关(统计条/通知仍是入口,7 天后卡自动回来,无永久
    /// 关闭出口)。
    ///
    /// 形态:44pt 热区(a11y 推荐下限)垫 20pt 卡色圆底——AX 大字号下主文案
    /// 可能延伸到卡右上,底衬保证压在文字上仍可读;横排下与尾部胶囊仅有
    /// 边缘小片重叠(胶囊中心远离热区),竖排/AX 完全无碰撞。a11y 文案复用
    /// `panel.close`(zh/en/ja 现成,不新增 key)。
    private var entryCardDismissButton: some View {
        Button {
            dismissEntryCard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WarmTheme.textMuted)
                .padding(WarmSpacing.xs)
                .background(Circle().fill(WarmTheme.cardBackground))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "panel.close"))
        .accessibilityIdentifier("ReviewEntryCardDismiss")
    }

    /// × 的动作:记录关闭时刻(store 内落 `review_entry_dismiss.set` 结构化
    /// 日志,可回答「多少人主动关掉了入口卡」)+ 带动画收卡——与复盘完成
    /// 滑出同款事务与曲线(`loadReviewNotes(animated:)` 同源)。
    private func dismissEntryCard() {
        let now = Date()
        ReviewEntryDismissStore.shared.markDismissed(now)
        withAnimation(.easeInOut(duration: 0.25)) {
            entryCardDismissedAt = now
        }
    }

    /// 入口卡图标——「有事要批改/决定」的心智锚。
    private func entryIcon() -> some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 22))
            .foregroundColor(WarmTheme.primary)
    }

    /// 入口卡文案区:主文案(N 件事等你决定)+ 范围标。
    ///
    /// 范围标(2026-09-04 拍板 B1;2026-09-07 修正口径):点进流程前就锚定窗口
    /// 口径——割裂感发生在点之前。锚定对象是**流程**的窗口(v3 拍板 1:上次复盘
    /// 至今,首次复盘回落近 7 天),不是本页统计窗口——两窗有意分叉,Hero 的
    /// 「近 30 天」属 `fixedWindowSummary`,与此处无关。键与三元判断和第 1 步
    /// `ReviewStepRecap.scopeHeader` 同源,别让两处漂移。信息层级刻意低于主文案,
    /// 不加第三行/图标,不要退回 8-23 否掉的「信息展示卡」。
    /// AX 档隐藏(2026-10-19):en AX5 下 caption 缩放后仍超整行宽
    /// (「Since your last revi…」实测截断)——非必要元素让位(零容忍规则);
    /// 口径信息点进流程第 1 步 `scopeHeader` 同键再现,不丢信息。
    /// `pendingCount` 由调用方单次捕获传入——`decidablePendingCount` 是 O(全表)
    /// 计算属性,主文案键插值与 hasPending 判定共值,不求值两次。
    private func entryTexts(hasPending: Bool, pendingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            Text(String(localized: hasPending
                ? "review.flow.entry.pending_\(pendingCount)"
                : "review.flow.entry.empty"))
                .font(WarmFont.headline(15))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            if !dynamicTypeSize.isAccessibilitySize {
                Text(String(localized: lastReviewDate != nil
                    ? "review.flow.recap.scope_since"
                    : "review.flow.recap.scope_first"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// 尾部胶囊是动作暗示:这一行是「进去做事」,不是信息展示。
    ///
    /// fixedSize(2026-10-19):胶囊绝不退让,横排下左侧 priority-1 文字换行让位
    /// (PendingDateTodoRow 同款拍板模式)——否则大字号下左侧先占满,胶囊文字被
    /// 压成残影(用户截图中「! →」即「Start」被挤剩的笔画)。xL 起胶囊占宽过大会
    /// 反噬左侧,由外层切竖排兜底。
    private func entryCapsule(hasPending: Bool) -> some View {
        HStack(spacing: WarmSpacing.xxs) {
            Text(String(localized: "review.flow.entry.action"))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .flipsForRightToLeftLayoutDirection(true)
        }
        .fixedSize()
        .font(WarmFont.headline(13))
        .foregroundColor(.white)
        .padding(.horizontal, WarmSpacing.md)
        .padding(.vertical, WarmSpacing.xs)
        .background(
            Capsule().fill(hasPending ? WarmTheme.primary : WarmTheme.primary.opacity(0.75))
        )
    }

    // MARK: - Computed(按窗取数)

    /// 两个统计窗(近 30 天 + 所选周/月)与到期范围的边界。集中一处是因为
    /// 两个窗口共用同一次 `dueTodoCount`/`pendingOneOffCount` 取数,且窗口
    /// 推导必须与旧路径(`monthSummary` 内部窗口 / `ReviewPeriod.startDay`)
    /// 完全一致——数字一个不变的前提是窗口一天不差。
    private struct SummaryWindows {
        let fixedStart: Date
        let periodStart: Date
        let end: Date
        /// 未来 7 天到期数的换算边界:旧内存过滤
        /// `dueDay > todayStart && dueDay <= weekEnd`(用户日)≡
        /// `dueDate ∈ [dueOnOrAfter, dueBefore)`(时刻),等价性见
        /// `TodoQueryActor.dueTodoCount` 注释。
        let dueOnOrAfter: Date
        let dueBefore: Date
        let periodLabel: String

        init(period: ReviewPeriod, today: Date, calendar: Calendar) {
            let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
            let monthAgo = calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
            // 与 monthSummary 的窗口推导逐字一致(滚动 30 天 = 日历减一月)。
            fixedStart = monthAgo
            periodStart = period.startDay(from: today, calendar: calendar)
            end = period.endDay(from: today, calendar: calendar)
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart
            dueOnOrAfter = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
            dueBefore = calendar.date(byAdding: .day, value: 1, to: weekEnd) ?? weekEnd
            periodLabel = period.periodLabel(for: today, calendar: calendar)
        }
    }

    /// 按窗取数并聚合两份摘要(fixed 30 天 + 所选周期)。store 为 nil(纯
    /// preview/无注入语境)时无数据源,保持 nil 渲染空。失败显式记录并保留
    /// 上一份数字(读路径不打断页面;切周期/复盘 dismiss 会重试)。
    private func reloadSummaries() async {
        guard let store else { return }
        let today = Date()
        let requestedPeriod = selectedPeriod
        let windows = SummaryWindows(period: requestedPeriod, today: today, calendar: calendar)
        do {
            // 三个窗口查询并发下发;pendingOneOff 从工作集内存过滤(同入口卡口径)。
            async let fixedInputs = store.reviewWindowInputs(from: windows.fixedStart, to: windows.end)
            async let periodInputs = store.reviewWindowInputs(from: windows.periodStart, to: windows.end)
            async let dueCount = store.dueTodoCount(dueOnOrAfter: windows.dueOnOrAfter, dueBefore: windows.dueBefore)
            let pendingCount = ReviewAggregator.pendingOneOffCount(store.todos)

            let (fixed, period, upcoming) = try await (fixedInputs, periodInputs, dueCount)
            // 过期写回护栏:快速切周期时 `.task(id:)` 取消的旧任务仍会跑完
            // (取消是协作式的,actor 查询不检查取消),若它在新任务之后落笔,
            // 两份摘要会停留在已不再选中的周期窗口且无自动纠正——赋值前校验
            // 周期仍与出发时一致,且任务未被取消。
            guard selectedPeriod == requestedPeriod, !Task.isCancelled else { return }
            // 与旧路径同一对聚合入口、同一批口径参数(标签同样锚定「近 30 天」)。
            fixedSummary = RecapSummaryBuilder.summary(
                calendar: calendar,
                periodLabel: String(localized: "review.window.last30d"),
                start: windows.fixedStart,
                end: windows.end,
                inputs: fixed,
                pendingOneOffCount: pendingCount,
                upcomingDueIn7DaysCount: upcoming
            )
            periodSummary = RecapSummaryBuilder.summary(
                calendar: calendar,
                periodLabel: windows.periodLabel,
                start: windows.periodStart,
                end: windows.end,
                inputs: period,
                pendingOneOffCount: pendingCount,
                upcomingDueIn7DaysCount: upcoming
            )
        } catch {
            // 读失败不静默:error 日志显式留痕;页面保留上一份数字(首次失败
            // 则渲染空),切周期/复盘 dismiss/重进页面会自动重试——统计页没有
            // 「正确的降级数字」,不拿默认值掩盖失败(CLAUDE.md 错误显式传播)。
            VoiceTodoLog.coordinator.error("review.summary.load.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        VStack(spacing: WarmSpacing.lg) {
            Spacer()

            EmptyStateView(
                icon: "chart.pie",
                message: String(localized: "review.empty.message"),
                iconSize: 44,
                opacity: 0.6
            )

            emptyPreviewCard

            Spacer()
        }
    }

    /// 空态说明卡——告诉用户累计数据后会看到什么,把空白变成期待,
    /// 而不是只摆一个图标让人觉得「这个 app 啥也没有」。
    private var emptyPreviewCard: some View {
        RecapCard {
            Text(String(localized: "review.empty.preview"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func content(fixedWindowSummary: ReviewSummary, periodSummary: ReviewSummary) -> some View {
        VStack(spacing: WarmSpacing.lg) {
            // 2026-10-24 拍板:入口卡移至 body 尾部的底部悬浮层,列表顶部
            // 直接进成绩单;冷却期(7 天内已复盘)悬浮层整卡隐藏。

            // Hero/Stats 固定近 30 天(拍板 A):picker 只管下方图表区,
            // 切周/月不再牵动成绩单——窗口口径见 docs/review-window-tab-decoupling.md。
            RecapHeroSection(summary: fixedWindowSummary)

            RecapStatsRow(summary: fixedWindowSummary)

            // ── picker 辖区从这里开始(内联,不再吸顶):只管图表,不管上方成绩单 ──
            periodPicker

            // 空态判定与图表区窗口拆分后(d8f9c33)新增的可达状态:30 天有数据、
            // 选中的周窗口零完成。此时图表区整体退一行提示——不渲染空标题的分类卡,
            // 也不走稀疏拼接(activeDays 为空会拼出「，其余日期无记录」残句)。
            if periodSummary.total == 0 {
                periodEmptyHint
            } else {
                RecapCategoryChartSection(byCategory: periodSummary.byCategory)

                dailyTrendSection(periodSummary: periodSummary)

                if let busiest = periodSummary.busiestDay {
                    busiestDaySection(periodSummary: periodSummary, date: busiest)
                }
            }

            if !reviewNotes.isEmpty {
                reviewNotesSection
            }
        }
    }

    // MARK: 复盘笔记时间线

    /// 「复盘笔记」:历次复盘写过的话,随时可翻(2026-08-23 拍板)。无笔记整节隐藏。
    private var reviewNotesSection: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.notes.title"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                ReviewNotesListView(entries: reviewNotes)
            }
        }
    }

    /// 读取历次笔记(只留写了内容的会话,新→旧);顺带取最近一次会话时刻
    /// 作为入口卡范围标的口径(全量会话升序,`.last` 即最近,与流程侧同源)。
    /// `animated: true` 仅用于复盘流程 dismiss 路径——冷却翻转在此事务内
    /// 驱动悬浮卡 `.transition` 滑出;onAppear 初载传 false,首帧后即使翻进
    /// 冷也只做无动画移除,杜绝「卡片闪现后滑走」。
    private func loadReviewNotes(animated: Bool = false) {
        let sessions = ReviewSessionStore.shared.allSessions()
        let notes = ReviewNotesEntry.make(from: sessions)
        let last = sessions.last?.completedAt
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                reviewNotes = notes
                lastReviewDate = last
            }
        } else {
            reviewNotes = notes
            lastReviewDate = last
        }
    }

    // MARK: Period Picker

    private var periodPicker: some View {
        Picker(String(localized: "review.period.title"), selection: $selectedPeriod) {
            ForEach(ReviewPeriod.allCases) { period in
                Text(period.displayText)
                    .tag(period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ReviewPeriodPicker")
    }

    /// 选中周期(仅周可能:月窗口与 30 天窗口同式)零完成时,图表区的整区空态——
    /// 一行周期限定提示,替代空标题卡与残句。不用 `review.empty.message`
    /// (「还没有完成的待办」/ "No completed todos yet"):那是整页空态的文案,
    /// 这里同屏上方 Hero 正显示 30 天完成数,复用会自相矛盾。
    private var periodEmptyHint: some View {
        RecapCard {
            Text(String(localized: "review.period.empty"))
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Daily Trend

    /// 数据稀疏(<3 天有完成)时换文本态,避免画一堆空柱子观感像「这月啥也没干」。
    /// 文本态直接用一句话告诉用户「7月24日完成 2 项,其余日期无记录」。
    /// 图表态再画 BarMark,X 轴刻度按周/月差异化(月=每 7 天一标,周=全标)。
    private func dailyTrendSection(periodSummary: ReviewSummary) -> some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.daily_trend"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)

                if periodSummary.daysWithCompletion < 3 {
                    sparseTrendText(periodSummary: periodSummary)
                } else {
                    dailyTrendChart(periodSummary: periodSummary)
                    trendConclusion(periodSummary: periodSummary)
                }
            }
        }
    }

    /// 稀疏态文本:把所有有完成的天按日期顺序列出,以「,」分隔,末尾接「其余日期无记录」。
    /// 阈值 <3 天意味着最多 2 天需要描述,句子不会过长。
    private func sparseTrendText(periodSummary: ReviewSummary) -> some View {
        let activeDays = periodSummary.byDay
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
        let segments: [String] = activeDays.map { day, count in
            let dateText = day.formatted(.dateTime.month().day())
            return String(localized: "review.sparse.day_\(dateText)_\(count)")
        }
        let joined = segments.joined(separator: String(localized: "review.sparse.separator"))
        let sentence = joined + String(localized: "review.sparse.tail")

        return Text(sentence)
            .font(WarmFont.body(14))
            .foregroundColor(WarmTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dailyTrendChart(periodSummary: ReviewSummary) -> some View {
        let trendData = dailyTrendData(periodSummary: periodSummary)
        let todayStart = DayClock.startOfUserDay(for: Date(), calendar: calendar)
        return Chart {
            ForEach(trendData, id: \.day) { entry in
                BarMark(
                    x: .value(String(localized: "review.chart.day"), entry.day, unit: .day),
                    y: .value(String(localized: "review.chart.count"), entry.count)
                )
                .foregroundStyle(WarmTheme.primary)
                .cornerRadius(4)
            }

            // 灰点:过去但 count=0 的日子(不含今天,今天没完成不算「没做」)。
            // 区分「没做」和「还没到」——未来日本来就没柱子,过去日没柱子会显灰点。
            ForEach(trendData.filter { $0.count == 0 && $0.day < todayStart }, id: \.day) { entry in
                PointMark(
                    x: .value(String(localized: "review.chart.day"), entry.day, unit: .day),
                    y: .value(String(localized: "review.chart.mark"), 0)
                )
                .foregroundStyle(WarmTheme.textMuted.opacity(0.35))
                .symbolSize(14)
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisDates) { _ in
                AxisValueLabel(format: .dateTime.day(.defaultDigits))
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 160)
    }

    /// 图表下方一行结论:本月/本周共完成 N 项,最忙那天 M 项。
    /// 仅在图表态显示(稀疏态已有自己的替代文案,不重复堆叠)。
    @ViewBuilder
    private func trendConclusion(periodSummary: ReviewSummary) -> some View {
        if let busiest = periodSummary.busiestDay, periodSummary.busiestDayCount > 0 {
            let dateText = busiest.formatted(.dateTime.month().day())
            let sentence = String(localized: "review.trend.summary_\(periodSummary.total)_\(dateText)_\(periodSummary.busiestDayCount)")
            Text(sentence)
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dailyTrendData(periodSummary: ReviewSummary) -> [(day: Date, count: Int)] {
        let today = Date()
        let start = selectedPeriod.startDay(from: today, calendar: calendar)

        var result: [(day: Date, count: Int)] = []
        var cursor = start
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        // byDay 由调用方传入(聚合算一次缓存在 @State,不再每次 body 重算)。
        let byDay = periodSummary.byDay

        while cursor <= todayStart {
            let count = byDay[cursor] ?? 0
            result.append((day: cursor, count: count))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        return result
    }

    /// X 轴刻度日期。
    /// 月视图:每 7 天一标(起始日 + 7/14/21/28 日,过滤掉超过今天的),
    /// 避免 31 格全标导致数字叠成「2456789012345...」。
    /// 周视图:7 天全标,空间够。
    private var xAxisDates: [Date] {
        let today = Date()
        let start = selectedPeriod.startDay(from: today, calendar: calendar)
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)

        switch selectedPeriod {
        case .week:
            var dates: [Date] = []
            var cursor = start
            while cursor <= todayStart {
                dates.append(cursor)
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            return dates
        case .month:
            return [0, 7, 14, 21, 28]
                .compactMap { offset in
                    calendar.date(byAdding: .day, value: offset, to: start)
                }
                .filter { $0 <= todayStart }
        }
    }

    // MARK: Busiest Day

    /// 单行布局,修复旧版「·」孤立断行的问题。
    /// 旧布局:VStack { Text("最活跃的一天 · 完成 N 件") + Text("7月24日 周三") } —
    /// 当 headline 强制换行时,「·」会留在第一行末尾,看起来像个孤立符号。
    /// 新布局:整句一个 Text,文案是「最忙的一天:7月24日 周三 · 完成 2 项」,
    /// 让 SwiftUI 整行排版,「·」前后都有内容,不会孤立。
    private func busiestDaySection(periodSummary: ReviewSummary, date: Date) -> some View {
        RecapCard {
            HStack(spacing: WarmSpacing.md) {
                Image(systemName: "star.fill")
                    .font(.system(size: 28))
                    .foregroundColor(WarmTheme.warning)

                Text(busiestDayOneLiner(periodSummary: periodSummary, date: date))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
        }
    }

    private func busiestDayOneLiner(periodSummary: ReviewSummary, date: Date) -> String {
        // 星期恒用 `.abbreviated`:英文 "Monday" → "Mon",中文 "星期一" → "周一"。
        // 与 HomeView todayWeekdayTitle 保持一致。
        let dateText = date.formatted(.dateTime.month().day().weekday(.abbreviated))
        return String(localized: "review.busiest.oneline_\(dateText)_\(periodSummary.busiestDayCount)")
    }
}

// MARK: - Preview
//
// 按窗取数改造后统计走 store(ReviewSummaryReading),preview 不再裸建容器——
// 用同一容器构造 TodoStore 注入,数字链路与生产一致(入口卡/复盘入口也随之
// 可见,preview 更接近真实形态)。

#Preview("With Data") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)

    let now = Date()
    let cal = Calendar.current
    let categories: [TodoCategory] = [.work, .study, .life, .health, .other]
    for i in 0..<15 {
        let dayOffset = -(i % 10)
        let date = cal.date(byAdding: .day, value: dayOffset, to: now)!
        // 给 dueDate(与完成同一天),保持与真实数据形状一致。
        let item = TodoItem(
            title: "Preview item \(i)",
            dueDate: date,
            category: categories[i % categories.count],
            isCompleted: true,
            completedAt: date
        )
        container.mainContext.insert(item)
    }
    // 加一个未来 7 天到期的待办,验证「未来 7 天还有 N 项」副文案。
    let futureDate = cal.date(byAdding: .day, value: 3, to: now)!
    container.mainContext.insert(TodoItem(
        title: "Upcoming item",
        dueDate: futureDate,
        category: .work
    ))

    let store = TodoStore(modelContext: container.mainContext, forceMigration: true)
    return NavigationStack {
        ReviewView(store: store)
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Sparse") {
    // 整月只有今天完成 2 项,触发稀疏文本态:Daily Trend 切到一句话,
    // Category 也走横条(2 类各 1 件)。两件都到期于今天。
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)

    let now = Date()
    container.mainContext.insert(TodoItem(
        title: "Item A",
        dueDate: now,
        category: .work,
        isCompleted: true,
        completedAt: now
    ))
    container.mainContext.insert(TodoItem(
        title: "Item B",
        dueDate: now,
        category: .life,
        isCompleted: true,
        completedAt: now
    ))

    let store = TodoStore(modelContext: container.mainContext, forceMigration: true)
    return NavigationStack {
        ReviewView(store: store)
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TodoItem.self, configurations: config)
    let store = TodoStore(modelContext: container.mainContext, forceMigration: true)

    return NavigationStack {
        ReviewView(store: store)
    }
    .modelContainer(container)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}
