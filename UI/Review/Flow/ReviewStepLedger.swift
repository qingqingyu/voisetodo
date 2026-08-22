import SwiftUI

/// 第 5 步 · 收尾账本(阶段 3):N 条变 M 条 / 划掉 / 拆小 / 存规则 / 置顶 /
/// 下次复盘日期。数字全部从 `ReviewFlowState.ledger` 渲染;
/// 会话持久化(含下次复盘日期的落盘)在阶段 4。
struct ReviewStepLedger: View {
    let state: ReviewFlowState

    private let calendar = Calendar.current

    /// 下次复盘日期:复盘提醒现有节奏是每周一(App/ReviewNotificationScheduler),
    /// 账本对齐同一节奏——下一个周一。第 5 步渲染时点即会话收尾时点
    /// (阶段 4:`finishSession` 在「完成」点击时落库),与 scheduler 语义一致。
    private var nextReviewDate: Date {
        var components = DateComponents()
        components.weekday = 2 // 周一
        return calendar.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) ?? Date()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: WarmSpacing.lg) {
                summaryCard
                detailCard
                nextReviewCard
            }
            .padding(.horizontal, WarmSpacing.lg)
            .padding(.bottom, WarmSpacing.xxl)
        }
    }

    /// 「N 条变 M 条」:处理前 → 处理后仍在卡堆的。
    private var summaryCard: some View {
        let ledger = state.ledger
        return RecapCard {
            VStack(spacing: WarmSpacing.xs) {
                Text(String(localized: "review.flow.ledger.summary_\(ledger.inputCount)_\(ledger.remainingCount)"))
                    .font(WarmFont.headline(17))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "review.flow.ledger.summary_caption"))
                    .font(WarmFont.caption(12))
                    .foregroundColor(WarmTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var detailCard: some View {
        let ledger = state.ledger
        return RecapCard {
            VStack(spacing: WarmSpacing.sm) {
                ledgerRow(
                    icon: "calendar.badge.plus",
                    text: String(localized: "review.flow.ledger.scheduled_\(ledger.scheduledCount)")
                )
                ledgerRow(
                    icon: "sun.max",
                    text: String(localized: "review.flow.ledger.today_\(ledger.todayCount)")
                )
                ledgerRow(
                    icon: "xmark.circle",
                    text: String(localized: "review.flow.ledger.abandoned_\(ledger.abandonedCount)")
                )
                ledgerRow(
                    icon: "scissors",
                    text: String(localized: "review.flow.ledger.split_\(ledger.splitCount)")
                )
                ledgerRow(
                    icon: "pin",
                    text: String(localized: "review.flow.ledger.pinned_\(ledger.pinnedCount)")
                )
            }
        }
    }

    private var nextReviewCard: some View {
        RecapCard {
            HStack(spacing: WarmSpacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: 18))
                    .foregroundColor(WarmTheme.primary)

                Text(String(
                    localized: "review.flow.ledger.next_review_\(nextReviewDate.formatted(.dateTime.month().day().weekday(.abbreviated)))"
                ))
                    .font(WarmFont.body(14))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }
        }
    }

    private func ledgerRow(icon: String, text: String) -> some View {
        HStack(spacing: WarmSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(WarmTheme.textSecondary)
                .frame(width: 20, alignment: .center)

            Text(text)
                .font(WarmFont.body(14))
                .foregroundColor(WarmTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }
}
