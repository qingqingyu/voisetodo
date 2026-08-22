import XCTest
import Foundation
#if canImport(StoreKitTest)
import StoreKitTest
#endif
import StoreKit

/// `VoiceTodo/Products.storekit`(本地 StoreKit 调试配置)的守卫测试。
///
/// 背景:2026-08 曾因手改该文件把免费试用的 `paymentMode` 从合法的 `"free"` 改成
/// `"freeTrial"`(StoreKit API 枚举 rawValue,但 v5 JSON schema 不认识),iOS runtime
/// 的 ASOctaneSupport 解码**整个文件**失败 —— 且是静默失败:Xcode 编辑器照常打开、
/// `Product.products(for:)` 不抛错只返回空数组,paywall 报「Couldn't load
/// subscription plans」而无从归因。这组测试把这类配置损坏变成显性红灯。
///
/// 注意:`.storekit` 是 Apple 未公开文档的格式,唯一可靠的正确性来源是 Xcode 的
/// StoreKit 编辑器(写入器与 runtime 解码器配套)。本文件只做守卫,不要为了
/// 「修测试」手改 Products.storekit 的 schema 字段。
final class ProductsStorekitGuardTests: XCTestCase {

    /// 必须与 `App/EntitlementManager.swift` 的 `productIDs` 逐字一致。
    /// EntitlementManager 不在 SPM 目标内无法直接引用,只能在此重复字面量;
    /// 两处任一改动都要同步(改 productID 属高危操作,见 APPSTORE_REVIEW_KIT.md §3.1)。
    private static let expectedProductIDs: Set<String> = [
        "com.qingqingyu.voicetodo.pro.monthly",
        "com.qingqingyu.voicetodo.pro.yearly",
    ]

    /// v5 schema 的 `paymentMode` 合法拼写。注意 **免费试用写 `"free"`**,
    /// 不是 API 枚举 rawValue `"freeTrial"`(payAsYouGo / payUpFront 保持 rawValue
    /// 拼写,唯独 freeTrial 例外 —— 2026-08-22 实测,详见
    /// docs/onboarding-paywall-products-empty.md §3.1 修正说明)。
    private static let validPaymentModes: Set<String> = ["free", "payAsYouGo", "payUpFront"]

    /// 测试文件位于 `<repo>/VoiceTodoTests/Protocols/`,配置位于 `<repo>/VoiceTodo/`。
    private static var storekitFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → Protocols/
            .deletingLastPathComponent()  // → VoiceTodoTests/
            .deletingLastPathComponent()  // → repo 根
            .appendingPathComponent("VoiceTodo/Products.storekit")
    }

    private func loadStorekitJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.storekitFileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw NSError(domain: "ProductsStorekitGuard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Products.storekit 根节点必须是 JSON 对象"])
        }
        return root
    }

    private func subscriptions(in root: [String: Any]) throws -> [[String: Any]] {
        guard let version = root["version"] as? [String: Any],
              let major = version["major"] as? Int, major == 5 else {
            throw NSError(domain: "ProductsStorekitGuard", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "version 必须为 {major: 5, …};major 变更意味着 schema 换代,本守卫的断言需要重新核对"])
        }
        guard let groups = root["subscriptionGroups"] as? [[String: Any]] else {
            throw NSError(domain: "ProductsStorekitGuard", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "缺少 subscriptionGroups 数组"])
        }
        return groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
    }

    // MARK: - 结构守卫(纯 JSON,任何环境可跑)

    /// 商品 ID 与 EntitlementManager.productIDs 逐字一致,且恰好 2 个订阅。
    func testProductIDsMatchEntitlementManager() throws {
        let subscriptions = try subscriptions(in: try loadStorekitJSON())
        XCTAssertEqual(subscriptions.count, 2, "应恰好有月付/年付两个订阅商品")
        let ids = Set(subscriptions.compactMap { $0["productID"] as? String })
        XCTAssertEqual(ids, Self.expectedProductIDs,
                       "商品 ID 必须与 App/EntitlementManager.swift 的 productIDs 逐字一致,否则 Product.products(for:) 返回空数组")
    }

    /// 所有试用(introductoryOffer 单数 + introductoryOffers 复数)的 paymentMode
    /// 必须是 v5 合法拼写。这一条锁死 2026-08 事故的直接教训:"freeTrial" 会让
    /// runtime 拒绝解码整个文件。
    func testIntroOfferPaymentModesUseV5Spelling() throws {
        let subscriptions = try subscriptions(in: try loadStorekitJSON())
        var checked = 0
        for subscription in subscriptions {
            var offers: [[String: Any]] = []
            if let singular = subscription["introductoryOffer"] as? [String: Any] {
                offers.append(singular)
            }
            if let plural = subscription["introductoryOffers"] as? [[String: Any]] {
                offers.append(contentsOf: plural)
            }
            for offer in offers {
                guard let mode = offer["paymentMode"] as? String else {
                    XCTFail("试用块缺少 paymentMode: \(subscription["productID"] ?? "?")")
                    continue
                }
                XCTAssertTrue(Self.validPaymentModes.contains(mode),
                              "\(subscription["productID"] ?? "?") 的 paymentMode「\(mode)」不是 v5 合法拼写(合法: \(Self.validPaymentModes.sorted()));免费试用应写 \"free\" 而非 \"freeTrial\"")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "月付/年付应各配置试用(introductoryOffer/introductoryOffers)")
    }

    // MARK: - 加载守卫(StoreKitTest;仅 iOS —— xcodebuild/模拟器路径)

    /// 通过 StoreKitTest 加载配置并真实拉取商品,兜住结构守卫没预设到的
    /// 粗粒度损坏(结构塌坏、商品解析不出等)。
    ///
    /// **能力边界(2026-08-22 实测)**:SKTestSession 用的是 Xcode 侧的宽松解码器,
    /// 与 Xcode 编辑器同源 —— 即便 paymentMode 写了非法的 "freeTrial",这条测试
    /// 依然通过(注入坏值实测过)。真正拒绝坏文件的是 **App 运行时**的解码器
    /// (模拟器 ASOctaneSupport,经 storekitd 服务 App 进程),它没有任何自动化
    /// 测试可覆盖。所以:拼写类错误靠上面的结构守卫,别指望这一条。
    ///
    /// 仅在 iOS(模拟器)下编译:macOS CLI(`swift test`)里 SKTestSession 挂载不了
    /// 本地测试商店(`SKInternalErrorDomain Code=3` → 恒返回 0 商品,属环境限制
    /// 而非文件问题),在那条路径跑只会产生永久红灯。
    #if canImport(StoreKitTest) && os(iOS)
    func testStorekitConfigurationActuallyLoadsProducts() async throws {
        let session = try SKTestSession(contentsOf: Self.storekitFileURL)
        _ = session  // 仅持有会话使本进程 StoreKit 走本地测试商店
        let products = try await Product.products(for: Self.expectedProductIDs)
        XCTAssertEqual(products.count, 2,
                       "本地测试商店应返回 2 个商品;返回 0 且无异常,大概率是 .storekit 文件被 runtime 解码器静默拒绝")
        for product in products {
            XCTAssertNotNil(product.subscription,
                            "\(product.id) 应解析为订阅类型(type: RecurringSubscription)")
        }
    }
    #endif
}
