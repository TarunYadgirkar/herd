import AppKit
import UniformTypeIdentifiers

// Most rows without an app bundle are macOS daemons or tools another app started. A gear or a terminal says nothing about
// which, so each one borrows the icon of what it serves: the System Settings icon for its feature, the system app, or the app that launched it.
@MainActor
enum IconSource {
    enum Known: Equatable {
        case setting(String)
        case app(bundleID: String)
    }

    enum Reference: Hashable {
        case file(String)
        case type(String)
    }

    private static let simulatorPath = "/CoreSimulator"
    private static let simulatorBundleID = "com.apple.iphonesimulator"
    private static let xcodeBundleID = "com.apple.dt.Xcode"
    private static let simulatorInXcode = "/Contents/Developer/Applications/Simulator.app"
    private static let settingPrefix = "com.apple.graphic-icon."
    private static let mediaPlayerPrefix = "AMP"

    private static let known: [String: Known] = {
        var map: [String: Known] = [:]
        func setting(_ icon: String, _ names: String...) { names.forEach { map[$0] = .setting(icon) } }
        func app(_ bundleID: String, _ names: String...) { names.forEach { map[$0] = .app(bundleID: bundleID) } }
        setting("about-current-device", "kernel_task", "launchd")
        setting("display", "WindowServer")
        setting("auto-brightness", "corebrightnessd")
        setting("stage-manager", "WindowManager")
        setting("desktop", "Dock")
        setting("control-center", "MenuBarAgent", "ControlCenter", "Control Center")
        setting("sound", "coreaudiod", "audiomxd", "audioaccessoryd")
        setting("bluetooth", "bluetoothd", "BTServer")
        setting("wifi", "airportd", "wifid", "wifip2pd", "wifianalyticsd", "wifivelocityd")
        setting("local-network", "mDNSResponder", "configd", "networkserviceproxy", "nsurlsessiond", "symptomsd", "nehelper", "networkd")
        setting("battery", "powerd", "thermalmonitord", "batteryintelligenced")
        setting("software-update", "softwareupdated", "SoftwareUpdateNotificationManager")
        setting("search", "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd", "spotlightknowledged", "spotlightknowledged.updater", "Spotlight")
        setting("notifications", "usernoted", "NotificationCenter")
        setting("airdrop", "sharingd")
        setting("passwords", "secd", "securityd", "trustd", "authd")
        setting("privacy", "tccd")
        setting("touch-id", "biometrickitd")
        setting("icloud-backup", "cloudd", "bird", "fileproviderd")
        setting("printer-sharing", "cupsd", "printtool")
        setting("screen-time", "ScreenTimeAgent", "UsageTrackingAgent")
        setting("location", "locationd")
        setting("siri", "siriactionsd", "siriknowledged", "assistantd", "SiriNCService", "siriinferenced")
        setting("intelligence", "intelligenceflowd", "intelligenceplatformd", "generativeexperiencesd", "suggestd", "duetexpertd")
        setting("data-and-sensors", "BiomeAgent", "biomed")
        setting("external-drive", "diskimagesiod", "diskarbitrationd")
        setting("internal-drive", "fseventsd", "apfsd")
        setting("gear", "cfprefsd")
        setting("fonts", "fontd")
        setting("keyboard", "TextInputMenuAgent", "imklaunchagent")
        setting("camera", "VDCAssistant", "appleh16camerad")
        setting("airplay-video", "AirPlayXPCHelper", "airplayxpchelper")
        setting("remote-devices", "remoted", "remotepairingd")
        setting("screen-sharing", "screensharingd")
        setting("accessibility", "universalaccessd")
        setting("wallet", "passd")
        setting("paired-devices", "rapportd")
        setting("incoming-phone-calls", "callservicesd")
        setting("incoming-facetime-calls", "avconferenced")
        setting("app-installation", "installd", "appstoreagent", "storedownloadd")
        app("com.apple.Console", "diagnosticd", "logd", "ReportCrash", "spindump", "osanalyticshelper", "analyticsd")
        app("com.apple.Photos", "photoanalysisd", "photolibraryd", "mediaanalysisd")
        app("com.apple.shortcuts", "BackgroundShortcutRunner", "linkd")
        app("com.apple.findmy", "searchpartyd")
        app("com.apple.backup.launcher", "backupd", "backupd-helper")
        return map
    }()

