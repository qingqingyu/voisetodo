import SwiftUI

// MARK: - 成绩单组件(ReviewView 与复盘第 1 步共用)
//
// 从 `ReviewView` 抽出的 internal 组件(阶段 3,docs/todo-review-flow-design.md
// 「入口与既有页面」):`ReviewView`(日常随手看)与 `ReviewStepRecap`(五步流程
// 第 1 步,压到 10 秒能看完)共用,**别在两处复制**。纯搬移重构,视觉/行为零变化。

/// Hero 主标题内容(v3 拍板 2):回顾页默认 = 完成数;复盘第 1 步在有上次
/// 置顶结局时升级为兑现判词。沿用 `promotesSameDay` 的参数化模式——
/// 默认值 = 回顾页现状,回顾页调用点零变化(审阅缺口 A)。
enum RecapHeroContent {
    /// 回顾页现状:大数字 + 周期标签。
    case countSummary
    /// 兑现判词(v3 ① 屏主副对调):上次置顶的结局当主标题,完成数降为
    /// `RecapEvidenceRow` 的 Done 卡。
    case pinnedOutcome(total: Int, completed: Int)
}

/// Hero 区:大数字 + 周期标签。
struct RecapHeroSection: View {
    let summary: ReviewSummary
    /// sameDay 判词主体化(2026-09-01 拍板,复盘第 1 步):true 时「当天记
    /// 当天做完」与总数同级呈现。默认 false = 回顾页原样(13pt 副行)——
    /// 本组件两页共用(见文件头),回顾页行为不动(审阅缺口 A)。
    var promotesSameDay: Bool = false
    /// 主标题内容(v3 拍板 2)。默认 = 回顾页现状;复盘第 1 步传
    /// `.pinnedOutcome` 或(空态回退)`.countSummary`——不硬造「上次没有
    /// 承诺」的空标题,兑现判词是有上次承诺才有的话。
    var heroContent: RecapHeroContent = .countSummary

