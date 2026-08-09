import SwiftUI
import PhotosUI
import UIKit

/// 用户反馈弹窗。两个入口复用同一个 view:
/// - Settings 入口(常态反馈):不预填,默认 type = suggestion
/// - ConfirmSheet 入口(撞烂 AI 输出当下反馈):预填 type = ai_output + 附 transcript/title
struct FeedbackSheet: View {
    private let prefillType: FeedbackType?
    private let transcript: String?
    private let extractedTodoTitle: String?

    @Environment(\.dismiss) private var dismiss
    @State private var type: FeedbackType
    @State private var description: String = ""
    @State private var screenshotItem: PhotosPickerItem?
    @State private var screenshotImage: UIImage?
    @State private var screenshotData: Data?
    @State private var isSubmitting = false
    @State private var didSubmit = false
    /// 提交失败的错误文案(触发"发送失败"alert)。仅 submit 路径写。
    @State private var errorMessage: String?
    /// 截图加载/压缩失败的错误文案(在选择器下方内联显示,不弹 alert)。
    /// 独立于 errorMessage —— 否则用户填到一半的描述被一个"发送失败"alert 打断,
    /// 但截图加载其实跟 submit 毫无关系。
    @State private var screenshotError: String?

    init(
        prefillType: FeedbackType? = nil,
        transcript: String? = nil,
        extractedTodoTitle: String? = nil
    ) {
        self.prefillType = prefillType
        self.transcript = transcript
        self.extractedTodoTitle = extractedTodoTitle
        // _type = State(initialValue:) 必须在所有 let 赋值之后,Swift 限制
        _type = State(initialValue: prefillType ?? .suggestion)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "feedback.type.label"), selection: $type) {
                        ForEach(FeedbackType.allCases, id: \.self) { t in
                            Text(t.displayText).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("FeedbackTypePicker")
                }

                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("FeedbackDescriptionEditor")
                        .overlay(alignment: .topLeading) {
                            if description.isEmpty {
                                Text(String(localized: "feedback.description.placeholder"))
                                    .foregroundStyle(.secondary)
                                    .font(.body)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text(String(localized: "feedback.description.title"))
                }

                Section {
                    PhotosPicker(
                        selection: $screenshotItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(String(localized: "feedback.screenshot.pick"), systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("FeedbackScreenshotPicker")

                    if let screenshotImage {
                        Image(uiImage: screenshotImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button(role: .destructive) {
                            screenshotItem = nil
                            screenshotImage = nil
                            screenshotData = nil
                        } label: {
                            Text(String(localized: "feedback.screenshot.remove"))
                        }
                        .accessibilityIdentifier("FeedbackScreenshotRemoveButton")
                    }

                    // 截图加载失败的内联提示(独立于提交 alert)。
                    // loadFailed 文案明确,不与"发送失败"标题混淆。
                    if let screenshotError {
                        Text(screenshotError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                } header: {
                    Text(String(localized: "feedback.screenshot.title"))
                } footer: {
                    Text(String(localized: "feedback.screenshot.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if transcript != nil || extractedTodoTitle != nil {
                    Section {
                        Text(String(localized: "feedback.context.include"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "feedback.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "feedback.cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("FeedbackCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(String(localized: "feedback.submit"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    .accessibilityIdentifier("FeedbackSubmitButton")
                }
            }
            .alert(
                String(localized: "feedback.error.title"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "feedback.error.ok")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: screenshotItem) { _, newItem in
                // 重选时清掉上一次的加载错误提示,避免旧错误残留。
                screenshotError = nil
                Task { await loadScreenshot(from: newItem) }
            }
            .onChange(of: didSubmit) { _, submitted in
                if submitted { dismiss() }
            }
        }
    }

    private func submit() {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // .disabled 在同一 runloop 内更新,但用户极快双击可能在 isSubmitting=true 生效前
        // 触发第二次 submit。这里显式守一道,避免双 Task 并发造成重复提交。
        guard !isSubmitting else { return }
        isSubmitting = true
        let payload = FeedbackPayload(
            type: type,
            description: trimmed,
            screenshot: screenshotData,
            screenshotMime: "image/jpeg",
            transcript: transcript,
            extractedTodoTitle: extractedTodoTitle
        )
        Task {
            do {
                try await FeedbackSubmitter().submit(payload)
                await MainActor.run {
                    isSubmitting = false
                    didSubmit = true
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? String(localized: "error.feedback_failed")
                }
            }
        }
    }

    @MainActor
    private func loadScreenshot(from item: PhotosPickerItem?) async {
        guard let item else {
            screenshotImage = nil
            screenshotData = nil
            return
        }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let jpeg = compressJpeg(image, maxBytes: FeedbackConfig.maxScreenshotBytes) {
                screenshotData = jpeg
                screenshotImage = UIImage(data: jpeg)
            }
            // compressJpeg 返 nil(异常图像格式编不出 JPEG)→ 跳过赋值,
            // screenshotImage 保持 nil,Picker 表现为未选图,用户可重选。
        } catch {
            // 选图失败不阻断主流程(用户可重选),但不能完全静默 ——
            // 否则 Picker 留空用户会一头雾水。记日志 + 截图区域下方内联显示一条
            // 错误提示(独立于提交错误,不弹"发送失败"alert 打断用户填描述)。
            VoiceTodoLog.feedback.error("feedback.screenshot_load_failed: \(VoiceTodoLog.errorSummary(error))")
            screenshotImage = nil
            screenshotData = nil
            screenshotError = String(localized: "feedback.screenshot.load_failed")
        }
    }

    /// 逐级降质 JPEG 直到 ≤ maxBytes。截图通常 < 500KB,极少需要降到 0.3 以下。
    /// 返回 nil 表示该图根本编不出 JPEG(异常图像格式),调用方应跳过截图上传。
    private func compressJpeg(_ image: UIImage, maxBytes: Int) -> Data? {
        var quality: CGFloat = 0.8
        // 首次编不出就直接返回 nil —— 不用空 Data 硬塞进 payload(会被 Worker 当有效
        // screenshotBase64 接收,Telegram 收到 0 字节 photo 会报错)。
        guard var data = image.jpegData(compressionQuality: quality) else { return nil }
        while data.count > maxBytes && quality > 0.1 {
            quality -= 0.1
            // 降质失败时保留上一档 data(必然更小),不用 ?? Data() 把结果清空
            if let next = image.jpegData(compressionQuality: quality) {
                data = next
            }
        }
        return data
    }
}

#Preview {
    FeedbackSheet()
}
