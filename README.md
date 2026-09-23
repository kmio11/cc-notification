# cc-notification — Windows Desktop Notifications for Claude Code

A PowerShell-based plugin that displays Claude Code notifications as Windows desktop toasts.
Integrates with Claude Code's `Notification`, `Stop`, and `PermissionRequest` hook events to provide native Windows notifications with click-to-focus support.

## Files

- `scripts/toast-notification.ps1` - PowerShell script that displays Windows notifications with fallback chain
- `scripts/focus-handler.ps1` - Protocol handler that focuses the terminal window on notification click
- `scripts/register-protocol.ps1` - One-time setup to register the `claude-notify://` protocol
- `scripts/launch-hidden.vbs` - VBScript wrapper to launch the focus handler without a visible window
- `.claude-plugin/plugin.json` - Claude Code plugin manifest
- `hooks/hooks.json` - Hook definitions for Notification, Stop, and PermissionRequest events

## Requirements

- Windows 10 or later
- PowerShell execution permissions
- Windows Runtime API (for toast notifications)
- System.Windows.Forms (.NET Framework)

## Installation

### Option 1: Claude Code Plugin (Recommended)

Install as a plugin using the Claude Code CLI:

```bash
# Add this repo as a marketplace
claude plugin marketplace add kmio11/cc-notification

# Install the plugin
claude plugin install cc-notification
```

The plugin automatically registers `Notification`, `Stop`, and `PermissionRequest` hooks — no manual configuration needed.

### Option 2: Manual Hook Configuration

If you prefer manual setup, add to your Claude Code settings file (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"/path/to/scripts/toast-notification.ps1\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"/path/to/scripts/toast-notification.ps1\""
          }
        ]
      }
    ]
  }
}
```

Refer to the [Claude Code hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks) for more details.

## Setup

### Click-to-Focus (Optional)

To make notifications clickable (clicking brings your terminal to the foreground), run the protocol registration script once after installation:

```powershell
# If installed as a plugin, find the plugin path first:
# Default: ~/.claude/plugins/marketplaces/<marketplace>/plugins/cc-notification/scripts/
powershell.exe -ExecutionPolicy Bypass -File "path/to/scripts/register-protocol.ps1"
```

This registers a `claude-notify://` protocol handler in your user registry (no admin required). The first time you click a notification, Windows may ask you to confirm the handler — check "Always" to skip the prompt in the future.

If the protocol is not registered, notifications still work normally — they just won't be clickable.

## Usage

### Direct Execution and Testing

**Input Priority**: JsonInput → Stdin → Default
**Override Rule**: Title/Message parameters force override regardless of input source

```bash
# Default notification (lowest priority)
powershell.exe -File "/path/to/toast-notification.ps1"

# Manual JSON input (highest priority)
powershell.exe -File "/path/to/toast-notification.ps1" -JsonInput '{"title":"Test","message":"JSON test"}'

# Stdin input (Claude Code hook simulation)
echo '{"hook_event_name":"Notification","message":"Hook message"}' | powershell.exe -File "/path/to/toast-notification.ps1"

# Force override examples
# Override Stop hook message
echo '{"hook_event_name":"Stop","stop_hook_active":false}' | powershell.exe -File "/path/to/toast-notification.ps1" -Message "Custom Complete Message"

# Override title only (keep parsed message)
echo '{"hook_event_name":"Notification","title":"Original","message":"Keep this"}' | powershell.exe -File "/path/to/toast-notification.ps1" -Title "My App"
```

## How It Works

The script uses a robust fallback chain to ensure reliable notification delivery:

### 1. Primary Method: Windows Toast Notifications
- Uses Windows Runtime API with `cc-notification` AppID
- Appears in Windows Action Center with modern toast styling
- Persistent in Action Center until dismissed

### 2. Fallback Method: Balloon Tip Notifications
- Traditional balloon notifications from system tray
- Appears in bottom-right corner for 5 seconds
- Used when toast notifications fail

### Click-to-Focus

When the protocol handler is registered:
1. On hook trigger, the script walks the process tree to find the parent terminal (Windows Terminal, VS Code, etc.)
2. The toast notification includes a `claude-notify://focus?pid=<terminal-pid>` protocol URI
3. Clicking the notification launches the focus handler, which brings the terminal window to the foreground using Win32 `SetForegroundWindow`
