import Foundation

// A VM started with Virtualization.framework runs as an Apple XPC service, so its own path names no app. The disk
// images it holds open do: one inside an app bundle names that app, otherwise the folder holding them names the owner.
enum VirtualMachineOwner: Equatable {
    case bundle(String)
    case folder(String)

    static let title = "Virtual machine"

    static func isVirtualMachine(_ path: String) -> Bool {
        path.hasSuffix("/com.apple.Virtualization.VirtualMachine")
    }

    static func resolve(openFiles: [String], home: String = NSHomeDirectory()) -> VirtualMachineOwner? {
        if let bundle = openFiles.lazy.compactMap(appBundle).first { return .bundle(bundle) }
        let support = home + "/Library/Application Support/"
        if let name = openFiles.lazy.compactMap({ firstComponent($0, after: support) }).first { return .folder(name) }
        let hidden = home + "/."
        guard let name = openFiles.lazy.compactMap({ firstComponent($0, after: hidden) }).first else { return nil }
        return .folder(name.prefix(1).uppercased() + name.dropFirst())
    }

    private static func appBundle(_ path: String) -> String? {
        path.hasPrefix("/System/") ? nil : AppGrouper.outermostBundle(path)
    }

    private static func firstComponent(_ path: String, after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
    }
}
