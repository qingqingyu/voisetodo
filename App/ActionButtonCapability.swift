import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Action Button 机型能力检测。
///
/// Action Button 仅在以下机型可用:
/// - iPhone 15 Pro / iPhone 15 Pro Max(硬件标识 iPhone16,1 / iPhone16,2)
/// - iPhone 16 全系及后续(硬件标识 iPhone17,*)
///
/// 其它机型(iPhone 14 / 15 / 15 Plus、iPad 等)没有 Action Button,
/// Onboarding 和后续提示需要据此跳过相关引导,避免用户去设置里找不存在的选项。
enum ActionButtonCapability {
    /// 当前设备是否支持 Action Button。
    /// 硬件标识在运行期不变,故用 lazy static 只算一次,避免 Onboarding 每次 body
    /// 求值都重复跑 sysctl + 字符串解析。
    static var isSupported: Bool { _isSupported }

    private static let _isSupported: Bool = {
        var systemInfo = utsname()
        let result = Darwin.sysctlbyname("hw.machine", &systemInfo, nil, nil, 0)
        guard result == 0 else {
            VoiceTodoLog.app.warning("action_button.capability.sysctl_failed result=\(result)")
            return false
        }

        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
        }

        guard machine.hasPrefix("iPhone") else { return false }

        let versionPart = machine.dropFirst("iPhone".count)
        let parts = versionPart.split(separator: ",")
        guard let majorPart = parts.first,
              let minorPart = parts.last,
              let major = Int(majorPart),
              let minor = Int(minorPart) else {
            VoiceTodoLog.app.warning("action_button.capability.unparsed_machine machine=\(machine, privacy: .public)")
            return false
        }

        // iPhone 16 全系及后续新机(iPhone17,*)默认支持
        if major >= 17 { return true }
        // iPhone 15 Pro / Pro Max(iPhone16,1 / iPhone16,2)
        if major == 16 && minor <= 2 { return true }
        return false
    }()
}
