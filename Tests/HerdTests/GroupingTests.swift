import Foundation
import Testing
@testable import Herd

@Suite struct BundleDetectionTests {
    @Test func findsOutermostBundleForNestedHelpers() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(AppGrouper.outermostBundle(path) == "/Applications/Google Chrome.app")
    }

    @Test func handlesBareBundlePathAndLooseBinaries() {
        #expect(AppGrouper.outermostBundle("/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(AppGrouper.outermostBundle("/usr/bin/top") == nil)
        #expect(AppGrouper.outermostBundle("") == nil)
    }
}

@Suite struct RuntimeDetectionTests {
    @Test func detectsInterpretersByExecutableName() {
        #expect(Runtime.detect(executableName: "python3.12") == .python)
        #expect(Runtime.detect(executableName: "Python") == .python)
        #expect(Runtime.detect(executableName: "node") == .node)
        #expect(Runtime.detect(executableName: "java") == .java)
        #expect(Runtime.detect(executableName: "pythonic-tool") == nil)
        #expect(Runtime.detect(executableName: "Google Chrome") == nil)
    }
}

@Suite struct ScriptLabelTests {
    private let home = NSHomeDirectory()

    @Test func labelsScriptByFileNameAndAbbreviatedFolder() {
        let label = ScriptLabel.make(runtime: .python, arguments: ["python3", "train.py", "--epochs", "3"], workingDirectory: "\(home)/ml")
        #expect(label == ScriptLabel(title: "train.py", location: "~/ml"))
    }

    @Test func resolvesRelativeScriptAgainstWorkingDirectory() {
        let label = ScriptLabel.make(runtime: .python, arguments: ["python3", "scripts/run.py"], workingDirectory: "\(home)/proj")
        #expect(label == ScriptLabel(title: "run.py", location: "~/proj/scripts"))
    }

    @Test func labelsModulesInlineCodeAndRepl() {
        #expect(ScriptLabel.make(runtime: .python, arguments: ["python3", "-m", "http.server"], workingDirectory: nil).title == "-m http.server")
        #expect(ScriptLabel.make(runtime: .node, arguments: ["node", "-e", "1+1"], workingDirectory: nil).title == "inline code")
        #expect(ScriptLabel.make(runtime: .node, arguments: ["node"], workingDirectory: nil).title == "interactive")
    }

    @Test func skipsFlagsThatTakeValues() {
        let label = ScriptLabel.make(runtime: .node, arguments: ["node", "--require", "ts-node/register", "server.ts"], workingDirectory: nil)
        #expect(label.title == "server.ts")
    }

    @Test func namesNodePackagesIncludingScopedAndShims() {
        let scoped = ScriptLabel.make(runtime: .node, arguments: ["node", "\(home)/app/node_modules/@biomejs/biome/bin/biome"], workingDirectory: nil)
        #expect(scoped == ScriptLabel(title: "@biomejs/biome", location: "~/app"))
        let shim = ScriptLabel.make(runtime: .node, arguments: ["node", "\(home)/app/node_modules/.bin/vite"], workingDirectory: nil)
        #expect(shim == ScriptLabel(title: "vite", location: "~/app"))
        let npx = ScriptLabel.make(runtime: .node, arguments: ["node", "\(home)/.npm/_npx/abc/node_modules/typescript/bin/tsc"], workingDirectory: nil)
        #expect(npx == ScriptLabel(title: "typescript", location: "npx"))
    }

    @Test func usesRenamedArgvFromNpx() {
        let label = ScriptLabel.make(runtime: .node, arguments: ["npm exec @playwright/mcp@latest", "", ""], workingDirectory: nil)
        #expect(label.title == "@playwright/mcp")
    }

    @Test func labelsJavaByJarOrClassName() {
        #expect(ScriptLabel.make(runtime: .java, arguments: ["java", "-jar", "/opt/tools/app.jar"], workingDirectory: nil) == ScriptLabel(title: "app.jar", location: "/opt/tools"))
        #expect(ScriptLabel.make(runtime: .java, arguments: ["java", "-cp", "lib/*", "com.example.Main"], workingDirectory: nil).title == "Main")
    }
}

@Suite struct VirtualMachineGroupingTests {
    private static let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    private let home = "/Users/someone"