    // Daemons come in families named after what they serve (AMPLibraryAgent, CalendarAgent, imagent), so a name fragment
    // covers the ones the exact list misses. Earlier rules win; fragments are matched case-insensitively.
    private static let families: [(fragment: String, source: Known)] = [
        ("siri", .setting("siri")), ("intelligence", .setting("intelligence")), ("generative", .setting("intelligence")),
        ("spotlight", .setting("search")), ("bluetooth", .setting("bluetooth")), ("wifi", .setting("wifi")), ("airplay", .setting("airplay-video")),
        ("accessibility", .setting("accessibility")), ("universalaccess", .setting("accessibility")),
        ("account", .setting("account")), ("keychain", .setting("passwords")), ("notification", .setting("notifications")),
        ("location", .setting("location")), ("battery", .setting("battery")), ("power", .setting("battery")),
        ("display", .setting("display")), ("audio", .setting("sound")), ("camera", .setting("camera")), ("keyboard", .setting("keyboard")),
        ("font", .setting("fonts")), ("print", .setting("printer-sharing")), ("screentime", .setting("screen-time")),
        ("softwareupdate", .setting("software-update")), ("wallet", .setting("wallet")), ("xprotect", .setting("privacy")),
        ("music", .app(bundleID: "com.apple.Music")),
        ("calendar", .app(bundleID: "com.apple.iCal")), ("contacts", .app(bundleID: "com.apple.AddressBook")),
        ("mail", .app(bundleID: "com.apple.mail")), ("safari", .app(bundleID: "com.apple.Safari")), ("webkit", .app(bundleID: "com.apple.Safari")),
        ("imagent", .app(bundleID: "com.apple.MobileSMS")), ("messages", .app(bundleID: "com.apple.MobileSMS")),
        ("facetime", .app(bundleID: "com.apple.FaceTime")), ("photo", .app(bundleID: "com.apple.Photos")),
        ("notes", .app(bundleID: "com.apple.Notes")), ("remind", .app(bundleID: "com.apple.reminders")),
        ("weather", .app(bundleID: "com.apple.weather")), ("news", .app(bundleID: "com.apple.news")), ("maps", .app(bundleID: "com.apple.Maps")),
        ("homed", .app(bundleID: "com.apple.Home")), ("podcast", .app(bundleID: "com.apple.podcasts")), ("book", .app(bundleID: "com.apple.iBooksX")),
        ("game", .app(bundleID: "com.apple.games")), ("shortcut", .app(bundleID: "com.apple.shortcuts")), ("finder", .app(bundleID: "com.apple.finder")),
    ]

    private static var appPaths: [String: String?] = [:]
    private static var ownIcons: [String: Bool] = [:]
    private static var namedApps: [String: String?] = [:]
    private static var settingTypes: [String: Bool] = [:]

    static func reference(for group: AppGroup) -> Reference? {
        if let bundle = group.bundlePath, hasOwnIcon(bundle) { return .file(bundle) }
        if let source = known(for: group), let reference = resolve(source) { return reference }
        if let launcher = group.launcherBundle, hasOwnIcon(launcher) { return .file(launcher) }
        return installedApp(named: group.name).map { .file($0) }
    }

    // A copy of an app running outside its bundle (a test-driven Chrome, a CLI build) still looks like the installed app.
    private static func installedApp(named name: String) -> String? {
        if let cached = namedApps[name] { return cached }
        let path = "/Applications/\(name).app"
        let found = FileManager.default.fileExists(atPath: path) ? path : nil
        namedApps[name] = found
        return found
    }

    static func known(for group: AppGroup) -> Known? {
        if let source = known[group.name] { return source }
        if let executable = group.executablePath, let source = known[(executable as NSString).lastPathComponent] { return source }
        let paths = [group.bundlePath, group.executablePath].compactMap { $0 }
        if paths.contains(where: { $0.contains(simulatorPath) }) { return .app(bundleID: simulatorBundleID) }
        if group.name.hasPrefix(mediaPlayerPrefix) { return .app(bundleID: "com.apple.Music") }
        let name = group.name.lowercased()
        return families.first { name.contains($0.fragment) }?.source
    }

    static func image(for reference: Reference) -> NSImage {
        switch reference {
        case .file(let path): NSWorkspace.shared.icon(forFile: path)
        case .type(let identifier): UTType(identifier).map { NSWorkspace.shared.icon(for: $0) } ?? NSImage()
        }
    }

    private static func resolve(_ source: Known) -> Reference? {
        switch source {
        case .setting(let name):
            let identifier = settingPrefix + name
            let isValid = settingTypes[name] ?? (UTType(identifier) != nil)
            settingTypes[name] = isValid
            return isValid ? .type(identifier) : nil
        case .app(let bundleID):
            if appPaths[bundleID] == nil { appPaths[bundleID] = appPath(bundleID) }
            return appPaths[bundleID]?.map { .file($0) }
        }
    }

    // Simulator lives inside Xcode, where Launch Services often doesn't index it, and some Xcode versions don't ship it
    // as its own app, so simulator processes fall back to Xcode's icon.
    private static func appPath(_ bundleID: String) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url.path }
        guard bundleID == simulatorBundleID, let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xcodeBundleID) else { return nil }
        let simulator = xcode.path + simulatorInXcode
        return FileManager.default.fileExists(atPath: simulator) ? simulator : xcode.path
    }

    // Helper apps like Claude Code's claude.app ship no icon, and macOS draws a blank page for them.
    private static func hasOwnIcon(_ bundle: String) -> Bool {
        if let cached = ownIcons[bundle] { return cached }
        let info = Bundle(path: bundle)?.infoDictionary ?? [:]
        let hasIcon = ["CFBundleIconFile", "CFBundleIconName", "CFBundleIcons"].contains { info[$0] != nil }
        ownIcons[bundle] = hasIcon
        return hasIcon
    }
}
