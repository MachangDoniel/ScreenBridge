# ScreenBridge Debug Workspace Implementation Plan

**Goal:** Deliver a debug-only floating inspector with selectable report evidence and Claude Desktop, Code, browser, and inbox handoffs.

**Architecture:** Keep the existing authenticated report transport and outbox. Add optional protocol metadata and a native overlay workspace; perform Claude handoffs only on the Mac after report persistence.

**Tech Stack:** Swift 6, UIKit, SwiftUI, CoreGraphics, Network.framework, Swift Testing.

## Tasks

- [x] Protocol and export: add tests for optional destination, region, properties, rectangle rendering, backward compatibility, and evidence filtering. Implement optional fields, rectangle tool, report inclusion filtering. Run shared package tests.
- [x] Mac handoff: add tests for Desktop/Code URL encoding, browser portable content, safe source export and configuration merge. Implement ClaudeHandoff in Mac core and wire receiver-arrival actions and inbox buttons. Compile Mac helper and run Mac tests.
- [x] iOS workspace: add full-screen captured surface with floating top toolbar, element/region selection, colors, undo, selection summary and More. Preserve one model when opening sheets. Show live sanitized app logs and connection transitions. Build and test on simulator.
- [x] Integration: point demo to local package, preserve signing changes, build/install updated helper, provide explicit MCP setup (installation awaits user approval), test sending from simulator to receiver and opening report preparation without sending a Claude message.
- [x] Documentation and verification: update README/MCP instructions, run focused tests plus iOS Debug and Release builds, inspect Release stripping, review diff and report remaining device/Claude limitations.

## Verification record

- Shared protocol/transport suite: 25 passed.
- Mac suite: 26 passed, including handoff URLs, portable source confinement, configuration merge, and export retention.
- iOS unit suite: 12 passed, including secure text exclusion and prepared payload filtering.
- UI: logs, colors, drawing/undo, evidence options, toolbar move/collapse, object/area selection and Mac acknowledgement passed in three simulator tests, including the default Desktop handoff. All three passed together on the final run.
- Unsigned iOS Release archive: tooling, connection credentials and absolute source paths absent.
- Mac helper installed and running; doctor confirms listening receiver.
- Persistent Claude Desktop MCP configuration was blocked by automatic approval review; no configuration change was made. Explicit user approval is required to grant report/image/source access.
- Physical device networking and actual Claude model execution are outside the simulator checks. No model message is automatically submitted.

- Default destination end-to-end: report SB-B45117C0D080 acknowledged by Mac; Claude Desktop composer visibly contained the prepared report request. Left unsent. Remaining MCP configuration requires explicit approval.