    private func vm(pid: pid_t, responsible: pid_t) -> ProcessSample {
        ProcessSample(
            id: "\(pid)", pid: pid, ppid: 1, responsiblePid: responsible, uid: getuid(), name: "com.apple.Virtualization.VirtualMachine",
            path: Self.vmPath, arguments: [], startTime: nil, cpuPercent: 5, memoryBytes: 8_000_000_000, energyWatts: 0, diskReadBps: 0,
            diskWriteBps: 0, netInBps: 0, netOutBps: 0, gpuPercent: 0, threads: 4, isApproximate: false, isSuspended: false
        )
    }

    @Test func resolvesOwnerFromOpenDiskImages() {
        let inBundle = ["\(home)/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img", "/Applications/Claude.app/Contents/Resources/smol-bin.arm64.img"]
        #expect(VirtualMachineOwner.resolve(openFiles: inBundle, home: home) == .bundle("/Applications/Claude.app"))
        let inSupport = ["\(home)/.cache/x", "\(home)/Library/Application Support/Docker/vms/0/data/Docker.raw"]
        #expect(VirtualMachineOwner.resolve(openFiles: inSupport, home: home) == .folder("Docker"))
        #expect(VirtualMachineOwner.resolve(openFiles: ["\(home)/.antigravity/extensions/lib"], home: home) == .folder("Antigravity"))
        #expect(VirtualMachineOwner.resolve(openFiles: ["/System/Library/CoreServices/SystemVersion.bundle/x"], home: home) == nil)
    }

    @Test func filesLeftoverVirtualMachineUnderItsAppNotMacOS() throws {
        let grouper = AppGrouper(openFiles: { _ in ["/Applications/Claude.app/Contents/Resources/smol-bin.arm64.img"] })
        let group = try #require(grouper.group([vm(pid: 900, responsible: 12345)], regularAppPids: []).first)
        #expect(group.kind == .background)
        #expect(group.bundlePath == "/Applications/Claude.app")
        #expect(group.processes.first?.title == "Virtual machine")
        #expect(group.processes.first?.subtitle == "Its app has quit")
    }

    @Test func namesVirtualMachineByFolderWhenNoAppHoldsIt() throws {
        let grouper = AppGrouper(openFiles: { _ in ["\(NSHomeDirectory())/.antigravity/extensions/lib"] })
        let group = try #require(grouper.group([vm(pid: 901, responsible: 901)], regularAppPids: []).first)
        #expect(group.name == "Virtual machine (Antigravity)")
        #expect(group.kind == .background)
        #expect(group.processes.first?.subtitle == nil)
    }
}

@Suite struct RuntimeLauncherLabelTests {
    private func process(pid: pid_t, responsible: pid_t, path: String, arguments: [String] = []) -> ProcessSample {
        ProcessSample(
            id: "\(pid)", pid: pid, ppid: 1, responsiblePid: responsible, uid: getuid(), name: (path as NSString).lastPathComponent,
            path: path, arguments: arguments, startTime: nil, cpuPercent: 0, memoryBytes: 1, energyWatts: 0, diskReadBps: 0,
            diskWriteBps: 0, netInBps: 0, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false
        )
    }

    private func makeApp(_ name: String, in folder: URL) throws -> String {
        let contents = folder.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.launcher"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return folder.appending(path: "\(name).app").path
    }

    @Test func namesSharedRuntimeGroupTheSameWhicheverLauncherComesFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "herd-launchers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let alpha = try makeApp("Alpha", in: folder)
        let beta = try makeApp("Beta", in: folder)
        let samples = [
            process(pid: 10, responsible: 10, path: "\(alpha)/Contents/MacOS/Alpha"),
            process(pid: 20, responsible: 20, path: "\(beta)/Contents/MacOS/Beta"),
            process(pid: 11, responsible: 10, path: "/usr/local/bin/node", arguments: ["node", "a.js"]),
            process(pid: 21, responsible: 20, path: "/usr/local/bin/node", arguments: ["node", "b.js"]),
        ]
        let names = try [samples, Array(samples.reversed())].map { order in
            let groups = AppGrouper().group(order, regularAppPids: [])
            return try #require(groups.first { $0.runtime == .node }).name
        }
        #expect(names == ["Node.js (via Alpha)", "Node.js (via Alpha)"])
    }
}

@Suite struct OpenFileTests {
    @Test func listsFilesThisProcessHoldsOpen() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "herd-open-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
        let open = ProcessIntrospection.openFilePaths(getpid())
        #expect(open.contains { $0.hasSuffix(url.lastPathComponent) })
    }
}
