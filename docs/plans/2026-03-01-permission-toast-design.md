# Rich Permission Toast Notifications

**Goal:** When Claude Code asks for permission to run a tool, show a toast notification with the tool name and command preview. Clicking the toast focuses the correct terminal tab so the user can approve/deny in context.

**Trigger:** `PermissionRequest` hook event — fires only when a permission dialog is about to be shown to the user.

## Architecture

```
PermissionRequest hook fires (stdin: tool_name, tool_input, pid info)
        │
        ▼
toast-notification.ps1 parses PermissionRequest event
        │
        ▼
Sends toast: "🔒 Permission Required" / "Bash" / "git push origin main"
        │
        ▼
Hook exits 0 (no output) → normal terminal prompt appears
        │
        ▼ (user clicks toast)
focus-handler.ps1 → focus window → select tab (existing behavior)
        │
        ▼
User sees the full permission prompt, types y/n manually
```

## Changes

### 1. `hooks/hooks.json` — Add PermissionRequest entry

New hook entry calling the same `toast-notification.ps1` script.

### 2. `scripts/toast-notification.ps1` — Handle PermissionRequest events

Extend `Parse-ClaudeCodeHookInput` to recognize `PermissionRequest` as a hook event name.

**Command preview extraction by tool type:**
- `Bash` → `tool_input.command` (truncated to ~120 characters)
- `Write` → `tool_input.file_path`
- `Edit` → `tool_input.file_path`
- Other tools → tool name only

**Toast content:**
- Title: `🔒 Permission Required`
- Line 1: Tool name (e.g., `Bash`)
- Line 2: Command preview (e.g., `git push origin main`)

### 3. `scripts/focus-handler.ps1` — No changes

Existing focus + tab selection handles the click-to-focus behavior.

## Design Decisions

- **Fire-and-forget:** The hook sends the toast and exits immediately. It does not try to answer the permission request itself. The terminal prompt is always the source of truth.
- **No action buttons:** Approving/denying from a toast risks sending the response to the wrong session or tab. The toast is an information + navigation aid only.
- **Same script:** Reuses `toast-notification.ps1` rather than a new script. The parser already handles multiple event types.
- **Click-to-focus reuse:** The existing `claude-notify://focus` protocol with `pid` and `shellpid` parameters handles window focus and tab selection.
