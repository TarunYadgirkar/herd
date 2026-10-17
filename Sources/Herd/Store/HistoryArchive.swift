import Foundation
import Observation
import os

@MainActor
@Observable
final class HistoryArchive {
    private static let rawRetention: TimeInterval = 600
    private static let minuteResolution: TimeInterval = 10
    private static let minuteRetention: TimeInterval = 3_600
    private static let hourResolution: TimeInterval = 120
    private static let hourRetention: TimeInterval = 86_400
    private static let minimumChartPoints = 120
    private static let maximumChartPoints = 720
    private static let ledgerCapacity = 500
    private static let ledgerTrimSlack = 100
    private static let fileName = "history.json"
    nonisolated private static let log = Logger(subsystem: "Herd", category: "HistoryArchive")
    nonisolated private static let writer = DispatchQueue(label: "Herd.HistoryArchive.writer", qos: .utility)

    private(set) var revision = 0

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var raw = HistoryTier(resolution: 0, retention: rawRetention)
    @ObservationIgnored private var minute = HistoryTier(resolution: minuteResolution, retention: minuteRetention)
    @ObservationIgnored private var hour = HistoryTier(resolution: hourResolution, retention: hourRetention)
    @ObservationIgnored private var cores = DatedRing<CorePoint>()
    @ObservationIgnored private var ledger: [String: AppUsage] = [:]
    @ObservationIgnored private var ledgerDay = LedgerDay(containing: Date())
    @ObservationIgnored private var savedRevision = 0
    @ObservationIgnored private var usageCache: (revision: Int, usage: [AppUsage])?

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Herd", directoryHint: .isDirectory)
        restore(now: Date())
    }

    private var fileURL: URL { directory.appending(path: Self.fileName, directoryHint: .notDirectory) }

    // `elapsed` is the awake time the frame's counters actually cover; `rateWindow` caps it for network,
    // whose rates come from a short window and would overcount if stretched across a gap.
    func record(_ system: SystemSnapshot, groups: [AppGroup], elapsed: TimeInterval, rateWindow: TimeInterval, at date: Date) {
        if let latest = latestRecordedDate, date < latest { rewind(to: date) }
        var point = SystemPoint(system, at: date)
        point.contributors = groups.isEmpty ? nil : Contributor.leaders(groups.map(Contributor.init))
        raw.add(point)
        minute.add(point)
        hour.add(point)
        cores.append(CorePoint(system, at: date))
        cores.drop(before: date.addingTimeInterval(-Self.rawRetention))
        recordUsage(groups, span: UsageSpan(elapsed: elapsed, rateWindow: rateWindow), at: date)
        revision += 1
    }

    func recordUsage(groups: [AppGroup], elapsed: TimeInterval, rateWindow: TimeInterval, at date: Date) {
        recordUsage(groups, span: UsageSpan(elapsed: elapsed, rateWindow: rateWindow), at: date)
        revision += 1
    }

    func points(in range: HistoryRange) -> [SystemPoint] {
        window(in: range).points
    }

    func window(in range: HistoryRange) -> HistoryWindow {
        _ = revision
        let cutoff = latestDate.addingTimeInterval(-range.seconds)
        let tier = bestTier(since: cutoff)
        let source = tier.points(since: cutoff)
        let stretch = max(1, Double(source.count) / Double(Self.maximumChartPoints))
        let spacing = tier.resolution > 0 ? tier.resolution : HistoryGaps.medianSpacing(source.map(\.date)) ?? Self.minuteResolution
        return HistoryWindow(
            points: Self.downsample(source, to: Self.maximumChartPoints),
            maxGap: HistoryGaps.limit(spacing: spacing, stretch: stretch)
        )
    }

    func corePoints(in range: HistoryRange) -> [CorePoint] {
        _ = revision
        return Array(cores.slice(since: latestDate.addingTimeInterval(-range.seconds)))
    }

    var appUsageToday: [AppUsage] {
        let current = revision
        if let usageCache, usageCache.revision == current { return usageCache.usage }
        let usage = ledger.values.sorted { $0.energyWattHours > $1.energyWattHours }
        usageCache = (current, usage)
        return usage
    }

    func save(waitUntilWritten: Bool = false) {
        guard revision != savedRevision else { return }
        guard let data = encodedFile() else { return }
        savedRevision = revision
        let directory = directory
        let url = fileURL
        let work: @Sendable () -> Void = { Self.write(data, to: url, in: directory) }
        if waitUntilWritten { Self.writer.sync(execute: work) } else { Self.writer.async(execute: work) }
    }

    private var latestRecordedDate: Date? { [raw, minute, hour].compactMap(\.latestDate).max() }
    private var latestDate: Date { latestRecordedDate ?? Date() }

    // Coarse tiers are cheaper to draw, but a tier only qualifies once it reaches back as far as the data does and has enough points for a smooth line.
    private func bestTier(since cutoff: Date) -> HistoryTier {
        let coarseToFine = [hour, minute, raw]
        guard let earliest = coarseToFine.compactMap({ $0.firstDate(since: cutoff) }).min() else { return raw }
        let reach = earliest.addingTimeInterval(Self.hourResolution)
        let covering = coarseToFine.filter { ($0.firstDate(since: cutoff) ?? .distantFuture) <= reach }
        return covering.first { $0.count(since: cutoff) >= Self.minimumChartPoints } ?? covering.last ?? raw
    }

    private func rewind(to date: Date) {
        raw.rewind(to: date)
        minute.rewind(to: date)
        hour.rewind(to: date)
        cores.drop(from: date)
    }

    private static func downsample(_ points: [SystemPoint], to limit: Int) -> [SystemPoint] {
        guard points.count > limit else { return points }
        var result: [SystemPoint] = []
        result.reserveCapacity(limit)
        var bucket = 0
        var accumulator = PointAccumulator()
        for (index, point) in points.enumerated() {
            let next = index * limit / points.count
            if next != bucket, let average = accumulator.average() {
                result.append(average)
                accumulator = PointAccumulator()
            }
            bucket = next
            accumulator.add(point)
        }
        if let average = accumulator.average() { result.append(average) }
        return result
    }
}

