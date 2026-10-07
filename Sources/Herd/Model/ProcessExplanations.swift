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
            return "Draws one or more tabs or web views for a Chromium-based app like Chrome, Edge, Slack, or VS Code. Heavy pages and busy extensions make it work hard, and quitting it only reloads the tabs it was drawing."
        }
        if name.hasSuffix("Helper (GPU)") {
            return "Handles graphics and video for a Chromium-based app. It gets busy during video, animations, and WebGL, and the app restarts it automatically if it quits."
        }
        if name.hasSuffix("Helper (Plugin)") || name.hasSuffix("Helper (Alerts)") || name.hasSuffix(" Helper") {
            return "A helper process the app starts to keep tasks like networking, audio, or extensions separate from its main window. It belongs to the app above, so quitting the app is the cleaner way to stop it."
        }
        return nil
    }

    private static let known: [String: String] = [
        "WindowServer": "Draws everything you see on screen and composites every window. It gets busy with many displays, animations, or transparent windows, and quitting it logs you out.",
        "kernel_task": "The core of macOS. High CPU here usually means macOS is cooling the Mac down on purpose by keeping the processor busy, so it settles once things cool off. You can't quit it.",
        "mds": "The Spotlight metadata server that coordinates indexing. It's busy after big file changes or an update and calms down on its own.",
        "mds_stores": "Builds the Spotlight search index. It's busy after big file changes or an update and calms down on its own.",
        "mdworker_shared": "Reads files so Spotlight can index them. Many copies can run at once after you add lots of files, and they exit when they're done.",
        "Spotlight": "Runs the Spotlight search bar and its results. Quitting it is safe, and macOS starts it again the next time you search.",
        "launchd": "The first process macOS starts, and it starts and supervises every other one. It can't be quit.",
        "cloudd": "Syncs your iCloud Drive and app data with iCloud. It's busy while uploading or downloading files and is safe to leave alone.",
        "bird": "The iCloud Drive file sync daemon. Heavy activity usually means a large sync is in progress, and macOS restarts it if you quit it.",
        "photoanalysisd": "Scans your Photos library to recognize faces, places, and scenes. It works hardest when the Mac is idle or plugged in and finishes on its own.",
        "photolibraryd": "Manages your Photos library and its iCloud sync. It's busy after importing photos or turning on iCloud Photos.",
        "mediaanalysisd": "Analyzes photos and videos for features like Live Text and visual search. It runs in bursts after new media arrives and stops when it catches up.",
        "coreaudiod": "Handles all sound input and output. Quitting it cuts audio for a moment until macOS restarts it, which can fix crackling or missing sound.",
        "corespotlightd": "Indexes content inside apps (like messages and notes) for Spotlight. It's busy after big changes and settles on its own.",
        "backupd": "Runs Time Machine backups. It's busy during a backup and goes quiet when the backup finishes.",
        "trustd": "Checks security certificates when apps connect to websites or open signed files. Short bursts are normal, and it's best left running.",
        "syspolicyd": "Checks that apps you open are safe and signed (Gatekeeper). It spikes when you launch new or updated apps.",
        "nsurlsessiond": "Downloads and uploads data in the background for apps and iCloud. It's busy while something large transfers and is safe to leave alone.",
        "fileproviderd": "Connects cloud storage apps like iCloud Drive, Dropbox, and Google Drive to Finder. It's busy while files sync.",
        "softwareupdated": "Checks for and downloads macOS updates. It's busy while preparing an update and quiet otherwise.",
        "logd": "Collects log messages from every app and from macOS. A chatty app can keep it busy, and it should be left running.",
        "hidd": "Reads input from your keyboard, mouse, and trackpad. Quitting it makes input freeze until macOS restarts it.",
        "sharingd": "Powers AirDrop, Handoff, and Universal Clipboard. It's busy while finding nearby devices or sending files.",
        "bluetoothd": "Manages Bluetooth connections to headphones, keyboards, and other devices. Quitting it disconnects them briefly until it restarts.",
        "airportd": "Manages your Wi-Fi connection. It's busy while scanning for networks, and quitting it drops Wi-Fi for a moment.",
        "WiFiAgent": "Shows Wi-Fi menus and prompts like captive portal login pages. It's light and safe to leave running.",
        "ControlCenter": "Runs Control Center and many menu bar icons. Quitting it is safe, and macOS restarts it right away.",
        "Dock": "Runs the Dock, Mission Control, Launchpad, and the desktop background. Quitting it is safe and is a common fix when the Dock gets stuck.",
        "Finder": "Shows your files, windows, and desktop icons. Quitting it is safe, and macOS reopens it automatically.",
        "SystemUIServer": "Draws some menu bar items, like the clock on older setups and third party menu extras. Quitting it is safe, and it restarts on its own.",
        "loginwindow": "Manages your login session and the apps that open with it. Quitting it logs you out immediately.",
        "distnoted": "Passes notifications between apps so they can react to changes. It's normally tiny, and a busy copy usually means one app is sending too many messages.",
        "cfprefsd": "Reads and saves app preferences. Brief activity when apps launch is normal, and macOS restarts it if it quits.",
        "symptomsd": "Watches network health to help macOS fix connection problems. It's light and best left running.",
        "rapportd": "Lets your Apple devices talk to each other for features like Handoff and Continuity. It's safe to leave running.",
        "siriactionsd": "Runs Shortcuts and Siri actions in the background. It's busy while a shortcut runs.",
        "suggestd": "Finds suggestions like contacts and events in your mail and messages. It works in the background and settles down on its own.",
        "knowledge-agent": "Builds the on-device record of how you use apps so macOS can make suggestions. It runs in bursts and stops on its own.",
        "nearbyd": "Finds nearby Apple devices for features like AirDrop and Find My. It's light and safe to leave running.",
        "ReportCrash": "Writes a crash report when an app crashes. A busy copy means something just crashed, and it exits when the report is saved.",
        "powerd": "Manages sleep, battery, and power settings. It's light and should be left running.",
        "opendirectoryd": "Looks up user accounts and passwords for macOS. It's normally quiet and should be left running.",
        "secd": "Manages your keychain and iCloud Keychain sync. Brief activity after signing in or syncing passwords is normal.",
        "com.apple.WebKit.WebContent": "Draws web pages for Safari and apps that show web content. Each tab can have its own copy, and quitting one only reloads that page.",
        "Python": "Runs Python scripts and tools. Check the command line below to see which script it is before quitting, since a script may be doing work you started.",
        "Node.js": "Runs JavaScript tools like dev servers, build tools, and editor extensions. Check the command line below to see which one it is before quitting.",
    ]
}
