# Security model and release builds

## Connection and authentication

| Concern | Design |
|---|---|
| Finding the right Mac | The app browses `_screenbridge._tcp` and only considers services whose TXT `rid` equals the receiver ID baked into its build. It never picks "the first Mac". |
| Secrets in Bonjour | The TXT record holds only the public receiver ID and protocol version. |
| Mutual authentication and encryption | TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`) with Network.framework. Each side proves it has the same 32-byte key, so a different Mac (or an app without the key) fails the handshake. No certificates are involved and no ATS exceptions are needed (raw `NWConnection`s aren't governed by ATS). |
| Wrong receiver | The handshake fails without the key. If a key leaked to another receiver, the app still rejects a `helloAck` with a different receiver ID, and the receiver rejects a `hello` addressed to another receiver ID. |
| Credential scope | One credential per (project root, app bundle ID), stored on the Mac in `credentials.json` with mode 0600. The receiver checks that the credential's project and bundle match the app's hello. |
| Revocation | Use **Connection › Revoke** or `screenbridge revoke <id>`. The key material is erased, the listener reloads its key set and drops existing sessions, and the next build issues a fresh credential. |
| Credentials in source control | The connection file is written only into build products (`TARGET_BUILD_DIR`). Nothing is written to the source tree. |
| Report integrity | Every image's SHA-256, byte length and pixel dimensions are checked against the report before storage. Only `original.png` and `annotated.png` are accepted. Report IDs are validated against `^SB-[0-9A-F]{12}$` before any filesystem use. |
| Duplicates | Stable report IDs. The receiver acknowledges duplicates without storing them twice, and the device deletes from its outbox only after an ack for the same ID. |
| Reveal and source reads | Confined to registered project roots (see [MCP.md](MCP.md)). A device can only reveal files in its own credential's project. |

Known limit: inside an authenticated TLS session, the credential ID in `hello` isn't cryptographically bound to which PSK was used (Network.framework doesn't expose the negotiated PSK identity). A holder of one valid credential could claim another credential's ID. All credentials belong to the same developer's Mac, so this matters only for project scoping, not for outsiders.

## What a report contains

Exactly what the **Preview** screen shows: the included PNGs, your description, vector annotations, selected area, chosen Claude destination, the selected element (class, accessibility identifier, frame, view hierarchy and supported runtime properties), controller and navigation context (class names), registered anchors with repository-relative paths, app version and build, device model and OS, build ID, commit, dirty flag and fingerprint, and optional sanitized log entries. Exported reports contain no absolute paths.

View details can include sanitized label text, button titles, non-secure input text, accessibility label/value, and supported control state. Secure text fields omit their text and accessibility values. Text is best-effort sanitized with the same rules as app logs. Disable view details or logs in the composer to exclude them; screenshot redaction removes pixels and does not remove separately included textual evidence. Preview all selected evidence before sending. ScreenBridge does not read the system console or network bodies.

Portable browser/Code exports are stored locally under `Exports/<report-id>` and are removed when the report is deleted or pruned. Source excerpts use the same project confinement as MCP. Claude configuration is a separate explicit setup action that grants its local MCP process report/image access and confined reads of registered project files.

### Redaction

Redactions are rectangles rounded outward to whole pixels and filled fully opaque with `.copy` blending, after all markup. They're burned into **both** exported images. When any redaction exists, no unredacted original and no thumbnail are produced. Images are redrawn into a fresh sRGB bitmap and re-encoded as PNG without capture metadata. ImageIO reports only synthesized color-space and dimension fields. Tests verify that every pixel in a redacted area is black in both outputs.

## Keeping tooling out of distribution builds

Wrapping `ScreenBridge.start()` in `#if DEBUG` isn't enough by itself, so ScreenBridge enforces this at the package level:

1. The `ScreenBridge` target compiles its implementation only with `SCREENBRIDGE_ENABLED`, defined `.when(configuration: .debug)`. In Release, every public API (`start`, `log`, `register`, `screenBridgeSource`) is an `@inlinable` no-op, so call sites compile unchanged and their `#filePath` literals are optimized away.
2. `ScreenBridgeProtocol` and `ScreenBridgeTransport` compile to empty modules for iOS Release builds (`SCREENBRIDGE_STRIPPED`). They stay intact for the Mac helper's own Release build.
3. The build phase deletes `ScreenBridgeConnection.json` for any configuration that isn't enabled.

`Scripts/verify-release.sh` in the [demo repo](https://github.com/MachangDoniel/ScreenBridgeDemo) archives the example app in Release and fails if the bundle contains the connection file, credential field names, inspector strings, transport symbols or absolute source paths. Verified result for the example: the binary went from 676 KB to 167 KB with no ScreenBridge strings and no `/Users/…` paths.

Custom configurations: Xcode builds package targets in debug mode only for configurations it treats as debug. If you archive from a configuration based on Debug, run the same checks as the demo's `verify-release.sh` on that archive.

To keep the package out of a Release *link* entirely, use a separate Debug-only app target or an xcconfig that links the product only in Debug. That's optional with the measures above.
