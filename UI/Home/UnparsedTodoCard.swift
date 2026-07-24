import SwiftUI

/// 「没能识别」分组的卡片:outcome != .parsed 的原文兜底条目。
///
/// 视觉对齐 HTML 设计稿 line 198-211, 449-458:
/// - 45° 斜纹背景(Canvas 画 repeating-linear-gradient 等效图案,不用图片资源)
/// - dashed border(`StrokeStyle(lineWidth: 1, dash: [4, 3])`)
/// - 顶部小标签「原文片段」(11.5pt + 750 字重 + uppercase)
/// - 原文文本(lineLimit 3,容纳 AX5 + 中英文长原文,与「文本截断零容忍」一致)
/// - 底部两个按钮:「重新解析」(borderedProminent)+「删除」(bordered,destructive)
///
/// **不做「手动编辑」** —— 用户决策锁定(Commit 7 of plan)。
/// 失败原文的修复路径只有"再喂 AI 重解析"或"删除",不引导手动改字段。
struct UnparsedTodoCard: View {
    let todo: TodoItemData
    let index: Int
    let onReextract: () -> Void
    let onDelete: () -> Void

    /// 正在重新解析时降级按钮可点性 + 显示 ProgressView。
    /// 调用方(HomeSelectedDayListView)从 `AppCoordinator.reextractingTodoIDs` 派生注入。
    var isReextracting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
            Text(String(localized: "home.unparsed.tag"))
                .font(WarmFont.caption(11.5))
                .tracking(0.5)
                .foregroundColor(WarmTheme.textMuted)
                .textCase(.uppercase)
                .accessibilityIdentifier("UnparsedTag_\(index)")

            Text(todo.rawTranscript ?? todo.title)
                .font(WarmFont.body(14.5))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("UnparsedBody_\(index)")

            HStack(spacing: WarmSpacing.xs) {
                Button(action: onReextract) {
                    HStack(spacing: WarmSpacing.xxs) {
                        if isReextracting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(String(localized: "home.unparsed.reextract"))
                            .font(WarmFont.caption(13))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, WarmSpacing.sm)
                    .padding(.vertical, WarmSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: WarmRadius.chip)
                            .fill(WarmTheme.primary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isReextracting)
                .accessibilityIdentifier("UnparsedReextract_\(index)")

                Button(role: .destructive, action: onDelete) {
                    Text(String(localized: "home.delete"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(WarmTheme.textSecondary)
                        .padding(.horizontal, WarmSpacing.sm)
                        .padding(.vertical, WarmSpacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: WarmRadius.chip)
                                .fill(WarmTheme.sketch.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("UnparsedDelete_\(index)")
            }
            .padding(.top, WarmSpacing.xxs)
        }
        .padding(WarmSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnparsedStripesBackground()
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarmRadius.chip)
                .stroke(
                    WarmTheme.sketch,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: WarmSpacing.xxs,
                                  leading: WarmSpacing.lg,
                                  bottom: WarmSpacing.xxs,
                                  trailing: WarmSpacing.lg))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("UnparsedCard_\(todo.id)")
    }
}

/// 45° 斜纹背景(Canvas 等效 HTML `repeating-linear-gradient(-45deg, #FBFAF8, #FBFAF8 9px, #F5F3EF 9px, #F5F3EF 18px)`)。
/// 不用图片资源:Canvas 在 AX 档位不缩放,斜纹密度恒定,视觉一致。
struct UnparsedStripesBackground: View {
    var body: some View {
        Canvas { context, size in
            let stripeWidth: CGFloat = 18
            let stripeColor = Color(light: "FBFAF8", dark: "1A1C1F")
            let bandColor = Color(light: "F5F3EF", dark: "15171A")
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(stripeColor))

            // 沿 -45° 方向画带状区域。每条带宽度 stripeWidth,相邻带间距 stripeWidth。
            // 简化:画一系列平行四边形。
            let diagonal = (size.width + size.height) * 2
            var offset: CGFloat = -size.height
            while offset < diagonal {
                let path = Path { p in
                    p.move(to: CGPoint(x: offset, y: 0))
                    p.addLine(to: CGPoint(x: offset + stripeWidth / 2, y: 0))
                    p.addLine(to: CGPoint(x: offset + stripeWidth / 2 + size.height, y: size.height))
                    p.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                    p.closeSubpath()
                }
                context.fill(path, with: .color(bandColor.opacity(0.6)))
                offset += stripeWidth * 2
            }
        }
    }
}
