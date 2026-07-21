import SwiftUI

/// Bucket 内任务的钟点选择 sheet。
///
/// `DayTimelineView` 的 bucket slot 末尾「+ 设钟点」按钮触发。
/// 顶部 `DatePicker(hourAndMinute)` 选时间,中部单选 slot 内未指定钟点的 todo,
/// Save 后通过 `onApply` 把 todo + 时间传回调用方。
///
/// **默认时间**:按 bucket 取代表点(morning=09:00 / afternoon=14:00 / evening=18:00)。
/// Anytime 不应弹此 sheet(调用方负责过滤)。
struct BucketHourSheet: View {
    let bucket: TimeBucket
    let candidates: [TodoItemData]
    let onApply: (UUID, Date) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: UUID?
    @State private var hourMinute: Date

    init(
        bucket: TimeBucket,
        candidates: [TodoItemData],
        onApply: @escaping (UUID, Date) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.bucket = bucket
        self.candidates = candidates
        self.onApply = onApply
        self.onDismiss = onDismiss
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = Self.representativeHour(for: bucket)
        components.minute = 0
        _hourMinute = State(initialValue: calendar.date(from: components) ?? Date())
        _selectedID = State(initialValue: candidates.first?.id)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: WarmSpacing.md) {
                DatePicker(
                    String(localized: "home.timeline.set_hour"),
                    selection: $hourMinute,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.compact)
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.top, WarmSpacing.sm)

                if candidates.isEmpty {
                    Text(String(localized: "home.timeline.no_candidates"))
                        .font(WarmFont.body(14))
                        .foregroundColor(WarmTheme.textSecondary)
                        .padding(.horizontal, WarmSpacing.lg)
                        .padding(.top, WarmSpacing.sm)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: WarmSpacing.xs) {
                            ForEach(candidates) { todo in
                                candidateRow(todo)
                            }
                        }
                        .padding(.horizontal, WarmSpacing.lg)
                        .padding(.top, WarmSpacing.xs)
                    }
                }

                Spacer()
            }
            .navigationTitle(bucket.localizedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.save")) {
                        guard let id = selectedID else { return }
                        onApply(id, hourMinute)
                    }
                    .disabled(selectedID == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func candidateRow(_ todo: TodoItemData) -> some View {
        let isSelected = selectedID == todo.id
        Button {
            selectedID = todo.id
        } label: {
            HStack(spacing: WarmSpacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(isSelected ? WarmTheme.primary : WarmTheme.textMuted)
                Text(todo.category.emoji)
                    .font(.system(size: 16))
                Text(todo.title)
                    .font(WarmFont.body(15))
                    .foregroundColor(WarmTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(WarmSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: WarmRadius.card)
                    .fill(isSelected ? WarmTheme.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Bucket 代表小时,用作 DatePicker 初始值。
    /// morning=09 / afternoon=14 / evening=18;anytime 调用方应过滤掉,不会进入此 sheet。
    private static func representativeHour(for bucket: TimeBucket) -> Int {
        switch bucket {
        case .morning: return 9
        case .afternoon: return 14
        case .evening: return 18
        case .anytime: return 9
        }
    }
}
