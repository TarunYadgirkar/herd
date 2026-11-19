import Foundation

enum ProcessExplanations {
    static func explanation(for name: String) -> String? {
        if let exact = known[name] { return exact }
        if let python = pythonFamily(name) { return python }
        return helperExplanation(for: name)
    }

    private static func pythonFamily(_ name: String) -> String? {
        let lowered = name.lowercased()
        guard lowered == "python" || lowered.hasPrefix("python3") || lowered.hasPrefix("python2") else { return nil }
        return known["Python"]
    }

    private static func helperExplanation(for name: String) -> String? {
        if name.hasPrefix("com.apple.WebKit.") { return known["com.apple.WebKit.WebContent"] }
        if name.hasSuffix("Helper (Renderer)") {
            return "Draws tabs or web views for a Chromium-based app. Quitting it reloads those tabs."
        }
        if name.hasSuffix("Helper (GPU)") {
            return "Handles graphics and video for a Chromium-based app. The app restarts it if it quits."
        }
        if name.hasSuffix("Helper (Plugin)") || name.hasSuffix("Helper (Alerts)") || name.hasSuffix(" Helper") {
            return "A helper for the app above. Quit the app to stop it."
        }
        return nil
    }

    private static let known: [String: String] = [
        "WindowServer": "Draws everything on screen. Quitting it logs you out.",
        "kernel_task": "The core of macOS. High CPU usually means it is cooling the Mac. Can't be quit.",
        "mds": "Coordinates Spotlight indexing. Busy after big file changes.",
        "mds_stores": "Builds the Spotlight index. Busy after big file changes.",
        "mdworker_shared": "Reads files for the Spotlight index. Copies exit when they finish.",
        "Spotlight": "Runs the Spotlight search bar. macOS restarts it when you next search.",
        "launchd": "Starts and supervises every other process. Can't be quit.",
        "cloudd": "Syncs iCloud Drive and app data. Busy during transfers.",
        "bird": "Syncs iCloud Drive files. macOS restarts it if you quit it.",
        "photoanalysisd": "Scans your Photos library for faces, places and scenes. Works while the Mac is idle.",
        "photolibraryd": "Manages your Photos library and its iCloud sync. Busy after imports.",
        "mediaanalysisd": "Analyzes photos and videos for Live Text and visual search. Busy after new media arrives.",
        "coreaudiod": "Handles all sound. Quitting it cuts audio briefly, which can fix crackling.",
        "corespotlightd": "Indexes content inside apps for Spotlight. Busy after big changes.",
        "backupd": "Runs Time Machine backups.",
        "trustd": "Checks security certificates for websites and signed files.",
        "syspolicyd": "Checks that apps you open are signed (Gatekeeper). Busy when you open new or updated apps.",
        "nsurlsessiond": "Transfers data in the background for apps and iCloud.",
        "fileproviderd": "Connects cloud storage like iCloud Drive and Dropbox to Finder. Busy while files sync.",
        "softwareupdated": "Checks for and downloads macOS updates.",
        "logd": "Collects log messages from apps and macOS. A chatty app keeps it busy.",
        "hidd": "Reads your keyboard, mouse and trackpad. Quitting it freezes input until macOS restarts it.",
        "sharingd": "Powers AirDrop, Handoff and Universal Clipboard.",
        "bluetoothd": "Manages Bluetooth devices. Quitting it disconnects them briefly.",
        "airportd": "Manages Wi-Fi. Quitting it drops Wi-Fi briefly.",
        "WiFiAgent": "Shows Wi-Fi menus and network login pages.",
        "ControlCenter": "Runs Control Center and menu bar icons. macOS restarts it if you quit it.",
        "Dock": "Runs the Dock, Mission Control and the desktop background. Quitting it restarts a stuck Dock.",
        "Finder": "Shows your files and desktop. macOS reopens it if you quit it.",
        "SystemUIServer": "Draws some menu bar items. macOS restarts it if you quit it.",
        "loginwindow": "Manages your login session. Quitting it logs you out.",
        "distnoted": "Passes notifications between apps. High CPU means one app is sending too many.",
        "cfprefsd": "Reads and saves app preferences. macOS restarts it if it quits.",
        "symptomsd": "Watches network health so macOS can fix connection problems.",
        "rapportd": "Connects your Apple devices for Handoff and Continuity.",
        "siriactionsd": "Runs Shortcuts and Siri actions.",
        "suggestd": "Finds contacts and events in your mail and messages.",
        "knowledge-agent": "Records how you use apps so macOS can make suggestions. Stays on this Mac.",
        "nearbyd": "Finds nearby Apple devices for AirDrop and Find My.",
        "ReportCrash": "Writes a report when an app crashes. It exits when the report is saved.",
        "powerd": "Manages sleep, battery and power settings.",
        "opendirectoryd": "Looks up user accounts and passwords for macOS.",
        "secd": "Manages your keychain and iCloud Keychain sync.",
        "com.apple.WebKit.WebContent": "Draws web pages for Safari and other apps. Quitting one reloads its page.",
        "Python": "Runs a Python script. The command line below shows which one.",
        "Node.js": "Runs a JavaScript tool. The command line below shows which one.",
    ]
}
