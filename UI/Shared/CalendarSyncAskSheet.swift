import SwiftUI

/// 首次确认带日期待办后弹出的一次性日历同步询问 sheet(2026-08-23 决策:
/// 删 onboarding 日历页,询问延后到用户刚看到「今晚八点」被识别出来的那一刻)。
///
/// 一次性语义:是否弹过由调用方(HomeView)的 `CalendarWriteMode.deferredAskShownKey`
/// 控制,弹过一次(含下滑关闭)不再弹;本视图不管触发条件,只负责呈现与选择。
///
/// 持久化不变量沿用原 onboarding 日历页:`.appAndSystemCalendar ⟹ 权限确实拿到过`
/// ——持久化只在 `requestCalendarPermission()` 返回 true(或已授权)后写入;
/// 被拒只回滚视觉,不写脏持久化。真正的开关始终在「设置 - 日历同步」。
struct CalendarSyncAskSheet: View {
    @ObservedObject var permissionManager: PermissionManager

    /// 与 HomeSettingsSheet / HomeView 共享同一 UserDefaults key 的写模式 binding。
    @Binding var calendarWriteModeRaw: String

    /// 视图内部决定关闭时机(开启成功 / 点「暂不」),调用方负责把 presentation 置 false。
    var onDismissRequest: () -> Void

    @State private var isRequesting = false
    @State private var isDenied = false

    private var inkColor: Color { WarmTheme.ink }
    private var highlightColor: Color { WarmTheme.primary }
    private var sketchColor: Color { WarmTheme.sketch }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 8)

            illustration

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.calendar.title"))
                    .font(WarmFont.title(24))
                    .foregroundColor(inkColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(String(localized: "onboarding.calendar.desc"))
                    .font(WarmFont.body(15))
                    .foregroundColor(sketchColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 隐私说明:与权限说明同款式(锁图标 + 胶囊底),用户点「开启」前就读得到
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundColor(sketchColor.opacity(0.6))
                Text(String(localized: "onboarding.calendar.privacy"))
                    .font(WarmFont.caption(13))
                    .foregroundColor(sketchColor.opacity(0.8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(sketchColor.opacity(0.06)))

            if isDenied {
                // 被拒:给出口去系统设置。开启按钮不再重复出现(再点也是被拒)。
                VStack(spacing: 12) {
                    Text(String(localized: "onboarding.calendar.denied"))
                        .font(WarmFont.caption(13))
                        .foregroundColor(sketchColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: { permissionManager.openAppSettings() }) {
                        Label {
                            Text(String(localized: "onboarding.open_settings"))
                                .font(WarmFont.body(14))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } icon: {
                            Image(systemName: "gear")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(inkColor))
                    }
                    .accessibilityIdentifier("CalendarAskOpenSettingsButton")
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            } else {
                Button(action: enableSync) {
                    HStack(spacing: 8) {
                        if isRequesting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text(String(localized: "calendar.ask.allow"))
                                .font(WarmFont.headline(17))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(highlightColor)
                            .shadow(color: highlightColor.opacity(0.3), radius: 8, y: 4)
                    )
                }
                .disabled(isRequesting)
                .accessibilityIdentifier("CalendarAskAllowButton")
            }

            Button(action: close) {
                Text(String(localized: "calendar.ask.not_now"))
                    .font(WarmFont.body(14))
                    .foregroundColor(sketchColor.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.vertical, 6)
            }
            .accessibilityIdentifier("CalendarAskNotNowButton")

            Spacer().frame(height: 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 20)
        .frame(maxWidth: 460)
        .background(WarmTheme.paperBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "onboarding.calendar.title"))
    }

    // MARK: - Actions

    /// 点「开启」。已授权(重装等场景)直接写持久化;否则先请求,拿到才写。
    private func enableSync() {
        // 已授权直接开,不多弹一次系统窗
        if permissionManager.calendarGranted {
            calendarWriteModeRaw = CalendarWriteMode.appAndSystemCalendar.rawValue
            close()
            return
        }
        isRequesting = true
        Task {
            let granted = await permissionManager.requestCalendarPermission()
            isRequesting = false
            if granted {
                calendarWriteModeRaw = CalendarWriteMode.appAndSystemCalendar.rawValue
                close()
            } else {
                // 只回滚视觉;calendarWriteModeRaw 全程没被写过,不存在写脏的窗口
                withAnimation(.spring(response: 0.3)) {
                    isDenied = true
                }
            }
        }
    }

    /// 暂不/关闭:保持 .appOnly,不写任何持久化。
    private func close() {
        onDismissRequest()
    }

    // MARK: - Subviews

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(highlightColor.opacity(0.1))
                .frame(width: 100, height: 100)

            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(inkColor)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(highlightColor)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("CalendarSyncAskSheet") {
    CalendarSyncAskSheet(
        permissionManager: PermissionManager(),
        calendarWriteModeRaw: .constant(CalendarWriteMode.appOnly.rawValue),
        onDismissRequest: {}
    )
}