    /// sameDay 判词门槛(v3 ① 改动 4):占比(分子分母同为一次性完成口径)
    /// **超过**该值时出判词。注意文案约束:门槛 < 50% 时当天组可能仍是少数,
    /// 判词只允许「相当一部分」级别的份额事实,不写「更多/更少」比较级。
    private static let sameDayJudgmentThreshold = 0.4

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            switch heroContent {
            case .countSummary:
                Text(String(localized: "review.hero.count_\(summary.total)"))
                    .font(WarmFont.serifDisplay(40))
                    .foregroundColor(WarmTheme.primary)
                    .accessibilityIdentifier("ReviewHeroCount")

                Text(summary.periodLabel)
                    .font(WarmFont.caption(14))
                    .foregroundColor(WarmTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

            case .pinnedOutcome(let total, let completed):
                // 兑现判词主标题(v3 拍板 2):周期标签不跟——它描述的是
                // 完成数窗口,而判词说的是上次置顶那批的结局,两个口径。
                Text(String(
                    localized: "review.flow.recap.pinned_outcome_hero_\(total)_\(completed)"
                ))
                    .font(WarmFont.serifDisplay(32))
                    .foregroundColor(WarmTheme.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WarmSpacing.lg)
                    .accessibilityIdentifier("ReviewHeroPinnedOutcome")
            }

            // 「当天记、当天做完」件数(2026-08-21 用户拍板加上)。区间内没有
            // 完成时不显示——「其中 0 件」是噪音。一次性任务口径,与洞察 03 一致。
            // 整块收窄居中(2026-08-23 打磨):长句换行后不再撑满行宽,与上方
            // 居中的数字保持同一视觉节奏。
            if summary.total > 0 {
                Text(String(localized: "review.hero.sameday_\(summary.sameDayCount)"))
                    .font(promotesSameDay ? WarmFont.body(15) : WarmFont.caption(13))
                    .foregroundColor(promotesSameDay ? WarmTheme.primaryText : WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WarmSpacing.xl)

                // sameDay 判词(v3 ① 改动 4,仅复盘第 1 步):占比超门槛时接
                // 一句判定。分母用 oneOffCompletionCount(同口径——分子只数
                // 一次性完成,分母不能是 total,审阅修订二);文案只说份额事实,
                // 不写「更多/更少」比较级——40% 门槛刚触发时当天组仍是少数,
                // 比较级会被同屏数字当场证伪(审阅修订三)。
                if promotesSameDay, summary.oneOffCompletionCount > 0,
                   Double(summary.sameDayCount) / Double(summary.oneOffCompletionCount)
                       > Self.sameDayJudgmentThreshold {
                    Text(String(localized: "review.hero.sameday_judgment"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, WarmSpacing.xl)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stats 行:streak 卡 + 本期完成卡。
/// 完成率已下岗(2026-08-23 拍板):比率与入口卡待处理数不同分母同屏会自相矛盾
/// (「100% + 5 件没做」),且违反洞察引擎反 gaming 章程,改显绝对数。
/// 副文案「未来 7 天还有 N 项」在 N>0 时才显示,避免空文案占位。
/// ⚠️ 仅回顾页在用(2026-09-01 v2:第 1 步换 `RecapEvidenceRow`,streak 卡
/// 按拍板 5 从流程里下岗;回顾页保持成绩单角色不动,审阅缺口 A)。
struct RecapStatsRow: View {
    let summary: ReviewSummary

    var body: some View {
        HStack(spacing: WarmSpacing.md) {
            RecapStatCard(
                icon: "flame.fill",
                value: "\(summary.streakDays)",
                label: String(localized: "review.stat.streak")
            )

            RecapDoneCard(summary: summary)
        }
    }
}

/// 三数证据行(2026-09-01 拍板,复盘第 1 步专用):「完成 N / 新增 M /
/// 还挂着 K」——判词的证据链,清单在变长还是变短,三个数并排自己会说。
/// 数字口径见 `ReviewSummary.createdCount` / `pendingOneOffCount` 注释
/// (还挂着与入口卡「N 件事等你决定」、第 2 步卡堆同源)。
/// v3 拍板 3:Done/Added 已同窗(拍板 1),Still open 是全时段口径——
/// 差异必须说出口,补一行 caption 说明;**不写减法算式**(Added − Done
/// 不是任何真实集合,算式上屏就是新的自相矛盾)。
struct RecapEvidenceRow: View {
    let summary: ReviewSummary

    var body: some View {
        VStack(spacing: WarmSpacing.xxs) {
            HStack(spacing: WarmSpacing.md) {
                RecapStatCard(
                    icon: "checkmark.circle",
                    value: "\(summary.total)",
                    label: String(localized: "review.stat.done")
                )

                RecapStatCard(
                    icon: "plus.circle",
                    value: "\(summary.createdCount)",
                    label: String(localized: "review.stat.created")
                )

                RecapStatCard(
                    icon: "tray",
                    value: "\(summary.pendingOneOffCount)",
                    label: String(localized: "review.stat.pending")
                )
            }

            // 零积压时这行没有对象,不出。
            if summary.pendingOneOffCount > 0 {
                Text(String(localized: "review.stat.pending_note_\(summary.pendingOneOffCount)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WarmSpacing.md)
            }
        }
    }
}

/// 单张统计卡(icon + 大数字 + 标签)。原 ReviewView.statCard。
struct RecapStatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(WarmTheme.primary)

                Text(value)
                    .font(WarmFont.headline(22))
                    .foregroundColor(WarmTheme.textPrimary)
            }

            Text(label)
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, WarmSpacing.md)
        .background(RecapStatCardBackground())
    }
}

/// 本期完成卡(原 completionRateCard 改版,2026-08-23):绝对数 + 标签 + 未来 7 天副文案。
struct RecapDoneCard: View {
    let summary: ReviewSummary

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(WarmTheme.primary)

                Text(verbatim: "\(summary.total)")
                    .font(WarmFont.headline(22))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(String(localized: "review.stat.done"))
                .font(WarmFont.caption(12))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if summary.upcomingDueIn7DaysCount > 0 {
                Text(String(localized: "review.stat.upcoming_7d_\(summary.upcomingDueIn7DaysCount)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, WarmSpacing.md)
        .background(RecapStatCardBackground())
    }
}

/// 统计卡背景块。原 statCard / completionRateCard 里重复了两遍的背景,
/// 收编为单一来源(阶段 3 顺带收编项)。
struct RecapStatCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: WarmRadius.card, style: .continuous)
            .fill(WarmTheme.cardBackground)
            .shadow(color: WarmTheme.shadowLight, radius: 6, x: 0, y: 3)
    }
}

/// 分类横条图卡(原 ReviewView.categoryChartSection)。
/// 旧版用 SectorMark(甜甜圈):2 类各 1 件时画成半圆纯属装饰,
/// 类别超过 4 个色块也没法读。横条在任何数量下都准确可读。
struct RecapCategoryChartSection: View {
    let byCategory: [TodoCategory: Int]

    private var data: [(category: TodoCategory, count: Int)] {
        byCategory
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, count: $0.value) }
    }

