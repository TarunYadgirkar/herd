import Foundation

struct TableRowItem: Identifiable, Sendable {
    enum Role: Sendable { case group, cluster, process }

    let id: String
    let role: Role
    let group: AppGroup
    let process: GroupedProcess?
    let title: String
    let subtitle: String?
    let metrics: Metrics
    let count: Int
    let isApproximate: Bool
    let isSuspended: Bool
    var isUnavailable = false
    var children: [TableRowItem]?

    var cpu: Double { metrics.cpu }
    var memory: Double { Double(metrics.memory) }
    var energy: Double { metrics.energy }
    var gpu: Double { metrics.gpu }
    var network: Double { metrics.network }
    var disk: Double { metrics.disk }
    var threads: Int { metrics.threads }
    var sortTitle: String { title.lowercased() }
    var pid: pid_t? { process?.sample.pid }
}

enum TableRowBuilder {
    private static let minimumClusterSize = 2

    static func rows(for groups: [AppGroup], query: String) -> [TableRowItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { row(for: $0, needle: needle) }
    }

    private static func row(for group: AppGroup, needle: String) -> TableRowItem? {
        let groupMatches = needle.isEmpty || group.name.lowercased().contains(needle)
        let members = groupMatches ? group.processes : group.processes.filter { matches($0, needle) }
        guard !members.isEmpty else { return nil }
        let metrics = groupMatches ? group.metrics : members.reduce(Metrics()) { $0 + Metrics($1.sample) }
        let children = members.count > 1 || !groupMatches ? childRows(members, group: group) : nil
        return TableRowItem(
            id: group.id,
            role: .group,
            group: group,
            process: members.count == 1 ? members.first : nil,
            title: group.name,
            subtitle: subtitle(for: group, members: members),
            metrics: metrics,
            count: members.count,
            isApproximate: members.allSatisfy(\.sample.isApproximate),
            isSuspended: groupMatches ? group.isSuspended : members.allSatisfy(\.sample.isSuspended),
            isUnavailable: members.allSatisfy(\.sample.isUnavailable),
            children: children
        )
    }

    private static func childRows(_ members: [GroupedProcess], group: AppGroup) -> [TableRowItem] {
        guard group.runtime != nil else { return members.map { processRow($0, group: group) } }
        let clusters = Dictionary(grouping: members) { $0.title + "\u{0}" + ($0.subtitle ?? "") }
        return clusters.values.map { cluster in
            guard cluster.count >= minimumClusterSize, let first = cluster.first else {
                return processRow(cluster[0], group: group)
            }
            return TableRowItem(
                id: "\(group.id)/\(first.title)/\(first.subtitle ?? "")",
                role: .cluster,
                group: group,
                process: nil,
                title: first.title,
                subtitle: first.subtitle,
                metrics: cluster.reduce(Metrics()) { $0 + Metrics($1.sample) },
                count: cluster.count,
                isApproximate: cluster.allSatisfy(\.sample.isApproximate),
                isSuspended: cluster.allSatisfy(\.sample.isSuspended),
                children: cluster.map { processRow($0, group: group) }
            )
        }
    }

    private static func processRow(_ member: GroupedProcess, group: AppGroup) -> TableRowItem {
        TableRowItem(
            id: member.id,
            role: .process,
            group: group,
            process: member,
            title: member.title,
            subtitle: member.subtitle,
            metrics: Metrics(member.sample),
            count: 1,
            isApproximate: member.sample.isApproximate,
            isSuspended: member.sample.isSuspended,
            isUnavailable: member.sample.isUnavailable,
            children: nil
        )
    }

    private static func matches(_ member: GroupedProcess, _ needle: String) -> Bool {
        member.title.lowercased().contains(needle)
            || member.sample.name.lowercased().contains(needle)
            || String(member.sample.pid) == needle
            || member.sample.arguments.joined(separator: " ").lowercased().contains(needle)
    }

    private static func subtitle(for group: AppGroup, members: [GroupedProcess]) -> String? {
        if members.count == 1, let only = members.first, only.title != group.name { return only.title }
        return members.count == 1 ? members.first?.subtitle : nil
    }

    static func sorted(_ rows: [TableRowItem], using comparators: [KeyPathComparator<TableRowItem>]) -> [TableRowItem] {
        guard let first = comparators.first else { return rows }
        return sorted(rows, value: sortValue(for: first.keyPath), ascending: first.order == .forward)
    }

    private static func sorted(_ rows: [TableRowItem], value: ((TableRowItem) -> Double)?, ascending: Bool) -> [TableRowItem] {
        let decorated = rows.map { row in
            var copy = row
            copy.children = row.children.map { sorted($0, value: value, ascending: ascending) }
            return (key: value?(row) ?? 0, title: row.title.lowercased(), row: copy)
        }
        return decorated.sorted { lhs, rhs in
            if lhs.key != rhs.key { return ascending ? lhs.key < rhs.key : lhs.key > rhs.key }
            if value == nil && lhs.title != rhs.title { return ascending ? lhs.title < rhs.title : lhs.title > rhs.title }
            return lhs.title == rhs.title ? lhs.row.id < rhs.row.id : lhs.title < rhs.title
        }.map(\.row)
    }

    private static func sortValue(for keyPath: PartialKeyPath<TableRowItem>) -> ((TableRowItem) -> Double)? {
        switch keyPath {
        case \TableRowItem.cpu: { $0.metrics.cpu }
        case \TableRowItem.memory: { Double($0.metrics.memory) }
        case \TableRowItem.energy: { $0.metrics.energy }
        case \TableRowItem.gpu: { $0.metrics.gpu }
        case \TableRowItem.network: { $0.metrics.network }
        case \TableRowItem.disk: { $0.metrics.disk }
        case \TableRowItem.threads: { Double($0.metrics.threads) }
        default: nil
        }
    }

    static func holding(_ rows: [TableRowItem], order: [String: Int]) -> [TableRowItem] {
        rows.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }.map { row in
            var copy = row
            copy.children = row.children.map { holding($0, order: order) }
            return copy
        }
    }

    static func flattenOrder(_ rows: [TableRowItem]) -> [String: Int] {
        var order: [String: Int] = [:]
        func visit(_ items: [TableRowItem]) {
            for item in items {
                order[item.id] = order.count
                if let children = item.children { visit(children) }
            }
        }
        visit(rows)
        return order
    }
}
