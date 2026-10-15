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

The helper's **Prepare for Claude** button copies:

> Read ScreenBridge report SB-7F3A2C9104BE, inspect its screenshot and linked source, and propose a fix.

Paste it into Claude yourself. ScreenBridge can't inject messages into a conversation or start a model turn.

## Manual check

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_debug_reports","arguments":{}}}' \
 | "$HOME/Library/Application Support/ScreenBridge/bin/screenbridge-mcp"
```

The server works whether or not the helper app is running. It reads the store directly.
