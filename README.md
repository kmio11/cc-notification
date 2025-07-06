# Claude Code Windows Notification Hook

A PowerShell script that displays Claude Code notifications as Windows desktop notifications from WSL.
Integrates with Claude Code's `Notification` and `Stop` hook system to provide native Windows notifications.

## Files

- `toast-notification.ps1` - PowerShell script that displays Windows notifications with fallback chain

## Requirements

- Windows 10 or later
- PowerShell execution permissions
- Windows Runtime API (for toast notifications)
- System.Windows.Forms (.NET Framework)

## Usage
### 1. Claude Code Notification Hook

The script is designed to work with Claude Code's `Notification` hook, which receives actual notification messages from Claude Code and displays them as Windows notifications.
Refer [Claude Code hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks) for more details.

Add to your Claude Code settings file:

**For Notification Hook Support:**

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"/path/to/toast-notification.ps1\""
          }
        ]
      }
    ]
  }
}
```

This will intercept all Claude Code notifications and display them as Windows toast notifications instead of (or in addition to) the default notification method.

**For Stop Hook Support:**

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"/path/to/cc-utils/toast-notification.ps1\""
          }
        ]
      }
    ]
  }
}
```

### 2. Direct Execution and Testing

**Input Priority**: JsonInput → Stdin → Default  
**Override Rule**: Title/Message parameters force override regardless of input source

```bash
# Default notification (lowest priority)
powershell.exe -File "/path/to/toast-notification.ps1"

# Manual JSON input (highest priority) 
powershell.exe -File "/path/to/toast-notification.ps1" -JsonInput '{"title":"Test","message":"JSON test"}'

# Stdin input (Claude Code hook simulation)
echo '{"hook_event_name":"Notification","title":"Claude Code","message":"Hook message"}' | powershell.exe -File "/path/to/toast-notification.ps1"

# Force override examples
# Override Stop hook message
echo '{"hook_event_name":"Stop","stop_hook_active":false}' | powershell.exe -File "/path/to/toast-notification.ps1" -Message "Custom Complete Message"

# Override title only (keep parsed message)
echo '{"hook_event_name":"Notification","title":"Original","message":"Keep this"}' | powershell.exe -File "/path/to/toast-notification.ps1" -Title "My App"
```

## How It Works

The script uses a robust fallback chain to ensure reliable notification delivery:

### 1. Primary Method: Windows Toast Notifications
- Uses Windows Runtime API with `Anthropic.ClaudeCode` AppID
- Appears in Windows Action Center with modern toast styling
- Persistent in Action Center until dismissed

### 2. Fallback Method: Balloon Tip Notifications
- Traditional balloon notifications from system tray
- Appears in bottom-right corner for 5 seconds
- Used when toast notifications fail