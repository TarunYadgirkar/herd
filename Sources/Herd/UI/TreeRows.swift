import Darwin
import Foundation

// Builds the parent/child process tree. launchd parents nearly everything, so its children become the top level.
enum TreeRowBuilder {
    private struct Node {
        let member: GroupedProcess
        let group: AppGroup
    }

    private static let launchdPid: pid_t = 1
    private static let maxDepth = 64

    static func rows(for groups: [AppGroup], query: String) -> [TableRowItem] {
        var nodes: [pid_t: Node] = [:]
        for group in groups {
            for member in group.processes { nodes[member.sample.pid] = Node(member: member, group: group) }
        }
        var children: [pid_t: [pid_t]] = [:]
        var roots: [pid_t] = []
        for (pid, node) in nodes {
            let parent = node.member.sample.ppid
            if pid == launchdPid { roots.append(pid); continue }
            if parent != pid, parent != launchdPid, nodes[parent] != nil {
                children[parent, default: []].append(pid)
            } else {
                roots.append(pid)
            }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return roots.compactMap { build($0, nodes: nodes, children: children, needle: needle, depth: 0) }
    }

    private static func build(_ pid: pid_t, nodes: [pid_t: Node], children: [pid_t: [pid_t]], needle: String, depth: Int) -> TableRowItem? {
        guard let node = nodes[pid], depth < maxDepth else { return nil }
        let kids = (children[pid] ?? []).compactMap { build($0, nodes: nodes, children: children, needle: needle, depth: depth + 1) }
        let matches = needle.isEmpty || matches(node, needle)
        guard matches || !kids.isEmpty else { return nil }
        let sample = node.member.sample
        let isMain = node.group.mainPid == pid && node.group.bundlePath != nil
        return TableRowItem(
            id: node.member.id,
            role: isMain ? .group : .process,
            group: node.group,
            process: node.member,
            title: isMain ? node.group.name : node.member.title,
            subtitle: subtitle(node, isMain: isMain),
            metrics: Metrics(sample),
            count: 1,
            isApproximate: sample.isApproximate,
            isSuspended: sample.isSuspended,
            isUnavailable: sample.isUnavailable,
            lacksCounters: !sample.hasDetailedCounters,
            children: kids.isEmpty ? nil : kids
        )
    }

    private static func subtitle(_ node: Node, isMain: Bool) -> String? {
        if isMain { return nil }
        if let subtitle = node.member.subtitle { return subtitle }
        return node.group.name != node.member.title ? node.group.name : nil
    }

    private static func matches(_ node: Node, _ needle: String) -> Bool {
        node.member.title.lowercased().contains(needle)
            || node.group.name.lowercased().contains(needle)
            || String(node.member.sample.pid) == needle
    }
}
