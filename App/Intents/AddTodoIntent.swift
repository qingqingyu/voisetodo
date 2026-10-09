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
        let inputLocale = Locale.current

        // 5.1.1 AI 同意 gate:转写文本将经我们的服务器发往第三方 AI 服务商,
        // 未同意前 intent 进程不发请求(扩展进程无 UI 可弹披露卡)。话不丢:
        // 原文按 pending 草稿落库(needsAIProcessing = true),用户打开 App
        // 完成披露同意后,前台恢复流程(PendingRecoveryFlow)原地解析成待办
        // ——与离线/额度耗尽兜底同一条「原文先存、后续升级」链路。
        guard AppGroupConfig.aiConsentGranted() else {
            VoiceTodoLog.intent.info("intent.add.ai_consent_missing id=\(intentID, privacy: .public)")
            do {
                let container = try AppGroupModelContainerProvider.writable()
                let context = ModelContext(container)
                let item = TodoItem.rawTranscript(trimmed)
                item.localeIdentifier = inputLocale.identifier
                item.sortOrder = try fetchMinSortOrder(context: context) - 1
                context.insert(item)
                try context.save()
                AppGroupConfig.markExternalDataChanged()
                WidgetCenter.shared.reloadAllTimelines()
                // 与主存库路径同口径:consent gate 的原文保存也计入 siri 保存遥测
                // (原文未解析,不是 todoSaved 的 parsed 语义,但「siri 说的话落了库」
                // 这一事件与 fallbackError 路径一致,漏记会让 siriAdd 来源少算)。
                Telemetry.record(.todoSaved(source: .siriAdd, count: 1))
            } catch {
                VoiceTodoLog.intent.error("intent.add.ai_consent_save_failed id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                Telemetry.record(.intentFailed(operation: "add", stage: "container"))
                return .result(
                    dialog: "siri.result.save_failed",
                    view: AddTodoIntentView(todos: [], fallbackError: nil)
                )
            }
            return .result(
                dialog: "siri.result.consent_required",
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

        // snippet 卡片文案与口播同口径:被拒订阅时卡片也要显示「订阅验证未通过」,
        // 否则 Siri 说「请恢复购买」、卡片却写「今日免费额度已用完」。
        let carriedSubscriptionJWS = !(subscriptionJWS?.isEmpty ?? true)
        let fallbackMessage = Self.fallbackSnippetMessage(for: fallbackError, carriedSubscriptionJWS: carriedSubscriptionJWS)

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
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError, fallbackMessage: fallbackMessage)
            )
        }

        let minSortOrder: Int
        do {
            minSortOrder = try fetchMinSortOrder(context: context)
        } catch {
            VoiceTodoLog.intent.error("intent.add.fetch_min_sort_order.blocked_save id=\(intentID, privacy: .public) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError, fallbackMessage: fallbackMessage)
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
            // 落库后就地排提醒:intent 写库走自己的 ModelContext,活着的 TodoStore 的
            // $todos 不发布 → 主 App 的 TodoNotificationSync 感知不到。用户对 Siri 说
            // "明天 9 点提醒我 X",不开 App 的话提醒永远不会排——这里按最新落库状态
            // 逐条对账(与 CompleteTodoIntent 同模式)。权限 notDetermined 时只删不加,
            // 不在 Siri 上下文弹权限窗;App 首次前台对账时再懒申请。
            if fallbackError == nil {
                for todo in extractedTodos {
                    await IntentNotificationReconciler.reconcile(
                        todoID: todo.id,
                        context: context,
                        enabled: AppGroupConfig.notificationsEnabledInStandard(),
                        port: UNNotificationPort()
                    )
                }
            }
        } catch {
            VoiceTodoLog.intent.error("intent.add.save_failed id=\(intentID, privacy: .public) todoCount=\(extractedTodos.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            Telemetry.record(.intentFailed(operation: "add", stage: "save"))
            return .result(
                dialog: "siri.result.save_failed",
                view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError, fallbackMessage: fallbackMessage)
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
            case .quotaExhausted(let tier, _):
                // 与 App 内 AppCoordinator.proQuotaBlockedToastMessage 同口径的分流：
                // 被拒订阅用户听到「订阅验证未通过/恢复购买」而非「免费额度用完」，
                // Pro 用户不听到「免费」字样。intent 进程没有 QuotaUsage 实例可读
                // 拒绝标志，改用错误自带的 tier（代理计费口径）+ 本次是否携带凭证判定。
                switch Self.quotaExhaustedDialog(tier: tier, carriedSubscriptionJWS: carriedSubscriptionJWS) {
                case .subscriptionRejected:
                    dialog = "error.subscription_rejected"
                case .proExhausted:
                    dialog = "error.quota_exhausted_pro"
                case .freeExhausted:
                    dialog = "error.quota_exhausted"
                }
            default:
                dialog = "siri.result.extract_failed"
            }
        } else {
            dialog = "siri.result.added \(count)"
        }

        return .result(
            dialog: dialog,
            view: AddTodoIntentView(todos: extractedTodos, fallbackError: fallbackError, fallbackMessage: fallbackMessage)
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

    /// quotaExhausted 时 Siri 口播文案的三分流（App 内对应
    /// `AppCoordinator.proQuotaBlockedToastMessage`）。intent 进程没有 `QuotaUsage`
    /// 实例可读拒绝标志，改用错误自带的 tier（代理计费口径，worker.js
    /// quota_exceeded 的 429 body）+ 本次请求是否实际携带凭证判定。
    enum QuotaExhaustedDialog: Equatable {
        /// 带了凭证仍按 free 计 = 订阅被代理拒（验签失败/宽限期/退款）→ 提示恢复购买。
        case subscriptionRejected
        /// 按 pro 计的用户撞 Pro 上限（不含「免费」字样）。
        case proExhausted
        /// 真免费用户。
        case freeExhausted
    }

    /// 按代理计费口径（tier）+ 本次是否携带凭证分流 quotaExhausted 的 Siri 口播文案。
    ///
    /// 判定与 `QuotaUsage.applyQuotaHeaders` 的 `proxyRejectedSubscription` 同口径
    /// （带了凭证 + 代理明确按 free 计 = 被拒）。已知限制：tier 在 `NetworkClient`
    /// 构造错误时已兜底成 `"free"`，代理**未表态**档位（现网 worker 两条
    /// quota_exceeded 路径 body 恒带 tier，仅代理回归时可能出现）会被折叠成
    /// free 口径——与 App 侧「未表态不臆断」原则的偏差以文案口径为限。
    static func quotaExhaustedDialog(tier: String, carriedSubscriptionJWS: Bool) -> QuotaExhaustedDialog {
        if carriedSubscriptionJWS, tier == "free" { return .subscriptionRejected }
        return tier == "pro" ? .proExhausted : .freeExhausted
    }

    /// snippet 卡片的兜底文案覆盖。只有「订阅被代理拒」需要覆盖:`VoiceTodoError.errorDescription`
    /// 对 tier=="free" 恒为免费口径(它不知道请求是否带了凭证);其余情况返回 nil 沿用 errorDescription。
    static func fallbackSnippetMessage(for error: VoiceTodoError?, carriedSubscriptionJWS: Bool) -> String? {
        guard case .quotaExhausted(let tier, _) = error,
              quotaExhaustedDialog(tier: tier, carriedSubscriptionJWS: carriedSubscriptionJWS) == .subscriptionRejected
        else { return nil }
        return ErrorMessages.subscriptionRejected
    }

    private static func todosWithInputLocale(_ todos: [ExtractedTodo], localeIdentifier: String) -> [ExtractedTodo] {
        todos.map { todo in
            var localized = todo
            localized.localeIdentifier = localeIdentifier
            return localized
        }
    }
}
