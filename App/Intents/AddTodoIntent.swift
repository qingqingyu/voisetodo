import AppIntents
import SwiftData
import WidgetKit

/// Siri App Intent：通过语音快速记录待办
/// 用户对 Siri 说"用 VoiceTodo 记录..."时触发
struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "siri.intent.title"
    static var description: IntentDescription = IntentDescription("siri.intent.description")

    @Parameter(title: "siri.param.transcript")
    var transcript: String

    static var parameterSummary: some ParameterSummary {
        Summary("siri.summary \(\.$transcript)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let intentID = VoiceTodoLog.makeID("add-intent")
        let startedAt = Date()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceTodoLog.intent.info("intent.add.start id=\(intentID, privacy: .public) \(VoiceTodoLog.textSummary(trimmed), privacy: .public)")
        guard !trimmed.isEmpty else {
            VoiceTodoLog.intent.info("intent.add.empty id=\(intentID, privacy: .public)")
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], fallbackError: nil)
            )
        }

        // 订阅凭证：Siri 走的是独立构造的 NetworkClient，默认 subscriptionJWSProvider
        // 是 { nil }，不注入的话 Pro 用户经 Siri 的每一句都会被代理按免费档计费。
        // 用 enableTransactionListener: false —— intent 是一次性调用，不需要常驻
        // Transaction.updates 监听。refreshEntitlements() 只遍历
        // Transaction.currentEntitlements，是本地 StoreKit 调用、无网络往返。
        let subscriptionJWS = await Self.currentSubscriptionJWS()

        // quotaProvider 有意留空：intent 进程里没有活着的 QuotaUsage 实例可更新，
        // 而 QuotaUsage 本身完全不持久化（冷启动即归零）、代理返回的 X-Quota-* 才是
        // 权威源，App 下一次请求就会拿到正确数值。不是遗漏。
        let extractor = TodoExtractorService(
            networkClient: NetworkClient(subscriptionJWSProvider: { subscriptionJWS })
        )
        var extractedTodos: [ExtractedTodo]
        var fallbackError: VoiceTodoError?
        let inputLocale = Locale.current

        do {
            let result = try await VoiceTodoLog.$requestPath.withValue("siri") {
                try await extractor.extract(from: trimmed, locale: inputLocale)
            }
            // 草稿出生点(Siri 直落库,无确认页):AI 未显式解析出提前量时回填全局默认,
            // snippet 视图展示的即是落库真值。
            let defaultOffset = ReminderOffsetConfig.effectiveDefaultOffset()
            extractedTodos = Self.todosWithInputLocale(result.todos, localeIdentifier: inputLocale.identifier)
                .map { $0.backfilledDefaultReminderOffset(defaultOffset) }
            VoiceTodoLog.intent.info("intent.add.extract_success id=\(intentID, privacy: .public) locale=\(inputLocale.identifier, privacy: .public) todoCount=\(extractedTodos.count)")
        } catch let error as VoiceTodoError {
            VoiceTodoLog.intent.error("intent.add.extract_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            switch error {
            // quotaExhausted 必须在这里兜底：以前它落到 default 直接返回失败，
            // transcript 被静默丢弃 —— 用户对 Siri 说的话直接消失，而 App 内同样
            // 情况会存下来（TranscriptProcessingFlow 的 quotaFallbackSaved）。
            case .networkUnavailable, .apiTimeout, .circuitOpen, .rateLimited,
                 .ipRateLimited, .serviceUnavailable, .quotaExhausted:
                let fallback = extractor.fallbackExtract(from: trimmed)
                extractedTodos = Self.todosWithInputLocale(fallback.todos, localeIdentifier: inputLocale.identifier)
                fallbackError = error
                VoiceTodoLog.intent.warning("intent.add.fallback id=\(intentID, privacy: .public) reason=\(String(describing: error), privacy: .public) todoCount=\(extractedTodos.count)")
            default:
                return .result(
                    dialog: "siri.result.extract_failed",
                    view: AddTodoIntentView(todos: [], fallbackError: nil)
                )
            }
        } catch {
            VoiceTodoLog.intent.error("intent.add.extract_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .result(
                dialog: "siri.result.extract_failed",
                view: AddTodoIntentView(todos: [], fallbackError: nil)
            )
        }

        guard !extractedTodos.isEmpty else {
            VoiceTodoLog.intent.info("intent.add.no_todos id=\(intentID, privacy: .public) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return .result(
                dialog: "siri.result.empty",
                view: AddTodoIntentView(todos: [], fallbackError: nil)
            )
        }

        let context: ModelContext
        do {
            let container = try AppGroupModelContainerProvider.writable()
            context = ModelContext(container)
        } catch {
            VoiceTodoLog.intent.error("intent.add.container_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "add", stage: "container"))
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError)
            )
        }

        let minSortOrder: Int
        do {
            minSortOrder = try fetchMinSortOrder(context: context)
        } catch {
            VoiceTodoLog.intent.error("intent.add.fetch_min_sort_order.blocked_save id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError)
            )
        }
        var baseSortOrder = minSortOrder - 1

        if fallbackError != nil {
            // 兜底路径（额度耗尽 / 网络 / 限流 / 服务不可用）：存原文而不是当成解析结果。
            // TodoItem.rawTranscript 会带上 needsAIProcessing = true +
            // extractionOutcome = .rawFallback，下次打开 App 由 PendingRecoveryFlow
            // 认领并**原地升级**成正式解析结果 —— 同一行，不产生重复、不需要去重。
            //
            // 以前这里走 TodoItem.from(...)，不带 needsAIProcessing，所以 Siri 的兜底
            // 待办永远停留在截断标题，永远不会被重解析（App 内同样情况走
            // TodoStore.addRawTranscript，会被重解析）。
            let item = TodoItem.rawTranscript(trimmed)
            item.localeIdentifier = inputLocale.identifier
            item.sortOrder = baseSortOrder
            context.insert(item)
        } else {
            for extracted in extractedTodos {
                let item = TodoItem.from(extracted, rawTranscript: trimmed)
                item.sortOrder = baseSortOrder
                baseSortOrder -= 1
                context.insert(item)
            }
        }

        do {
            try context.save()
            AppGroupConfig.markExternalDataChanged()
            WidgetCenter.shared.reloadAllTimelines()
            VoiceTodoLog.intent.info("intent.add.save_success id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            Telemetry.record(.todoSaved(source: .siriAdd, count: extractedTodos.count))
        } catch {
            VoiceTodoLog.intent.error("intent.add.save_failed id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "add", stage: "save"))
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError)
            )
        }

        let count = extractedTodos.count
        let dialog: IntentDialog
        if let fallbackError {
            switch fallbackError {
            case .networkUnavailable:
                dialog = "siri.result.offline"
            case .apiTimeout:
                dialog = "error.api_timeout"
            case .circuitOpen:
                dialog = "error.circuit_open"
            case .rateLimited:
                dialog = "error.rate_limited"
            case .ipRateLimited:
                dialog = "error.ip_rate_limited"
            case .serviceUnavailable:
                dialog = "error.service_busy"
            case .quotaExhausted:
                // 「今日免费额度已用完，已离线保存」——文案已存在，与 App 内同源
                dialog = "error.quota_exhausted"
            default:
                dialog = "siri.result.extract_failed"
            }
        } else {
            dialog = "siri.result.added \(count)"
        }

        return .result(
            dialog: dialog,
            view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError)
        )
    }

    private func fetchMinSortOrder(context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<TodoItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        descriptor.fetchLimit = 1
        do {
            let items = try context.fetch(descriptor)
            VoiceTodoLog.intent.debug("intent.add.fetch_min_sort_order.success value=\(items.first?.sortOrder ?? 0)")
            return items.first?.sortOrder ?? 0
        } catch {
            VoiceTodoLog.intent.error("intent.add.fetch_min_sort_order.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            if let voiceError = error as? VoiceTodoError {
                throw voiceError
            }
            throw VoiceTodoError.storageReadFailed(error.localizedDescription)
        }
    }

    /// 读取当前生效订阅的 JWS，供代理判定 Pro 档。
    ///
    /// 失败（无订阅 / StoreKit 异常）返回 nil —— 代理侧对缺失 JWS 是 fail-safe 到免费档，
    /// 所以这里不需要也不应该抛错阻断记录待办。
    @MainActor
    private static func currentSubscriptionJWS() async -> String? {
        let entitlements = EntitlementManager(enableTransactionListener: false)
        await entitlements.refreshEntitlements()
        return entitlements.jwsString
    }

    private static func todosWithInputLocale(_ todos: [ExtractedTodo], localeIdentifier: String) -> [ExtractedTodo] {
        todos.map { todo in
            var localized = todo
            localized.localeIdentifier = localeIdentifier
            return localized
        }
    }
}
