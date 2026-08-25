import SwiftUI

// MARK: - 成绩单组件(ReviewView 与复盘第 1 步共用)
//
// 从 `ReviewView` 抽出的 internal 组件(阶段 3,docs/todo-review-flow-design.md
// 「入口与既有页面」):`ReviewView`(日常随手看)与 `ReviewStepRecap`(五步流程
// 第 1 步,压到 10 秒能看完)共用,**别在两处复制**。纯搬移重构,视觉/行为零变化。

/// Hero 区:大数字 + 周期标签。
struct RecapHeroSection: View {
    let summary: ReviewSummary

    var body: some View {
        VStack(spacing: WarmSpacing.xs) {
            Text(String(localized: "review.hero.count_\(summary.total)"))
                .font(WarmFont.serifDisplay(40))
                .foregroundColor(WarmTheme.primary)
                .accessibilityIdentifier("ReviewHeroCount")

            Text(summary.periodLabel)
                .font(WarmFont.caption(14))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // 「当天记、当天做完」件数(2026-08-21 用户拍板加上)。区间内没有
            // 完成时不显示——「其中 0 件」是噪音。一次性任务口径,与洞察 03 一致。
            // 整块收窄居中(2026-08-23 打磨):长句换行后不再撑满行宽,与上方
            // 居中的数字保持同一视觉节奏。
            if summary.total > 0 {
                Text(String(localized: "review.hero.sameday_\(summary.sameDayCount)"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(WarmTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WarmSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stats 行:streak 卡 + 本期完成卡。
/// 完成率已下岗(2026-08-23 拍板):比率与入口卡待处理数不同分母同屏会自相矛盾
/// (「100% + 5 件没做」),且违反洞察引擎反 gaming 章程,改显绝对数。
/// 副文案「未来 7 天还有 N 项」在 N>0 时才显示,避免空文案占位。
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

// MARK: - 月度摘要构建(共用聚合逻辑)

/// 把 @Query 原料聚合成近一个月的 `ReviewSummary`(ReviewView 与复盘第 1 步共用,
/// 避免 40 行聚合逻辑复制两份)。口径:
/// - 一次性完成 + 规律任务完成记录 union;
/// - 未来 7 天到期数作统计卡副文案(完成率已下岗,2026-08-23)。
enum RecapSummaryBuilder {
    /// - Parameters:
    ///   - today: 参照「今天」。
    ///   - calendar: 日历(日界走 `DayClock` 用户日)。
    ///   - allTodos: 全量待办 DTO(不过滤完成态——分母与分类表都要查父任务)。
    ///   - completedTodos: 已完成的一次性待办 DTO。
    ///   - recurringCompletions: 规律任务完成记录(todoId + completedAt)。
    static func monthSummary(
        today: Date = Date(),
        calendar: Calendar = Calendar.current,
        allTodos: [TodoItemData],
        completedTodos: [TodoItemData],
        recurringCompletions: [(id: UUID, todoId: UUID, completedAt: Date)]
    ) -> ReviewSummary {
        let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
        let start = calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
        let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let label = (calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today)
            .formatted(.dateTime.year().month(.abbreviated))
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
            sameDayCount: sameDayCount
        )
    }
}
