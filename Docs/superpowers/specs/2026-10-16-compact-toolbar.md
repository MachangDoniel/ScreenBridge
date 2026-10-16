# Compact developer toolbar

User-directed revision: remove the overlay title/status/hint/selection-card sections. Show only tools: Select, Area, Pen, Ellipse, Rectangle, Arrow, Redact, Undo, Colors, More, Send and Hide. A dedicated grip drags the palette and snaps it to the nearest safe-area corner. Keep a small reopen button after Hide, preserving annotations and selection. Put properties, parent selection, source and log details in More. The normal debug icon remains available after ending the inspection from More.

Use a compact two-row grid, 44-point tool targets, short labels, native material, blue selected state, and a color row only when requested. Store the chosen corner between inspections and clamp dragging within safe bounds. No visible instructional text on the overlay.

Claude chat deep links accept prompt text only. Preserve the MCP handoff and add an explicit Copy screenshot action to the Mac report preparation sheet; it writes the annotated image to the clipboard for pasting into Claude. Do not use UI automation or silently request Accessibility permissions to inject attachments. This does not enable the still-unapproved persistent Claude MCP configuration.

Verification: simulator drag to bottom and top corners; no visible hints; Hide/reopen preserves inspection; More contains properties/logs; drawing and color selection; report delivery acknowledgement; compile Mac screenshot-copy action. Existing protocol and release stripping remain unchanged.

Verified: focused simulator UI tests passed for drawing/colors/logs/report controls and dragging, corner snapping, Hide/reopen, properties in More, area selection and acknowledged Mac delivery. The first drag regression failed in local gesture coordinates and passed after using a stable named coordinate space. Mac helper built and installed successfully with Copy screenshot. Screenshot: `Docs/images/09-compact-tools.png`.
