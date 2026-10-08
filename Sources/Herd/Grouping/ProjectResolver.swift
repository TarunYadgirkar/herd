import Foundation

// Finds the project a runtime process works for, so unrelated jobs that share an interpreter
// don't share a group, a history line, or a Quit button.
final class ProjectResolver {
    private static let markers = [
        "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "Cargo.toml", "go.mod",
        "Gemfile", "deno.json", "deno.jsonc", "pom.xml", "build.gradle", "composer.json", ".git",
    ]
    // A script inside these says where a tool is installed, not which project it serves.
    private static let toolingFragments = [
        "/node_modules/", "/.npm/", "/site-packages/", "/.local/", "/.nvm/", "/.pyenv/", "/.rbenv/", "/.cache/",
        "/Library/Caches/", "/opt/homebrew/", "/usr/local/", "/Library/Frameworks/", "/.bun/", "/.deno/",
    ]

    private let home: String
    private var roots: [String: String?] = [:]

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func project(for sample: ProcessSample) -> String? {
        let candidates = [scriptDirectory(sample), sample.workingDirectory].compactMap { $0 }
        for directory in candidates {
            if let root = root(startingAt: directory) { return root }
        }
        return nil
    }

    private func scriptDirectory(_ sample: ProcessSample) -> String? {
        let arguments = sample.arguments.dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("-") }
        guard let script = arguments.first else { return nil }
        let path = script.hasPrefix("/") ? script : sample.workingDirectory.map { "\($0)/\(script)" }
        guard let path, !isTooling(path) else { return nil }
        return (URL(fileURLWithPath: path).standardizedFileURL.path as NSString).deletingLastPathComponent
    }

    private func root(startingAt directory: String) -> String? {
        if let cached = roots[directory] { return cached }
        let found = findRoot(from: directory)
        roots[directory] = found
        return found
    }

    private func findRoot(from start: String) -> String? {
        guard start.hasPrefix(home + "/"), !isTooling(start + "/") else { return nil }
        var directory = start
        while directory.count > home.count {
            if hasMarker(directory) { return directory }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return start
    }

    private func hasMarker(_ directory: String) -> Bool {
        Self.markers.contains { FileManager.default.fileExists(atPath: "\(directory)/\($0)") }
    }

    private func isTooling(_ path: String) -> Bool {
        Self.toolingFragments.contains { path.contains($0) }
    }
}
