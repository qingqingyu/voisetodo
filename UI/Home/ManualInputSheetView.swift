import SwiftUI

/// 手动输入待办弹窗
struct ManualInputSheetView: View {
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool
    @State private var text = ""
    @State private var isSubmitting = false

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedText.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperTextureBackground()

                VStack(alignment: .leading, spacing: WarmSpacing.md) {
                    inputCard
                    hintRow
                    Spacer()
                }
                .padding(.horizontal, WarmSpacing.lg)
                .padding(.top, WarmSpacing.md)
            }
            .navigationTitle(String(localized: "manual_input.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "manual_input.cancel")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: WarmTheme.primary))
                        } else {
                            Text(String(localized: "manual_input.generate"))
                                .bold()
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("ManualInputGenerateButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
        .accessibilityIdentifier("ManualInputSheet")
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            isInputFocused = true
        }
    }

    private var inputCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(WarmFont.body(17))
                .foregroundColor(WarmTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isInputFocused)
                .padding(WarmSpacing.xs)
                .frame(minHeight: 180)
                .background(Color.clear)
                .disabled(isSubmitting)
                .accessibilityIdentifier("ManualInputTextEditor")

            if text.isEmpty {
                Text(String(localized: "manual_input.placeholder"))
                    .font(WarmFont.body(16))
                    .foregroundColor(WarmTheme.textMuted)
                    .padding(.horizontal, WarmSpacing.sm)
                    .padding(.vertical, WarmSpacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .fill(Color.white)
                .shadow(color: WarmTheme.shadowLight, radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarmRadius.section)
                .stroke(WarmTheme.primary.opacity(isInputFocused ? 0.35 : 0.12), lineWidth: 1.5)
        )
    }

    private var hintRow: some View {
        HStack(spacing: WarmSpacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WarmTheme.primary)

            Text(String(localized: "manual_input.hint"))
                .font(WarmFont.caption(13))
                .foregroundColor(WarmTheme.textSecondary)
        }
        .padding(.horizontal, WarmSpacing.sm)
        .padding(.vertical, WarmSpacing.xs)
        .background(
            Capsule()
                .fill(WarmTheme.secondaryBackground)
        )
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        isInputFocused = false
        onSubmit(trimmedText)
    }
}

#Preview {
    ManualInputSheetView { _ in }
}
