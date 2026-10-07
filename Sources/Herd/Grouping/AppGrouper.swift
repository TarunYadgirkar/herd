import Darwin
import Foundation

final class AppGrouper {
    private enum Target {
        case bundle(String)
        case runtime(Runtime)
        case standalone(String)
    }

    private struct Assignment {
        let target: Target
        let key: String
        let title: String
        let subtitle: String?
    }

    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/",
    ]

    private let currentUid = getuid()
    private var bundleNames: [String: String] = [:]
    private var assignments: [String: Assignment] = [:]

    func group(_ samples: [ProcessSample], regularAppPids: Set<pid_t>) -> [AppGroup] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String: (target: Target, members: [GroupedProcess])] = [:]
        var nextAssignments: [String: Assignment] = [:]
        nextAssignments.reserveCapacity(samples.count)
        for sample in samples {
            let assignment = assignments[sample.id] ?? assign(sample, byPid: byPid)
            nextAssignments[sample.id] = assignment
            let member = GroupedProcess(sample: sample, title: assignment.title, subtitle: assignment.subtitle)
            buckets[assignment.key, default: (assignment.target, [])].members.append(member)
        }
        assignments = nextAssignments
        return buckets.map { key, bucket in
            makeGroup(key: key, target: bucket.target, members: bucket.members, regularAppPids: regularAppPids)
        }
    }

    private func assign(_ sample: ProcessSample, byPid: [pid_t: ProcessSample]) -> Assignment {
        if let runtime = Runtime.detect(executableName: sample.name) {
            let label = ScriptLabel.make(runtime: runtime, arguments: sample.arguments, workingDirectory: sample.workingDirectory)
            return makeAssignment(.runtime(runtime), title: label.title, subtitle: label.location)
        }
        let ownBundle = Self.outermostBundle(sample.path)
        if let parentBundle = responsibleBundle(for: sample, ownBundle: ownBundle, byPid: byPid) {
            return makeAssignment(.bundle(parentBundle), title: sample.name)
        }
        if let ownBundle { return makeAssignment(.bundle(ownBundle), title: sample.name) }
        return makeAssignment(.standalone(sample.name), title: sample.name)
    }

    private func makeAssignment(_ target: Target, title: String, subtitle: String? = nil) -> Assignment {
        Assignment(target: target, key: Self.key(for: target), title: title, subtitle: subtitle)
    }

    private func responsibleBundle(for sample: ProcessSample, ownBundle: String?, byPid: [pid_t: ProcessSample]) -> String? {
        guard sample.responsiblePid != sample.pid,
              let responsible = byPid[sample.responsiblePid],
              Runtime.detect(executableName: responsible.name) == nil,
              let bundle = Self.outermostBundle(responsible.path) else { return nil }
        let isServiceOnBehalf = ownBundle == nil || sample.path.contains(".xpc/")
        return isServiceOnBehalf ? bundle : nil
    }

    private func makeGroup(key: String, target: Target, members: [GroupedProcess], regularAppPids: Set<pid_t>) -> AppGroup {
        let metrics = members.reduce(Metrics()) { $0 + Metrics($1.sample) }
        switch target {
        case .bundle(let path):
            let mainPid = Self.mainPid(bundle: path, members: members, regularAppPids: regularAppPids)
            let isRegular = members.contains { regularAppPids.contains($0.sample.pid) }
            let kind: GroupKind = isRegular ? .apps : (isSystemPath(path) ? .system : .background)
            return AppGroup(id: key, name: displayName(forBundle: path), kind: kind, bundlePath: path, runtime: nil,
                            mainPid: mainPid, processes: members, metrics: metrics)
        case .runtime(let runtime):
            return AppGroup(id: key, name: runtime.rawValue, kind: .background, bundlePath: nil, runtime: runtime,
                            mainPid: nil, processes: members, metrics: metrics)
        case .standalone(let name):
            let isSystem = members.allSatisfy { isSystemProcess($0.sample) }
            return AppGroup(id: key, name: name, kind: isSystem ? .system : .background, bundlePath: nil, runtime: nil,
                            mainPid: members.map(\.sample.pid).min(), processes: members, metrics: metrics)
        }
    }

    private static func key(for target: Target) -> String {
        switch target {
        case .bundle(let path): "bundle:\(path)"
        case .runtime(let runtime): "runtime:\(runtime.rawValue)"
        case .standalone(let name): "proc:\(name)"
        }
    }

    private static func mainPid(bundle: String, members: [GroupedProcess], regularAppPids: Set<pid_t>) -> pid_t? {
        let mainExecutableDir = bundle + "/Contents/MacOS/"
        let candidates = members.map(\.sample).filter { $0.path.hasPrefix(mainExecutableDir) }
        if let regular = candidates.first(where: { regularAppPids.contains($0.pid) }) { return regular.pid }
        return candidates.map(\.pid).min()
    }

    static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.upperBound].dropLast())
    }

    private func displayName(forBundle path: String) -> String {
        if let cached = bundleNames[path] { return cached }
        let raw = FileManager.default.displayName(atPath: path)
        let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
        bundleNames[path] = name
        return name
    }

    private func isSystemPath(_ path: String) -> Bool {
        Self.systemPrefixes.contains { path.hasPrefix($0) }
    }

    private func isSystemProcess(_ sample: ProcessSample) -> Bool {
        sample.uid != currentUid || sample.path.isEmpty || isSystemPath(sample.path)
    }
}
