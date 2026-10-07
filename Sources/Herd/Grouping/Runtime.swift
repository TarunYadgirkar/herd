import Foundation

enum Runtime: String, CaseIterable, Sendable {
    case python = "Python"
    case node = "Node.js"
    case bun = "Bun"
    case deno = "Deno"
    case ruby = "Ruby"
    case java = "Java"
    case perl = "Perl"
    case php = "PHP"

    static func detect(executableName: String) -> Runtime? {
        let name = executableName.lowercased()
        if name == "python" || name.hasPrefix("python3") || name.hasPrefix("python2") { return .python }
        switch name {
        case "node", "nodejs": return .node
        case "bun": return .bun
        case "deno": return .deno
        case "ruby": return .ruby
        case "java": return .java
        case "perl": return .perl
        case "php": return .php
        default: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .python: "chevron.left.forwardslash.chevron.right"
        case .node, .bun, .deno: "hexagon"
        case .ruby: "diamond"
        case .java: "cup.and.saucer"
        case .perl, .php: "curlybraces"
        }
    }
}

struct ScriptLabel: Equatable, Sendable {
    let title: String
    let location: String?

    private static let flagsWithValue: Set<String> = ["-W", "-X", "--require", "-r", "--import", "--loader", "-cp", "-classpath", "--inspect-port"]

    static func make(runtime: Runtime, arguments: [String], workingDirectory: String?) -> ScriptLabel {
        let args = arguments.dropFirst().filter { !$0.isEmpty }
        let folder = workingDirectory.map(abbreviate)
        if let renamed = renamedTitle(arguments) { return ScriptLabel(title: renamed, location: folder) }
        if let module = value(after: "-m", in: args) { return ScriptLabel(title: "-m \(module)", location: folder) }
        if args.contains("-c") || args.contains("-e") || args.contains("--eval") { return ScriptLabel(title: "inline code", location: folder) }
        if runtime == .java, let jar = value(after: "-jar", in: args) { return fromPath(jar, workingDirectory: workingDirectory) }
        guard let script = firstPositional(args) else { return ScriptLabel(title: "interactive", location: folder) }
        if runtime == .java { return ScriptLabel(title: script.split(separator: ".").last.map(String.init) ?? script, location: folder) }
        return fromPath(script, workingDirectory: workingDirectory)
    }

    // Tools like npx overwrite their argv with a readable title ("npm exec @playwright/mcp@latest") and blank the rest.
    private static func renamedTitle(_ arguments: [String]) -> String? {
        guard let first = arguments.first, first.contains(" "), !first.hasPrefix("/"),
              arguments.dropFirst().allSatisfy(\.isEmpty) else { return nil }
        let npmExec = "npm exec "
        guard first.hasPrefix(npmExec) else { return first }
        let package = first.dropFirst(npmExec.count).split(separator: " ").first.map(String.init) ?? first
        return withoutVersion(package)
    }

    private static func withoutVersion(_ package: String) -> String {
        guard let at = package.lastIndex(of: "@"), at != package.startIndex else { return package }
        return String(package[..<at])
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func firstPositional(_ args: [String]) -> String? {
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if flagsWithValue.contains(arg) { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            return arg
        }
        return nil
    }

    private static func fromPath(_ raw: String, workingDirectory: String?) -> ScriptLabel {
        let base = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let url = raw.hasPrefix("/") || base == nil ? URL(fileURLWithPath: raw) : URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL
        let components = url.pathComponents
        if let packageIndex = components.lastIndex(of: "node_modules"), packageIndex + 1 < components.count {
            let package = components[packageIndex + 1]
            let isShim = package == ".bin" && packageIndex + 2 < components.count
            let scoped = package.hasPrefix("@") && packageIndex + 2 < components.count ? "\(package)/\(components[packageIndex + 2])" : package
            let location = raw.contains("/.npm/_npx/") ? "npx" : abbreviate(components.prefix(packageIndex).joined(separator: "/"))
            return ScriptLabel(title: isShim ? components[packageIndex + 2] : scoped, location: location)
        }
        let parent = url.deletingLastPathComponent().path
        let isLocatable = raw.contains("/") || workingDirectory != nil
        return ScriptLabel(title: url.lastPathComponent, location: isLocatable ? abbreviate(parent) : nil)
    }

    static func abbreviate(_ path: String) -> String {
        let cleaned = path.hasPrefix("//") ? String(path.dropFirst()) : path
        let home = NSHomeDirectory()
        return cleaned.hasPrefix(home) ? "~" + cleaned.dropFirst(home.count) : cleaned
    }
}
