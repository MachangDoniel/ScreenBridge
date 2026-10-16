# Claude integration (MCP)

`screenbridge-mcp` is a local, read-only MCP server over stdio (JSON-RPC 2.0, newline-delimited). It has no dependencies and supports protocol versions `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`, negotiated during `initialize`.

## Tools

| Tool | Returns |
|---|---|
| `list_debug_reports` (`limit`, `project`) | Recent reports: ID, time, project, element or screen, source consistency, description |
| `get_debug_report` (`report_id` or `"latest"`) | Summary plus full JSON: description, selected element, view hierarchy, screen and navigation context, registered anchors (repository-relative), unverified candidates, build metadata, **current** consistency against the working tree, annotations (vector coordinates), sanitized logs |
| `get_report_images` (`report_id`, `variant`: annotated, original or both, `max_dimension`, default 1568) | MCP `image` content blocks (base64 PNG) that the model can see, with a text caption noting redaction and scale |
| `read_related_source` (`path`, `report_id` or `project`, `start_line`, `end_line`) | Numbered lines from a file under the report's registered project root |

Resources are also exposed: `screenbridge://reports/{id}` (JSON) and `screenbridge://reports/{id}/annotated.png` (blob).

Source access is confined. Relative paths only, no `..`, no `~` or absolute paths, symlinks resolved with `realpath` on both the root and the target, and the target must be inside the root (with a separator check, so `repo2` doesn't match `repo`). Files are limited to 2 MB, text only, at most 400 lines per call.

The server never modifies anything. Code changes go through your normal Claude Code session and its repository permissions.

## Claude Desktop

1. Copy the configuration. Use the helper's **Connection › Copy Claude Desktop configuration**, or run:

   ```bash
   "$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" mcp-config
   ```
   This produces:
   ```json
   {
     "mcpServers": {
       "screenbridge": {
         "command": "/Users/you/Library/Application Support/ScreenBridge/bin/screenbridge-mcp",
         "args": []
       }
     }
   }
   ```
2. Merge the `screenbridge` entry into `~/Library/Application Support/Claude/claude_desktop_config.json`. Keep any servers you already have.
3. **Quit and reopen Claude Desktop.** It reads the configuration only at launch.
4. In a chat, check that the ScreenBridge tools appear in the tools menu.

The path contains a space. That's fine in JSON because Claude Desktop doesn't use a shell.

## Claude Code

```bash
claude mcp add screenbridge -- "$HOME/Library/Application Support/ScreenBridge/bin/screenbridge-mcp"
```

Start a new session (or `/mcp` to check status). Running Claude Code from the repository root lets it edit the files the report points to.

## Asking Claude

The helper's **Copy request** button copies a prompt such as:

> Read ScreenBridge report SB-7F3A2C9104BE, inspect its screenshot and linked source, and propose a fix.

Use **Prepare for Claude** to open a supported destination with a prepared prompt, or copy it into an existing chat. You review and send the prompt in Claude.

## Manual check

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_debug_reports","arguments":{}}}' \
 | "$HOME/Library/Application Support/ScreenBridge/bin/screenbridge-mcp"
```

The server works whether or not the helper app is running. It reads the store directly.

## Floating workspace and destinations

The Debug icon opens a compact floating tool palette on a frozen app screenshot. Select an object or drag an area, choose an annotation tool and color, drag the grip to any corner or Hide the palette, and use **More** for source, hierarchy, live app logs, and connection details. **Send to Claude** opens the report composer. Logs are opt-in; view details, source links, and screenshots can each be excluded before the report enters the device outbox.

- **Claude Desktop** (default): the Mac helper opens `claude://claude.ai/new?q=...` with a prepared report request. Configure the local ScreenBridge MCP server to let Claude read reports and screenshots. Review and send the prompt in Claude.
- **Claude Code**: opens `claude://code/new?q=...&folder=...` using the Mac's registered project root. Claude may ask you to confirm that folder. A local export is included as a fallback when MCP is not configured.
- **Claude in browser**: opens Claude and a local export folder. Paste the copied Markdown report and attach the PNG files. Browser chat cannot use the local stdio MCP server. The export contains only selected evidence, with bounded source excerpts read inside the registered repository.
- **Mac inbox only**: persists the report without opening Claude.

Install the current helper before using these options. Older helpers will not interpret destination metadata; rectangles remain readable as closed pen paths. Reports from older apps still load in the new helper. Retransmission of a report that is already stored does not open a second chat. If opening Claude fails, the saved report remains in the inbox and the request is copied.

Claude's supported Desktop and Code links are documented at [Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link). These prefill a composer; they do not submit a message or attach local image files by URL.

### Configure Desktop without replacing other servers

In the Mac helper choose **Connection → Configure Claude Desktop**, or run:

```bash
"$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" configure-claude
```

This explicitly merges the `screenbridge` entry into Claude Desktop's configuration and preserves unrelated servers and settings. Quit and reopen Claude Desktop afterward. The connector exposes stored debug reports, screenshots, and confined reads of registered project source. Configuration is a separate setup action; sending a report never silently edits Claude's configuration.

### Attaching an image to the Claude composer

Desktop chat links prefill the prompt only. In the Mac inbox open **Prepare for Claude → Copy screenshot**, then paste with **⌘V** in Claude to attach the annotated image directly. With the ScreenBridge MCP connector configured, Claude can instead retrieve screenshot image content using `get_report_images`. These are separate paths: a prepared report prompt is not itself an image attachment.
