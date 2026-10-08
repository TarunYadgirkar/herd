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
