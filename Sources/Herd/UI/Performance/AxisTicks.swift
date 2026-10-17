import Foundation

enum AxisTicks {
    private static let decimalSteps: [Double] = [1, 2, 2.5, 5, 10]
    private static let binarySteps: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1024]
    private static let desiredCount = 4.0

    static func values(lower: Double, upper: Double, isBinary: Bool) -> [Double] {
        guard lower.isFinite, upper.isFinite else { return [0, 1] }
        let top = upper > lower ? upper : lower + (isBinary ? 1024 : 1)
        let step = isBinary ? binaryStep(for: (top - lower) / desiredCount) : decimalStep(for: (top - lower) / desiredCount)
        guard step.isFinite, step > 0 else { return [lower, top] }
        let start = (lower / step).rounded(.down) * step
        let end = (top / step).rounded(.up) * step
        return Array(stride(from: start, through: end + step * 0.01, by: step))
    }

    private static func decimalStep(for rough: Double) -> Double {
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let normalized = rough / magnitude
        return (decimalSteps.first { $0 >= normalized } ?? 10) * magnitude
    }

    private static func binaryStep(for rough: Double) -> Double {
        let clamped = max(rough, 1)
        let magnitude = pow(1024, (log(clamped) / log(1024)).rounded(.down))
        let normalized = clamped / magnitude
        return (binarySteps.first { $0 >= normalized } ?? 1024) * magnitude
    }
}
