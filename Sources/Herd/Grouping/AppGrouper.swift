import Darwin
import Foundation

final class AppGrouper {
    private enum Target {
        case bundle(String)
        case project(String)
        case runtime(Runtime, launcher: String?)
        case standalone(String)
    }

    private struct Assignment {
        let target: Target
        let key: String
        let title: String
        let subtitle: String?
        let path: String
    }

    private static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/",
    ]

    private let currentUid = getuid()
    private var bundleNames: [String: String] = [:]
    private var bundleKeys: [String: String] = [:]
    private var assignments: [String: Assignment] = [:]
    private let projects: ProjectResolver

    init(projects: ProjectResolver = ProjectResolver()) {
        self.projects = projects
    }

    func group(_ samples: [ProcessSample], regularAppPids: Set<pid_t>) -> [AppGroup] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String: (target: Target, members: [GroupedProcess])] = [:]
        var nextAssignments: [String: Assignment] = [:]
        nextAssignments.reserveCapacity(samples.count)
        let assigned = samples.map { sample in
            let cached = assignments[sample.id].flatMap { $0.path == sample.path ? $0 : nil }
            let assignment = cached ?? assign(sample, byPid: byPid)
            nextAssignments[sample.id] = assignment
            return (sample, assignment)
        }
        assignments = nextAssignments
        let canonical = canonicalBundlePaths(assigned, regularAppPids: regularAppPids)
        for (sample, assignment) in assigned {
            let member = GroupedProcess(sample: sample, title: assignment.title, subtitle: assignment.subtitle)
            buckets[bucketKey(assignment, canonical: canonical), default: (assignment.target, [])].members.append(member)
        }
        return buckets.map { key, bucket in
            var group = makeGroup(key: key, target: bucket.target, members: bucket.members, regularAppPids: regularAppPids)
            group.launcherBundle = launcher(of: bucket.target, members: bucket.members, byPid: byPid)
            return group
        }
    }

    private func assign(_ sample: ProcessSample, byPid: [pid_t: ProcessSample]) -> Assignment {
        if let runtime = Self.standaloneRuntime(sample) {
            let label = ScriptLabel.make(runtime: runtime, arguments: sample.arguments, workingDirectory: sample.workingDirectory)
            let target: Target = projects.project(for: sample).map { .project($0) } ?? .runtime(runtime, launcher: launcherBundle(of: sample, byPid: byPid))
            return makeAssignment(target, title: label.title, subtitle: label.location, path: sample.path)
        }
        let ownBundle = Self.outermostBundle(sample.path)
        if let parentBundle = responsibleBundle(for: sample, ownBundle: ownBundle, byPid: byPid) {
            return makeAssignment(.bundle(parentBundle), title: sample.name, path: sample.path)
        }
        if let ownBundle { return makeAssignment(.bundle(ownBundle), title: sample.name, path: sample.path) }
        return makeAssignment(.standalone(sample.name), title: sample.name, path: sample.path)
    }

    // Two copies sharing a bundle identifier (Xcode and Xcode-beta, a dev build beside the installed app) need separate
    // groups so Quit and Force Quit reach only one copy. One copy keeps the plain key so its history survives.
    private func canonicalBundlePaths(_ assigned: [(ProcessSample, Assignment)], regularAppPids: Set<pid_t>) -> [String: String] {
        var paths: [String: Set<String>] = [:]
        var regularPaths: Set<String> = []
        for (sample, assignment) in assigned {
            guard case .bundle(let path) = assignment.target else { continue }
            paths[assignment.key, default: []].insert(path)
            if regularAppPids.contains(sample.pid) { regularPaths.insert(path) }
        }
        return paths.filter { $0.value.count > 1 }.mapValues { candidates in
            let rank = { (path: String) in (regularPaths.contains(path) ? 0 : 1, path.hasPrefix("/Applications/") ? 0 : 1, path) }
            return candidates.min { rank($0) < rank($1) }!
        }
    }

    private func bucketKey(_ assignment: Assignment, canonical: [String: String]) -> String {
        guard case .bundle(let path) = assignment.target, let keeper = canonical[assignment.key], keeper != path else { return assignment.key }
        return "\(assignment.key)|\(path)"
    }

    private func makeAssignment(_ target: Target, title: String, subtitle: String? = nil, path: String) -> Assignment {
        Assignment(target: target, key: key(for: target), title: title, subtitle: subtitle, path: path)
    }

    // Without a project, the app that launched a runtime (Claude starting MCP servers, an editor starting a language server) is the best owner Herd can name.
    private func launcherBundle(of sample: ProcessSample, byPid: [pid_t: ProcessSample]) -> String? {
        guard sample.responsiblePid != sample.pid, let responsible = byPid[sample.responsiblePid] else { return nil }
        return Self.outermostBundle(responsible.path)
    }

    private func launcher(of target: Target, members: [GroupedProcess], byPid: [pid_t: ProcessSample]) -> String? {
        switch target {
        case .runtime(_, let launcher): return launcher
        case .project: return nil
        case .bundle(let path):
            return members.lazy.compactMap { Self.ancestorBundle(of: $0.sample, excluding: path, byPid: byPid) }.first
        case .standalone:
            return members.lazy.compactMap { Self.ancestorBundle(of: $0.sample, excluding: nil, byPid: byPid) }.first
        }
    }

    private static let ancestorHops = 4

    // Apps often launch helpers through a stub that gives up responsibility (Claude starts Claude Code via a "disclaimer"),
    // so after the responsible process, the parent chain is walked to find the app that started it.
    private static func ancestorBundle(of sample: ProcessSample, excluding own: String?, byPid: [pid_t: ProcessSample]) -> String? {
        var candidates: [pid_t] = sample.responsiblePid != sample.pid ? [sample.responsiblePid] : []
        var current = sample
        for _ in 0..<ancestorHops {
            guard current.ppid > 1, let parent = byPid[current.ppid] else { break }
            candidates.append(parent.pid)
            current = parent
        }
        return candidates.lazy.compactMap { byPid[$0].flatMap { outermostBundle($0.path) } }.first { $0 != own }
    }

    // Interpreters bundled inside an app (ChatGPT's node, an Electron app's python) belong to that app, not the global runtime group.
    private static func standaloneRuntime(_ sample: ProcessSample) -> Runtime? {
        guard let runtime = Runtime.detect(executableName: sample.name) else { return nil }
        guard let bundle = outermostBundle(sample.path) else { return runtime }
        return (bundle as NSString).lastPathComponent == "Python.app" ? runtime : nil
    }

    private func responsibleBundle(for sample: ProcessSample, ownBundle: String?, byPid: [pid_t: ProcessSample]) -> String? {
        guard sample.responsiblePid != sample.pid,
              let responsible = byPid[sample.responsiblePid],
              Self.standaloneRuntime(responsible) == nil,
              let bundle = Self.outermostBundle(responsible.path) else { return nil }
        guard let ownBundle else { return bundle }
        let isServiceOnBehalf = sample.path.contains(".xpc/") || !Self.isPrimaryBinary(sample.path, of: ownBundle)
        return isServiceOnBehalf ? bundle : nil
    }

    // An app's own code lives in Contents/MacOS or in nested helper bundles. Loose tools elsewhere in a bundle
    // (Xcode's git and clang) are run by whoever launched them, so they shouldn't make Xcode look busy.
    private static func isPrimaryBinary(_ path: String, of bundle: String) -> Bool {
        let inside = path.dropFirst(bundle.count)
        if inside.hasPrefix("/Contents/MacOS/") { return true }
        return [".app/", ".xpc/", ".appex/"].contains { inside.contains($0) }
    }

    private func makeGroup(key: String, target: Target, members: [GroupedProcess], regularAppPids: Set<pid_t>) -> AppGroup {
        let metrics = members.reduce(Metrics()) { $0 + Metrics($1.sample) }
        switch target {
        case .bundle(let path):
            let mainPid = Self.mainPid(bundle: path, members: members, regularAppPids: regularAppPids)
            let isRegular = members.contains { regularAppPids.contains($0.sample.pid) }
            let kind: GroupKind = isRegular ? .apps : (isSystemPath(path) ? .system : .background)
            return AppGroup(id: key, name: displayName(forBundle: path), kind: kind, bundlePath: path, runtime: nil,
                            mainPid: mainPid, processes: members, metrics: metrics, project: nil)
        case .project(let root):
            let runtimes = Self.runtimes(in: members)
            let folder = (root as NSString).lastPathComponent
            return AppGroup(id: key, name: "\(folder) (\(runtimes.map(\.rawValue).joined(separator: ", ")))", kind: .background,
                            bundlePath: nil, runtime: runtimes.first, mainPid: nil, processes: members, metrics: metrics, project: root)
        case .runtime(let runtime, let launcher):
            let owner = launcher.map { "via \(displayName(forBundle: $0))" } ?? "no project"
            return AppGroup(id: key, name: "\(runtime.rawValue) (\(owner))", kind: .background, bundlePath: nil, runtime: runtime,
                            mainPid: nil, processes: members, metrics: metrics, project: nil)
        case .standalone(let name):
            let isSystem = members.allSatisfy { isSystemProcess($0.sample) }
            return AppGroup(id: key, name: name, kind: isSystem ? .system : .background, bundlePath: nil, runtime: nil,
                            mainPid: members.map(\.sample.pid).min(), processes: members, metrics: metrics, project: nil)
        }
    }

    private func key(for target: Target) -> String {
        switch target {
        case .bundle(let path): "bundle:\(bundleKey(path))"
        case .project(let root): "project:\(root)"
        case .runtime(let runtime, let launcher): "runtime:\(runtime.rawValue)" + (launcher.map { "|\(bundleKey($0))" } ?? "")
        case .standalone(let name): "proc:\(name)"
        }
    }

    // Keying by bundle identifier keeps an app's history and selection across updates that move its path (the claude CLI, App Translocation).
    private func bundleKey(_ path: String) -> String {
        if let cached = bundleKeys[path] { return cached }
        let key = Bundle(path: path)?.bundleIdentifier ?? path
        bundleKeys[path] = key
        return key
    }

    private static func runtimes(in members: [GroupedProcess]) -> [Runtime] {
        let counts = Dictionary(members.compactMap { Runtime.detect(executableName: $0.sample.name) }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }.map(\.key)
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
