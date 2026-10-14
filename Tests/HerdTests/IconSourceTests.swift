import Darwin
import Foundation
import Testing
@testable import Herd

private func sample(pid: pid_t, responsible: pid_t, name: String, path: String, ppid: pid_t = 1) -> ProcessSample {
    ProcessSample(
        id: "\(pid)", pid: pid, ppid: ppid, responsiblePid: responsible, uid: getuid(), name: name, path: path, arguments: [name],
        startTime: Date(timeIntervalSince1970: 1), cpuPercent: 1, memoryBytes: 1_000, energyWatts: 0, diskReadBps: 0, diskWriteBps: 0,
        netInBps: 0, netOutBps: 0, gpuPercent: 0, threads: 1, isApproximate: false, isSuspended: false, workingDirectory: nil
    )
}

private func group(_ name: String, bundle: String? = nil) -> AppGroup {
    AppGroup(id: "proc:\(name)", name: name, kind: .system, bundlePath: bundle, runtime: nil, mainPid: nil,
             processes: [], metrics: Metrics(), project: nil)
}

@MainActor
@Suite struct IconSourceTests {
    @Test func systemDaemonsBorrowTheSettingsPaneTheyServe() {
        #expect(IconSource.known(for: group("WindowServer")) == .setting("display"))
        #expect(IconSource.known(for: group("airportd")) == .setting("wifi"))
        #expect(IconSource.known(for: group("diagnosticd")) == .app(bundleID: "com.apple.Console"))
    }

    @Test func simulatorHelpersShowSimulator() {
        let bundle = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/SimMetalHost.xpc"
        #expect(IconSource.known(for: group("SimMetalHost", bundle: bundle)) == .app(bundleID: "com.apple.iphonesimulator"))
    }

    @Test func daemonFamiliesMatchByName() {
        #expect(IconSource.known(for: group("AMPLibraryAgent")) == .app(bundleID: "com.apple.Music"))
        #expect(IconSource.known(for: group("CalendarAgent")) == .app(bundleID: "com.apple.iCal"))
        #expect(IconSource.known(for: group("siriactionsd")) == .setting("siri"))
    }

    @Test func unknownToolsHaveNoKnownSource() {
        #expect(IconSource.known(for: group("my-script")) == nil)
    }
}

@Suite struct LauncherBundleTests {
    @Test func iconlessHelperAppRemembersWhoLaunchedIt() {
        let claude = "/Applications/Claude.app"
        let cli = "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app"
        let groups = AppGrouper().group([
            sample(pid: 10, responsible: 10, name: "Claude", path: claude + "/Contents/MacOS/Claude"),
            sample(pid: 20, responsible: 10, name: "claude", path: cli + "/Contents/MacOS/claude"),
        ], regularAppPids: [10])
        let helper = groups.first { $0.bundlePath == cli }
        #expect(helper?.launcherBundle == claude)
        #expect(groups.first { $0.bundlePath == claude }?.launcherBundle == nil)
    }

    @Test func followsParentsPastAStubThatDisclaimedResponsibility() {
        let claude = "/Applications/Claude.app"
        let cli = "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app"
        let groups = AppGrouper().group([
            sample(pid: 10, responsible: 10, name: "Claude", path: claude + "/Contents/MacOS/Claude"),
            sample(pid: 11, responsible: 11, name: "disclaimer", path: claude + "/Contents/Helpers/disclaimer", ppid: 10),
            sample(pid: 20, responsible: 20, name: "claude", path: cli + "/Contents/MacOS/claude", ppid: 11),
        ], regularAppPids: [10])
        #expect(groups.first { $0.bundlePath == cli }?.launcherBundle == claude)
    }
}
