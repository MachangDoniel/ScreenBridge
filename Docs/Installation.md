# Installation

Requirements: Xcode 16 or newer (tested with Xcode 27), iOS 16+ app, macOS 14+ Mac, `xcodegen` to build the helper from source (`brew install xcodegen`).

## 1. Install and start the Mac helper

```bash
./Scripts/install-helper.sh
```

(from a clone of this repository). This builds `ScreenBridge.app`, copies it to `~/Applications` and launches it. It's a menu-bar app with no Dock icon. On launch it:

- creates `~/Library/Application Support/ScreenBridge/` (mode 0700), including a public receiver identity,
- installs two stable commands that point at the app binary:
  - `~/Library/Application Support/ScreenBridge/bin/screenbridge` (build phase, doctor, revoke)
  - `~/Library/Application Support/ScreenBridge/bin/screenbridge-mcp` (MCP server)
- starts the TLS‑PSK receiver and advertises `_screenbridge._tcp` over Bonjour.

macOS may ask to allow incoming connections (application firewall) and local network access. Allow both. To start it at login, add it in **System Settings › General › Login Items**.

## 2. Add the package

In Xcode use **File › Add Package Dependencies…**, enter `https://github.com/MachangDoniel/ScreenBridge.git`, choose **Up to Next Minor Version** from `0.1.0`, and link only the **ScreenBridge** product to your app target. (Package.swift users: `.package(url: "https://github.com/MachangDoniel/ScreenBridge.git", .upToNextMinor(from: "0.1.0"))`; while ScreenBridge is 0.x, minor versions may contain breaking changes.)

`install-helper.sh` is in this repository, so clone it once to build the Mac helper:

```bash
git clone https://github.com/MachangDoniel/ScreenBridge.git && cd ScreenBridge && ./Scripts/install-helper.sh
```

## 3. One-time project setup

### Run Script phase

```bash
"$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" print-build-phase
```

In your app target, open **Build Phases › + › New Run Script Phase**, drag it to the **end** (after *Copy Bundle Resources*), and paste the script. Then:

- **Output Files**: `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ScreenBridgeConnection.json`
- Uncheck **Based on dependency analysis**. The git working-tree state isn't something Xcode can track as an input, so the phase runs on every build (it takes well under a second on typical repositories).
- **Build Settings › User Script Sandboxing** (`ENABLE_USER_SCRIPT_SANDBOXING`) = **No** for this target. The script reads git state and the ScreenBridge store outside the project.

What the phase does:

- **Debug**: registers the git repository root as a project, issues (or reuses) a development credential for this project and bundle ID, records a build snapshot on the Mac (commit, dirty flag, working-tree fingerprint, per-file blob hashes), and writes `ScreenBridgeConnection.json` into the built app.
- **Any other configuration**: deletes the file and does nothing else. To enable another configuration, set `SCREENBRIDGE_CONFIGURATIONS=Debug,Staging` in the script's environment.
- **Never fails your build**: if the helper isn't installed or anything goes wrong, it prints an Xcode `warning:` and the app runs without a Mac connection.

The connection file is generated into build products only, never into your source tree. Keep `ScreenBridgeConnection.json` in `.gitignore` anyway.

### Info.plist

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>ScreenBridge sends debug reports to the Mac that built this app.</string>
<key>NSBonjourServices</key>
<array>
    <string>_screenbridge._tcp</string>
</array>
```

iOS shows the Local Network permission prompt the first time the app browses. Choose **Allow**. You can change it later in **Settings › Privacy & Security › Local Network**. The simulator doesn't prompt.

Verify the setup:

```bash
"$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" doctor --plist path/to/Info.plist --app path/to/Build/Products/Debug-iphoneos/YourApp.app
```

## 4. Start ScreenBridge in the app

### UIKit (app delegate or scene-based)

```swift
import ScreenBridge

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    #if DEBUG
    ScreenBridge.start()
    #endif
    return true
}
```

`start()` is idempotent and safe to call before any scene connects. It attaches one overlay window per foreground `UIWindowScene` as scenes activate, removes it when a scene disconnects, and keeps inspection scoped to the scene whose button you tapped.

### SwiftUI app lifecycle

```swift
import SwiftUI
import ScreenBridge

@main
struct MyApp: App {
    init() {
        #if DEBUG
        ScreenBridge.start()
        #endif
    }

    var body: some Scene { WindowGroup { ContentView() } }
}
```

## 5. Register source anchors

Registration uses caller-site `#filePath` and `#line` defaults, so call it **from the file you want linked**.

| Where | API | Notes |
|---|---|---|
| Any type (view model, service, controller class) | `ScreenBridge.register(Type.self, role:)` | Call in the type's own file, for example in `init`. Lets other registrations link it by type. |
| A view controller instance | `screenBridgeSource(_:role:related:)` in `viewDidLoad` | Becomes the owning screen's anchor. |
| A view instance | `view.screenBridgeSource("Name")` | |
| Reusable cells | `cell.screenBridgeSource("Cell", at: indexPath, in: tableView)` | Call every time in `cellForRowAt` or `cellForItemAt`. A registration recorded for another row is ignored once the cell is reused. |
| SwiftUI | `.screenBridgeSource("Name", role:related:)` | Background `UIViewRepresentable` marker, public API only. Use `role: "screen"` on a screen's root view. |
| Related | `related: [.type(VM.self, role: "viewModel"), .file(#filePath, line: #line)]` | `.type` resolves if that type registered itself; otherwise it's shown as "file not registered". |

ScreenBridge never retains registered objects. Registrations live on the objects themselves (associated objects with value data and weak container references). SwiftUI markers are tracked weakly.

In Release builds every API compiles to an inlinable no-op, so registration calls can stay in your code without leaking source paths into the binary. See [Security.md](Security.md).

## 6. Logs (optional)

```swift
ScreenBridge.log("Loaded \(items.count) items", category: "feed")
```

This is a bounded 200-entry in-memory ring, sanitized as entries are written (tokens, JWTs, password and secret fields, emails, and runs of 9+ digits such as card, account or ID numbers are removed). The user opts in per report and sees every entry in the preview. ScreenBridge doesn't read the system console or capture network traffic.

## Using it

1. Run the Debug build from Xcode. The floating button's dot shows status: green means connected, orange means searching, grey means not configured, red means a problem. VoiceOver reads the status.
2. Tap the button. The screenshot is captured before any inspector UI appears.
   - **Inspect an element**: tap any view to see its class, accessibility identifier, registered anchor, owning screen, related types and navigation context. **Select parent element** walks up the hierarchy. **Reveal source on Mac** opens the file at the anchor line in Xcode.
   - **Screen source**: shows the visible screen's registration.
   - **Report a change**: draw with pen, ellipse, arrow or opaque redaction (undo is available), describe the change, optionally attach logs, **Preview what will be sent**, then **Send to Mac**.
3. After the Mac acknowledges: *“On your Mac. Report SB-… is ready.”* If the Mac is unreachable, the report is saved on the device and retried automatically with bounded backoff.
4. On the Mac, open the inbox from the menu-bar icon. Use **Prepare for Claude** or **Copy request**, then ask Claude. See [MCP.md](MCP.md).
