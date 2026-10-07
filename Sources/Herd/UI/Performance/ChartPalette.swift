import SwiftUI

enum ChartPalette {
    static let primary = Theme.accent
    static let secondary = Theme.netOut
    static let tertiary = Theme.warm
    static let quaternary = Theme.neutral
    static let total = Color.secondary
    static let rule = Color.secondary.opacity(0.6)
    static let grid = Color.secondary.opacity(0.18)
    static let track = Color.secondary.opacity(0.12)

    static let cpuUser = primary
    static let cpuSystem = secondary

    static let appMemory = primary
    static let wiredMemory = secondary
    static let compressedMemory = tertiary
    static let cachedFiles = quaternary
    static let swap = secondary

    static let download = Theme.netIn
    static let upload = Theme.netOut

    static let cpuPower = primary
    static let gpuPower = secondary
    static let anePower = tertiary
    static let dramPower = quaternary

    static let cpuTemperature = tertiary
    static let gpuTemperature = secondary
    static let lidTemperature = Theme.hot
    static let fan = quaternary

    static let charge = primary
    static let charging = Theme.good
    static let draining = Theme.warning

    static let stackedOpacity = 0.72
    static let bandOpacity = 0.32
    static let gradientTopOpacity = 0.32
}