    var body: some View {
        RecapCard {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                Text(String(localized: "review.section.category"))
                    .font(WarmFont.headline(16))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                VStack(spacing: WarmSpacing.sm) {
                    let maxCount = max(data.first?.count ?? 1, 1)
                    ForEach(data, id: \.category) { entry in
                        barRow(entry, maxCount: maxCount)
                    }
                }
            }
        }
    }

    /// 单行横条:标签 + 条 + 数量。条宽相对最大值归一化,最长那条占满。
    /// maxCount 由调用方算好传入,避免每行都重新构造 data(O(n^2))。
    private func barRow(_ entry: (category: TodoCategory, count: Int), maxCount: Int) -> some View {
        let ratio = Double(entry.count) / Double(maxCount)

        return HStack(spacing: WarmSpacing.sm) {
            HStack(spacing: WarmSpacing.xxs) {
                Image(systemName: entry.category.sfSymbolName)
                    .font(.system(size: 14))
                    .foregroundColor(WarmTheme.color(for: entry.category))

                Text(entry.category.displayName)
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .frame(maxWidth: 110, alignment: .leading)

            GeometryReader { proxy in
                let barWidth = proxy.size.width * ratio
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(WarmTheme.color(for: entry.category))
                    .frame(width: barWidth, height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text(verbatim: "\(entry.count)")
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
                .frame(minWidth: 24, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// 卡片容器——统一圆角、背景、阴影(原 ReviewView 私有的 `reviewCard`,
/// 收编后 ReviewView 与 Flow 共用)。
struct RecapCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(WarmSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.section, style: .continuous)
                    .fill(WarmTheme.cardBackground)
                    .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
            )
    }
}

// MARK: - 历次复盘笔记(2026-08-23 拍板「全量可见」)

/// 一条可展示的复盘笔记行:当期日期 + 笔记原文 + 当期处理件数(+ 最新一条的
/// 语义对照关注点,任务 #4)。注:「当期完成数」用 ledger 的处理输入数展示;
/// 会话的 completedCount 是洞察口径,两者语义不同,别混用。
struct ReviewNotesEntry: Equatable, Identifiable {
    let id: UUID
    let date: Date
    let note: String
    let handledCount: Int
    /// 语义对照关注点(收尾后异步回写;nil = 未提取/失败/旧会话)。
    let topics: [ReviewTopic]?

    /// 会话列表 → 展示条目:只留写了笔记的会话,新→旧。
    /// 空白笔记视同没有(与 `ReviewFlowState.lastVoiceNote` 同口径)。
    static func make(from sessions: [ReviewSession]) -> [ReviewNotesEntry] {
        sessions.compactMap { session in
            guard let note = session.voiceNote?
                .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
                return nil
            }
            return ReviewNotesEntry(
                id: session.id,
                date: session.completedAt,
                note: note,
                handledCount: session.ledger.inputCount,
                topics: session.topics
            )
        }
        // 新→旧;同刻(极端场景)按 id 定序,避免 Swift 非稳定排序导致顺序抖动。
        .sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id.uuidString > rhs.id.uuidString : lhs.date > rhs.date
        }
    }
}

/// 历次复盘笔记列表:回顾页时间线与复盘流程第 3 步共用(别复制两份)。
struct ReviewNotesListView: View {
    let entries: [ReviewNotesEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.md) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry)
                if index < entries.count - 1 {
                    Rectangle()
                        .fill(WarmTheme.rowHairline)
                        .frame(height: 1)
                }
            }
        }
    }

    private func row(_ entry: ReviewNotesEntry) -> some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
            HStack(spacing: WarmSpacing.sm) {
                Text(entry.date.formatted(.dateTime.year().month().day()))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Text(String(localized: "review.notes.row.handled_\(entry.handledCount)"))
                    .font(WarmFont.caption(11))
                    .foregroundColor(WarmTheme.textMuted.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(entry.note)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 摘要构建(共用聚合逻辑)

/// 把 @Query 原料聚合成 `ReviewSummary`。两个窗口(ReviewView 与复盘第 1 步
/// 共用聚合核,避免 40 行逻辑复制两份):
/// - `monthSummary`:滚动 30 天(回顾页 / 统计页);
/// - `weekSummary(since:)`:上次复盘至今(v3 拍板 1,复盘第 1 步专用;
///   首次复盘回落近 7 天)。
/// 口径:
/// - 一次性完成 + 规律任务完成记录 union;
/// - 未来 7 天到期数作统计卡副文案(完成率已下岗,2026-08-23)。
enum RecapSummaryBuilder {
    /// 滚动 30 天窗口。
    /// - Parameters:
    ///   - today: 参照「今天」。
    ///   - calendar: 日历(日界走 `DayClock` 用户日)。
    ///   - periodLabel: 周期标签覆盖值。窗口是滚动 30 天,默认日历月名与区间
    ///     错位;两个生产调用方(`ReviewView` / 统计页)都传「近 30 天」,
    ///     缺省保留旧行为(日历月名)。
    ///   - allTodos: 全量待办 DTO(不过滤完成态——分母与分类表都要查父任务)。
    ///   - completedTodos: 已完成的一次性待办 DTO。
    ///   - recurringCompletions: 规律任务完成记录(todoId + completedAt)。
    static func monthSummary(
        today: Date = Date(),
        calendar: Calendar = Calendar.current,
        periodLabel: String? = nil,
        allTodos: [TodoItemData],
        completedTodos: [TodoItemData],
        recurringCompletions: [(id: UUID, todoId: UUID, completedAt: Date)]
    ) -> ReviewSummary {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        let start = calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        // 标签口径(2026-09-04 拍板 B2):窗口是滚动 30 天,默认日历月名与实际
        // 统计区间错位(9/2 时窗口 8/2-9/3 却标「2026年9月」)。调用方显式
        // 传入时以传入为准;缺省保留日历月名旧行为——零回归,未列出的调用方不受影响。
        let label = periodLabel ?? (calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today)
            .formatted(.dateTime.year().month(.abbreviated))
        return buildSummary(
            today: today,
            calendar: calendar,
            label: label,
            start: start,
            end: end,
            allTodos: allTodos,
            completedTodos: completedTodos,
            recurringCompletions: recurringCompletions
        )
    }

    /// 上次复盘至今的窗口(v3 拍板 1,复盘第 1 步专用)。
    ///
    /// 起点取上次复盘**完成时刻**的用户日(与提醒节奏「每周一」对齐——复盘
    /// 窗口跟着复盘走,不跟日历月走);`since == nil`(首次复盘)回落近 7 天。
    /// `periodLabel` 是窗口本身的描述(「8月28日–9月4日」),不是日历月名——
    /// 窗口滚动,月名必然错配(与 tab 拍板 B2 同一结论,回归护栏在测试里)。
    /// 注意:`pendingOneOffCount` 保持全时段口径(与 ② 屏卡堆/入口卡三处
    /// 同源是硬约束,修正 C),窗口只影响 Done/Added/分类/按天。
    static func weekSummary(
        since: Date?,
        today: Date = Date(),
        calendar: Calendar = Calendar.current,
        allTodos: [TodoItemData],
        completedTodos: [TodoItemData],
        recurringCompletions: [(id: UUID, todoId: UUID, completedAt: Date)]
    ) -> ReviewSummary {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        let sinceDay = since.map { DayClock.startOfUserDay(for: $0, calendar: calendar) }
            ?? (calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart)
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        // 展示到「今天」(闭端);统计 end 是明天 0 点(开端)——同一约定。
        let label = "\(sinceDay.formatted(.dateTime.month(.abbreviated).day()))–\(todayStart.formatted(.dateTime.month(.abbreviated).day()))"
        return buildSummary(
            today: today,
            calendar: calendar,
            label: label,
            start: sinceDay,
            end: end,
            allTodos: allTodos,
            completedTodos: completedTodos,
            recurringCompletions: recurringCompletions
        )
    }

    /// 两窗口共用的聚合核(私有):窗口与标签由调用方定,口径此处单一来源。
    private static func buildSummary(
        today: Date,
        calendar: Calendar,
        label: String,
        start: Date,
        end: Date,
        allTodos: [TodoItemData],
        completedTodos: [TodoItemData],
        recurringCompletions: [(id: UUID, todoId: UUID, completedAt: Date)]
    ) -> ReviewSummary {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart

        let upcomingDueIn7DaysCount = allTodos.filter { item in
            guard let due = item.dueDate else { return false }
            let dueDay = DayClock.startOfUserDay(for: due, calendar: calendar)
            return dueDay > todayStart && dueDay <= weekEnd
        }.count

        // 一次性完成 + 规律完成(union,分类取父任务)。
        var events = completedTodos.compactMap { item -> CompletionEvent? in
            guard let completedAt = item.completedAt else { return nil }
            return CompletionEvent(id: item.id, completedAt: completedAt, category: item.category)
        }
        let categoryById = Dictionary(allTodos.map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        for completion in recurringCompletions {
            events.append(CompletionEvent(
                id: completion.id,
                completedAt: completion.completedAt,
                category: categoryById[completion.todoId] ?? .other
            ))
        }

        let result = ReviewAggregator.summarize(
            events: events,
            from: start,
            to: end,
            calendar: calendar,
            upcomingDueIn7DaysCount: upcomingDueIn7DaysCount
        )
        // 「当天记当天做完」只在一次性完成里数(规律完成无 per-occurrence createdAt)。
        let sameDayCount = ReviewAggregator.sameDayCompletions(
            completedTodos,
            from: start,
            to: end,
            calendar: calendar
        )
        // sameDay 判词的同口径分母(v3 审阅修订二):只数一次性完成,
        // 与展示数 total(含规律完成)是两个口径,别合并(见 ReviewSummary 注释)。
        let oneOffCompletionCount = ReviewAggregator.oneOffCompletions(
            completedTodos,
            from: start,
            to: end,
            calendar: calendar
        )
        // 判词证据链的另两个数(2026-09-01 拍板):新增(不过滤规律)与
        // 还挂着(与入口卡/卡堆同口径)。allTodos 不过滤完成态。
        let createdCount = ReviewAggregator.createdInWindow(
            allTodos,
            from: start,
            to: end,
            calendar: calendar
        )
        let pendingOneOffCount = ReviewAggregator.pendingOneOffCount(allTodos)
        return ReviewSummary(
            periodLabel: label,
            total: result.total,
            byCategory: result.byCategory,
            byDay: result.byDay,
            streakDays: result.streakDays,
            busiestDay: result.busiestDay,
            busiestDayCount: result.busiestDayCount,
            upcomingDueIn7DaysCount: result.upcomingDueIn7DaysCount,
            daysWithCompletion: result.daysWithCompletion,
            sameDayCount: sameDayCount,
            createdCount: createdCount,
            pendingOneOffCount: pendingOneOffCount,
            oneOffCompletionCount: oneOffCompletionCount
        )
    }
}