extension HistoryArchive {
    private func recordUsage(_ groups: [AppGroup], span: UsageSpan, at date: Date) {
        if !ledgerDay.contains(date) {
            ledger = [:]
            ledgerDay = LedgerDay(containing: date)
        }
        for group in groups {
            ledger[group.id, default: AppUsage(group, at: date)].accumulate(group, span: span, at: date)
        }
        guard ledger.count > Self.ledgerCapacity + Self.ledgerTrimSlack else { return }
        let kept = ledger.values.sorted { $0.energyWattHours > $1.energyWattHours }.prefix(Self.ledgerCapacity)
        ledger = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }
}

extension HistoryArchive {
    private struct ArchiveFile: Codable {
        static let currentVersion = 1

        var version: Int
        var minute: [SystemPoint]
        var hour: [SystemPoint]
        var ledgerDay: Date
        var ledger: [AppUsage]
    }

    private func encodedFile() -> Data? {
        let file = ArchiveFile(
            version: ArchiveFile.currentVersion,
            minute: minute.persisted(),
            hour: hour.persisted(),
            ledgerDay: ledgerDay.start,
            ledger: Array(ledger.values)
        )
        do {
            return try JSONEncoder().encode(file)
        } catch {
            Self.log.error("Encoding history failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func restore(now: Date) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let file: ArchiveFile
        do {
            file = try JSONDecoder().decode(ArchiveFile.self, from: data)
        } catch {
            Self.log.error("Ignoring unreadable history file: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard file.version == ArchiveFile.currentVersion else { return }
        minute = HistoryTier(resolution: Self.minuteResolution, retention: Self.minuteRetention,
                             restoring: Self.recent(file.minute, within: Self.minuteRetention, of: now))
        hour = HistoryTier(resolution: Self.hourResolution, retention: Self.hourRetention,
                           restoring: Self.recent(file.hour, within: Self.hourRetention, of: now))
        guard ledgerDay.contains(file.ledgerDay) else { return }
        ledger = Dictionary(file.ledger.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func recent(_ points: [SystemPoint], within window: TimeInterval, of now: Date) -> [SystemPoint] {
        let cutoff = now.addingTimeInterval(-window)
        return points.filter { $0.date >= cutoff && $0.date <= now }.sorted { $0.date < $1.date }
    }

    nonisolated private static func write(_ data: Data, to url: URL, in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Saving history failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct HistoryWindow {
    let points: [SystemPoint]
    let maxGap: TimeInterval
}

private struct LedgerDay {
    let start: Date
    let end: Date

    init(containing date: Date) {
        let calendar = Calendar.current
        start = calendar.startOfDay(for: date)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

struct UsageSpan {
    let elapsed: TimeInterval
    let rateWindow: TimeInterval
}

private extension AppUsage {
    init(_ group: AppGroup, at date: Date) {
        self.init(
            id: group.id, name: group.name, bundlePath: group.bundlePath, cpuSeconds: 0, energyWattHours: 0,
            energyImpactSum: 0, networkBytes: 0, diskBytes: 0, peakMemory: 0, lastSeen: date
        )
    }

    // CPU, energy, impact and disk are averages over the whole elapsed span, so multiplying by it gives exact totals.
    mutating func accumulate(_ group: AppGroup, span: UsageSpan, at date: Date) {
        let metrics = group.metrics
        let impact = group.processes.reduce(0) { $0 + $1.sample.energyImpact }
        name = group.name
        bundlePath = group.bundlePath
        cpuSeconds += metrics.cpu / 100 * span.elapsed
        energyWattHours += metrics.energy * span.elapsed / 3_600
        energyImpactSum += impact * span.elapsed
        networkBytes += metrics.network * span.rateWindow
        diskBytes += metrics.disk * span.elapsed
        peakMemory = max(peakMemory, Double(metrics.memory))
        lastSeen = date
    }
}
