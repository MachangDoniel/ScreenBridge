# Troubleshooting

Start with:

```bash
"$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" doctor --plist path/to/Info.plist --app path/to/YourApp.app
```

| Symptom | Cause and fix |
|---|---|
| Build log: `warning: ScreenBridge helper is not installed` | Open `ScreenBridge.app` once (it installs the command), then rebuild. |
| Build log: `warning: ScreenBridge helper is not running` | The build is configured; reports will queue on the device. Open the helper. |
| Button dot is grey, "Not set up for this build" | No `ScreenBridgeConnection.json` in the app. Check the Run Script phase is last, its Output Files entry, that User Script Sandboxing is **No**, and that you built the Debug configuration. |
| "Local Network access needed" | Allow the app in **Settings › Privacy & Security › Local Network**, and check `NSBonjourServices` contains `_screenbridge._tcp`. |
| Stuck on "Looking for <Mac>…" | The phone and Mac must be on the same network, and some guest or enterprise Wi‑Fi blocks Bonjour or client-to-client traffic. Allow incoming connections for ScreenBridge in the macOS firewall. If the app was built on a different Mac, rebuild on this one. |
| "Mac rejected this build" | The credential was revoked, or the app was built for another receiver or bundle ID. Rebuild and run from Xcode. |
| Reports say *Saved on this device* | The device couldn't reach the Mac. Reports retry automatically (2 s doubling to 5 min) while the app is open, and immediately when it returns to the foreground. The device keeps up to 20 for 7 days. |
| Consistency shows **unknown** | The project isn't a git repository, has no commits, or the build predates the snapshot. Commit at least once. |
| "Reveal source" does nothing | The anchor must be inside the registered project root. `xed` comes with Xcode; without it ScreenBridge opens the file in Xcode without selecting the line. |
| Claude doesn't list the tools | Quit and reopen Claude Desktop after editing `claude_desktop_config.json`. Then run the manual check in [MCP.md](MCP.md). |
| Element picker selects a large container | Use a more specific registration, or **Select parent element** or **Pick another element**. Views that ignore touches can sit under transparent overlays, and the picker follows UIKit hit-testing first. |
| An element shows the wrong cell | The registration is checked against the cell's *current* index path. Call `screenBridgeSource(_:at:in:)` every time in `cellForRowAt`. |

Data lives in `~/Library/Application Support/ScreenBridge/`. Deleting `reports/` clears the inbox. Deleting the whole folder resets the receiver identity, so every app must be rebuilt.
