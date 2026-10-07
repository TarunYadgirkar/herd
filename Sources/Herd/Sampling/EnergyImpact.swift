import Foundation

// The score top(1) prints as POWER and Activity Monitor shows as Energy Impact: CPU time plus 500 µs per package idle wakeup.
// pmenergy's QoS and disk weights are left out because top and Activity Monitor don't apply them.
enum EnergyImpact {
    private static let idleWakeupCostMicros = 500.0
    private static let nanosPerMicro = 1_000.0
    private static let microsPerSecond = 1_000_000.0
    private static let percent = 100.0

    static func score(cpuNanos: UInt64, idleWakeups: UInt64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let chargedMicros = Double(cpuNanos) / nanosPerMicro + Double(idleWakeups) * idleWakeupCostMicros
        return chargedMicros / (seconds * microsPerSecond) * percent
    }
}
