# Development

## Layout and responsibilities

- `Sources/ScreenBridgeProtocol`: `DebugReport` schema (versioned `1.0`; readers accept the same major version and ignore unknown fields), `ConnectionConfig`, wire envelope and framing (`[u32 header][u32 body][JSON][parts]`), `AnnotationRenderer` (CoreGraphics; redaction and PNG export), `AspectFitMapping` (view points to image pixels), `LogSanitizer`.
- `Sources/ScreenBridgeTransport`: `TLSPSK` parameters, `FramedConnection`, `ReceiverBrowser` (TXT `rid` filter), `ReceiverSession` (client actor), `ReceiverListener` (server), `OutboxStore`, `OutboxProcessor`, `RetryPolicy` (2 s doubling to 5 min, 7-day expiry, 20-report cap).
- `Sources/ScreenBridge`: public API (`ScreenBridge.swift`), `SourceRegistry`, `SourceMarker` (SwiftUI), `Inspection` (capture, hit-testing, hierarchy and navigation context), `Overlay` (pass-through window, floating button, picker), `ConnectionManager`, `InspectorModel` and `InspectorViews` (SwiftUI sheets).
- `Mac/Sources/ScreenBridgeMacCore`: `Store` (home, identity, projects, credentials, heartbeat), `Git` (fingerprints, snapshots, `SourceConsistency`), `SourceAccess` (confinement, `CandidateFinder`), `ReportStore`, `ReceiverService`, `BuildIntegration`, `MCPServer`, `CLI`.
- `Mac/App`: SwiftUI menu-bar app. A single binary acts as the app, `cli`, or `mcp` depending on its first argument.

Element picking uses UIKit `hitTest` to skip transparent pass-through containers (such as the floating tab bar host), then searches inside the hit view for non-interactive children like labels. SwiftUI markers win when they're at least as specific as the UIKit view under the finger.

Source consistency has four states. `exactMatch` means the same commit and an identical working-tree fingerprint (the build may have been dirty). `sameCommitWorkingTreeChanged`, `differentCommit` and `unknown` cover the rest. There are also per-anchor file states: `unchanged`, `changedSinceBuild`, `missing` or `unknown`, from comparing git blob hashes recorded at build time with the current working tree.

## Building and testing

```bash
./Scripts/test-all.sh
```

Or run each part separately:

```bash
swift test
```

```bash
cd Mac && swift build && swift test
```

```bash
xcodebuild test -scheme ScreenBridge-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ScreenBridgeTests
```

The example app and its Release-archive check (`verify-release.sh`) live in [ScreenBridgeDemo](https://github.com/MachangDoniel/ScreenBridgeDemo). To develop the framework against the demo, point the demo's package reference at your local checkout (see the demo README).

The helper project is generated with xcodegen:

```bash
cd Mac/App && xcodegen generate && open ScreenBridgeHelper.xcodeproj
```

Set `SCREENBRIDGE_HOME=/tmp/sb-home` to run a CLI, MCP server or helper against an isolated store.

## Test coverage

| Area | Tests |
|---|---|
| Schema | Round-trip, newer minor version with unknown fields, older report without optional fields, incompatible major version rejected, malformed or missing version, path-like report IDs rejected, path relativization never exports absolute paths |
| Framing | Chunked decode, oversized headers, mismatched parts |
| Annotation and redaction | Redacted pixels destroyed in both variants (noise image, fractional rects), markup only in the annotated variant, top-left coordinates, no capture metadata, clamping, aspect-fit mapping round trip, downscaling |
| Logs | Secrets, emails and long digit runs removed; ordinary text preserved; ring buffer bounded |
| Transport (real TLS on loopback) | Report delivery and duplicate ack, wrong key, revoked credential after restart, hello addressed to another receiver, ack from an impostor receiver, Bonjour TXT matching |
| Outbox | Exponential bounded backoff, retry until ack, duplicate ack clears, mismatched ack doesn't clear, idempotent enqueue, capacity, expiry |
| Registry (macOS and iOS simulator) | Type lookup through superclasses, instance overwrite, stale registration after reuse, container deallocation, no retention, anchor provenance; real `UITableView` reuse on the simulator |
| Mac | Path confinement (traversal, absolute, `~`, symlink file and directory escapes, sibling-prefix trick, symlinked root, binary, line ranges); git consistency (dirty build exact match, working-tree change, new commit, deleted file, untracked files); report store (dedup, tampered or extra or missing parts, retention); build phase (git root, Debug only, credential reuse and revocation, 0600 permissions, never fails); end-to-end receiver over TLS (store, dedup, consistency at receipt, reveal confinement, foreign bundle, foreign receiver, revocation); MCP (version negotiation, tools list, decodable image content, report and source tools, traversal error, resources, the stdio binary itself) |
