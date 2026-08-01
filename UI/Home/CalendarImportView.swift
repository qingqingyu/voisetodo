import SwiftUI

/// 从系统日历导入事件的视图(场景 3)。
///
/// 列出指定时间段内的系统日历事件,用户多选后转 TodoItemData(source = .calendarImport)
/// 入库。导入逻辑由 `AppCoordinator.importCalendarEvents` 处理,本视图只负责选择。
///
/// 权限降级:用户拒绝日历读取时显示「去设置」引导,不崩溃。
struct CalendarImportView: View {
    let calendarReader: any SystemCalendarReadingProtocol
    let onImport: ([ExternalCalendarEvent]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var events: [ExternalCalendarEvent] = []
    @State private var selectedIDs: Set<String> = []
    @State private var loadState: LoadState = .loading
    @State private var timeRange: TimeRange = .week

    enum LoadState {
        case loading
        case loaded
        case failed
        case denied
    }

    enum TimeRange: String, CaseIterable, Identifiable {
        case today
        case week
        case month

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .today: return String(localized: "calendar_import.range.today")
            case .week: return String(localized: "calendar_import.range.week")
            case .month: return String(localized: "calendar_import.range.month")
            }
        }

        /// 时间段终点(相对起始日的偏移)。
        /// today/week 用日单位;month 用 `Calendar.date(byAdding: .month...)` 精确加一月,
        /// 避免把「本月」固定当 30 天(2 月只显 28/29、其他月少 1 天)。
        /// `loadEvents` 里据此决定调用 dayOffset 还是 monthOffset。
        var dayOffset: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 0   // 0 表示走 monthOffset 路径
            }
        }

        var monthOffset: Int {
            switch self {
            case .month: return 1
            default: return 0
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "calendar_import.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "common.cancel")) { dismiss() }
                            .accessibilityIdentifier("CalendarImportCancelButton")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(
                            String(format: String(localized: "calendar_import.import_count"), selectedIDs.count)
                        ) {
                            confirmImport()
                        }
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("CalendarImportConfirmButton")
                    }
                }
        }
        .task(id: timeRange) { await loadEvents() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView(String(localized: "calendar_import.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            eventList
        case .failed:
            errorStateView(
                icon: "exclamationmark.triangle",
                message: String(localized: "calendar_import.load_failed")
            )
        case .denied:
            deniedView
        }
    }

    private var eventList: some View {
        List {
            Section {
                Picker(String(localized: "calendar_import.time_range"), selection: $timeRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.localizedTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("CalendarImportRangePicker")
            }

            if events.isEmpty {
                Section {
                    Text(String(localized: "calendar_import.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                } header: {
                    Text(String(format: String(localized: "calendar_import.event_count"), events.count))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func eventRow(_ event: ExternalCalendarEvent) -> some View {
        Button {
            toggleSelection(event.id)
        } label: {
            HStack(alignment: .top, spacing: WarmSpacing.sm) {
                VStack(alignment: .leading, spacing: WarmSpacing.xxs) {
                    Text(event.title)
                        .font(WarmFont.body(15))
                        .foregroundStyle(WarmTheme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)

                    Text(formattedDate(event))
                        .font(WarmFont.caption(12))
                        .foregroundStyle(WarmTheme.textSecondary)

                    if let cal = event.calendarTitle, !cal.isEmpty {
                        Text(cal)
                            .font(WarmFont.caption(11))
                            .foregroundStyle(WarmTheme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: selectedIDs.contains(event.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedIDs.contains(event.id) ? WarmTheme.primary : WarmTheme.textMuted)
                    .font(.system(size: 22))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("CalendarImportEventRow_\(event.id)")
    }

    private var deniedView: some View {
        errorStateView(
            icon: "calendar.badge.exclamationmark",
            message: String(localized: "calendar_import.denied_message"),
            actionTitle: String(localized: "toast.open_settings"),
            action: { PermissionManager.openAppSettings() }
        )
    }

    @ViewBuilder
    private func errorStateView(
        icon: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: WarmSpacing.md) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.orange)

            Text(message)
                .font(WarmFont.body(14))
                .foregroundStyle(WarmTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(WarmFont.headline(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, WarmSpacing.md)
                        .padding(.vertical, WarmSpacing.xs)
                        .background(Capsule().fill(WarmTheme.primary))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(WarmSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadEvents() async {
        loadState = .loading
        let now = Date()
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: now)
        let to: Date
        if timeRange.monthOffset > 0 {
            to = calendar.date(byAdding: .month, value: timeRange.monthOffset, to: from) ?? from.addingTimeInterval(TimeInterval(30 * 86_400))
        } else {
            to = calendar.date(byAdding: .day, value: timeRange.dayOffset, to: from) ?? from.addingTimeInterval(TimeInterval(timeRange.dayOffset * 86_400))
        }

        do {
            let result = try await calendarReader.fetchEvents(from: from, to: to)
            events = result
            selectedIDs = selectedIDs.filter { id in result.contains { $0.id == id } }
            loadState = .loaded
        } catch {
            // Reader 把权限拒绝包成 storageReadFailed(message = permissionDeniedMessage)。
            // 这里精确识别该 message,给用户「去设置」引导;其他错误走通用 failed。
            let isPermissionDenied: Bool
            if let voiceError = error as? VoiceTodoError,
               case .storageReadFailed(let message) = voiceError,
               message == SystemCalendarReadPermissionDeniedMessage {
                isPermissionDenied = true
            } else {
                isPermissionDenied = false
            }
            VoiceTodoLog.ui.warning("calendar_import.load_failed reason=\(String(describing: error), privacy: .public) isPermissionDenied=\(isPermissionDenied)")
            loadState = isPermissionDenied ? .denied : .failed
        }
    }

    private func toggleSelection(_ id: String) {
        // EKEvent.eventIdentifier 理论上必有值,但 `toExternal` 兜底成空串时,
        // 多条无 id 的事件会共用空串 key 导致选中错乱。空串 id 视为无效不响应。
        guard !id.isEmpty else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func confirmImport() {
        let selected = events.filter { selectedIDs.contains($0.id) }
        onImport(selected)
        dismiss()
    }

    // MARK: - Formatting

    private static let allDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func formattedDate(_ event: ExternalCalendarEvent) -> String {
        event.isAllDay
            ? Self.allDayFormatter.string(from: event.startDate)
            : Self.timedFormatter.string(from: event.startDate)
    }
}
