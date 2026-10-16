# ScreenBridge debug workspace

Approved direction: the floating icon opens a top floating toolbar for inspection and annotation. Claude Desktop is the default destination; Claude Code, browser, and Mac inbox are also available.

The workspace freezes a clean app screenshot, excluding ScreenBridge windows. Selection resolves the underlying UIKit view or registered SwiftUI marker at screenshot coordinates; object name, type, safe text/properties, frame, source anchors, and related registrations appear in the workspace and More sheet. Secure text fields are excluded. Area selection records screenshot pixel bounds. Drawing supports pen, rectangle, ellipse, arrow, opaque redaction, colors, and undo.

More retains the existing source, report preview, connection and retry screens and adds a live app-log viewer. The report composer independently controls logs, view details, source links, and screenshots. Device diagnostics and ScreenBridge.log are sanitized before both storage and console output. Xcode loader/system console output is not automatically available to the in-process log buffer.

Reports carry optional destination, selected region, and element properties. The authenticated Mac receiver persists and acknowledges the report before opening the requested Claude destination. Desktop and Code use documented prefilled deep links; Code receives the registered project folder. Browser uses a copied portable report prompt and opens Claude plus a local export folder for image attachment, because local MCP is unavailable in browser chat. No destination submits a model turn automatically. An ordinary Mac-inbox send does not open Claude. Retries of an acknowledged report do not open duplicate chats.

The Mac helper exposes all destinations for stored reports, an explicit MCP configuration installer that preserves existing entries, clear handoff results, and source/image export. The demo consumes the local framework during development and preserves the existing signing team. Debug UI/networking remains stripped from iOS Release builds.

Verification: protocol compatibility, annotation pixels/colors, report options, destination URLs and portable exports, Mac receiver storage/acknowledgement, iOS simulator build and interaction, and unsigned Release archive inspection. Actual physical-device discovery and Claude UI permissions may need user validation.
