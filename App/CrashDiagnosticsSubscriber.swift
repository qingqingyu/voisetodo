import Foundation
import MetricKit

/// MetricKit 崩溃/卡顿诊断订阅器:把 Apple 每日聚合的 `MXDiagnosticPayload`
/// 摘要成一条 `mx_diagnostics` 遥测事件入队,复用 `TelemetryQueue` →
/// `TelemetryUploader` 批量链路上报(与「不做第三方 APM」的既有决策一致,
/// 见 ALERTING.md)。
///
/// 只报四类诊断的计数(崩溃/卡顿/磁盘写异常/CPU 异常),不上传堆栈符号——
/// 自建链路无符号化能力,完整 payload 体积大且含内存地址等字段;
/// 计数已足够回答「崩溃有没有、规模多大、哪个版本开始」,出现细化需求
/// (如按异常类型分桶)时再扩展参数。
///
/// 注意:
/// - MetricKit 仅真机产出数据(模拟器不回调),本埋点只能真机验证;
/// - `didReceive` 在后台队列回调;`TelemetryQueue` 内部有串行锁,
///   `Telemetry.record` 可从任意线程调用;
/// - 诊断 payload 在崩溃后的**下次启动**才交付,事件时间戳 ≠ 崩溃时刻,
///   分析时按天聚合而非按时间点对齐。
final class CrashDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsSubscriber()

    /// 注册诊断回调。幂等(MXMetricManager 对重复 add 去重),App 启动时调一次。
    func start() {
        MXMetricManager.shared.add(self)
    }

    /// 性能指标 payload(启动耗时/内存/电量等,每日交付)。当前不上报——
    /// 崩溃监控的最小可用只要诊断计数;协议要求实现此方法,留空即可
    /// (MetricKit 不因空实现出问题)。需要性能指标时在此扩展事件。
    func didReceive(_ payloads: [MXMetricPayload]) {
        // 有意留空,见类注释。
    }

    // 诊断 payload(崩溃/卡顿/磁盘写/CPU 异常),崩溃监控的核心回调。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashes = 0
        var hangs = 0
        var diskWrites = 0
        var cpuExceptions = 0
        for payload in payloads {
            crashes += payload.crashDiagnostics?.count ?? 0
            hangs += payload.hangDiagnostics?.count ?? 0
            diskWrites += payload.diskWriteExceptionDiagnostics?.count ?? 0
            cpuExceptions += payload.cpuExceptionDiagnostics?.count ?? 0
        }
        // 全 0 不入队:MetricKit 只在有诊断数据时才交付 diagnostic payload,
        // 这里防的是未来行为变化导致每日空事件刷量(与遥测「事件必须有分析价值」口径一致)。
        guard crashes + hangs + diskWrites + cpuExceptions > 0 else { return }
        VoiceTodoLog.app.warning("mx.diagnostics_received crashes=\(crashes) hangs=\(hangs) diskWrites=\(diskWrites) cpuExceptions=\(cpuExceptions)")
        Telemetry.record(.mxDiagnostics(
            crashes: crashes,
            hangs: hangs,
            diskWrites: diskWrites,
            cpuExceptions: cpuExceptions
        ))
    }
}
