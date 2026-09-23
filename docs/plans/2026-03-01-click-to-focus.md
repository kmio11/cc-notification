# Click-to-Focus Toast Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make toast notifications clickable so they bring the originating terminal window to the foreground.

**Architecture:** When the hook fires, walk the process tree to find the parent terminal (Windows Terminal, VS Code, etc.) and capture its PID. Build toast XML with `activationType="protocol"` pointing to a custom `claude-notify://focus?pid=XXXX` URI. A one-time registered protocol handler script receives the click and uses Win32 `SetForegroundWindow` (with `AttachThreadInput` trick) to focus the terminal.

**Tech Stack:** PowerShell, Windows Runtime API (toast notifications), Win32 API (SetForegroundWindow, AttachThreadInput), Windows Registry (protocol handler)

---

### Task 1: Create the focus handler script

**Files:**
- Create: `scripts/focus-handler.ps1`

**Step 1: Write `scripts/focus-handler.ps1`**

This script is invoked by Windows when the user clicks a toast notification. Windows passes the protocol URI as the first argument (e.g., `claude-notify://focus?pid=12345`). The script parses the PID, finds the process, and brings its window to the foreground.

```powershell
# Focus handler for claude-notify:// protocol
# Invoked by Windows when a toast notification is clicked
# Usage: focus-handler.ps1 "claude-notify://focus?pid=12345"

param([string]$Uri)

# Parse the URI to extract the PID
$TargetPid = $null
if ($Uri -match '[?&]pid=(\d+)') {
    $TargetPid = [int]$Matches[1]
}

if (-not $TargetPid) {
    exit 1
}

# Load Win32 interop for window management
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WindowFocusHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    public const int SW_RESTORE = 9;

    public static bool ForceForeground(IntPtr targetHwnd) {
        IntPtr foregroundHwnd = GetForegroundWindow();
        if (foregroundHwnd == targetHwnd) return true;

        uint foregroundThreadId;
        GetWindowThreadProcessId(foregroundHwnd, out foregroundThreadId);
        uint currentThreadId = GetCurrentThreadId();

        if (foregroundThreadId != currentThreadId) {
            AttachThreadInput(currentThreadId, foregroundThreadId, true);
        }

        if (IsIconic(targetHwnd)) {
            ShowWindow(targetHwnd, SW_RESTORE);
        }

        bool result = SetForegroundWindow(targetHwnd);

        if (foregroundThreadId != currentThreadId) {
            AttachThreadInput(currentThreadId, foregroundThreadId, false);
        }

        return result;
    }
}
"@

# Find the process and focus its window
$proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
if (-not $proc -or $proc.MainWindowHandle -eq [IntPtr]::Zero) {
    exit 1
}

[WindowFocusHelper]::ForceForeground($proc.MainWindowHandle) | Out-Null
exit 0
```

**Step 2: Verify the script parses URIs correctly**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "& { param([string]$Uri); if ($Uri -match '[?&]pid=(\d+)') { Write-Host 'Parsed PID:' $Matches[1] } else { Write-Host 'FAIL' } }" "claude-notify://focus?pid=12345"`
Expected: `Parsed PID: 12345`

**Step 3: Commit**

```bash
git add scripts/focus-handler.ps1
git commit -m "feat: add focus handler script for toast click-to-focus"
```

---

### Task 2: Create the protocol registration script

**Files:**
- Create: `scripts/register-protocol.ps1`

**Step 1: Write `scripts/register-protocol.ps1`**

One-time setup script that registers `claude-notify://` as a protocol handler in the current user's registry. Points to `focus-handler.ps1` in the same directory.

```powershell
# Registers the claude-notify:// protocol handler in the Windows registry
# Run once after installing the plugin: powershell.exe -ExecutionPolicy Bypass -File register-protocol.ps1
# Requires no elevation (writes to HKCU only)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HandlerScript = Join-Path $ScriptDir "focus-handler.ps1"

if (-not (Test-Path $HandlerScript)) {
    Write-Host "Error: focus-handler.ps1 not found at $HandlerScript"
    exit 1
}

$ProtocolName = "claude-notify"
$RegPath = "HKCU:\Software\Classes\$ProtocolName"

# Create protocol key
New-Item -Path $RegPath -Force | Out-Null
Set-ItemProperty -Path $RegPath -Name "(Default)" -Value "URL:Claude Code Notification Protocol"
Set-ItemProperty -Path $RegPath -Name "URL Protocol" -Value ""

# Default icon
New-Item -Path "$RegPath\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$RegPath\DefaultIcon" -Name "(Default)" -Value "powershell.exe,0"

# Shell open command — launches focus-handler.ps1 with the URI
New-Item -Path "$RegPath\shell\open\command" -Force | Out-Null
$Command = "`"powershell.exe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HandlerScript`" `"%1`""
Set-ItemProperty -Path "$RegPath\shell\open\command" -Name "(Default)" -Value $Command

Write-Host "Protocol 'claude-notify://' registered successfully."
Write-Host "Handler: $HandlerScript"
Write-Host ""
Write-Host "You can test it by running:"
Write-Host "  Start-Process 'claude-notify://focus?pid=$PID'"
```

**Step 2: Verify it runs without errors (dry-read the registry path)**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "Test-Path 'HKCU:\Software\Classes\claude-notify'"`
Expected: `False` (not registered yet — we'll register during end-to-end testing)

**Step 3: Commit**

```bash
git add scripts/register-protocol.ps1
git commit -m "feat: add one-time protocol registration script"
```

---

### Task 3: Add process tree walking to toast-notification.ps1

**Files:**
- Modify: `scripts/toast-notification.ps1` (add new function after `Send-BalloonNotification`, before `Parse-ClaudeCodeHookInput`)

**Step 1: Add `Find-ParentTerminal` function**

Insert after the `Send-BalloonNotification` function (after line 102) and before the `Parse-ClaudeCodeHookInput` function (line 104):

```powershell
# Walks up the process tree from the current process to find the parent terminal window
# Checks for Windows Terminal, VS Code, ConHost, and standalone PowerShell windows
# Returns: Hashtable with ProcessId, ProcessName, MainWindowHandle, or $null if not found
function Find-ParentTerminal {
    $TerminalProcessNames = @(
        "WindowsTerminal"
        "Code"
        "conhost"
    )

    $CurrentPid = $PID
    $Visited = @{}

    while ($CurrentPid -and $CurrentPid -ne 0 -and -not $Visited.ContainsKey($CurrentPid)) {
        $Visited[$CurrentPid] = $true

        $Proc = Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
        if (-not $Proc) { break }

        if ($Proc.MainWindowHandle -ne [IntPtr]::Zero -and
            $TerminalProcessNames -contains $Proc.ProcessName) {
            Write-DebugLog "Found parent terminal: $($Proc.ProcessName) (PID $($Proc.Id))"
            return @{
                ProcessId = $Proc.Id
                ProcessName = $Proc.ProcessName
                MainWindowHandle = $Proc.MainWindowHandle
            }
        }

        # Get parent PID via CIM
        $CimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $CurrentPid" -ErrorAction SilentlyContinue
        if (-not $CimProc) { break }

        $CurrentPid = $CimProc.ParentProcessId
    }

    Write-DebugLog "No parent terminal found in process tree"
    return $null
}
```

**Step 2: Verify the function runs without errors**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "function Find-ParentTerminal { $CurrentPid = $PID; $Proc = Get-Process -Id $CurrentPid; Write-Host 'Current process:' $Proc.ProcessName '(PID' $Proc.Id ')' }; Find-ParentTerminal"`
Expected: Shows current PowerShell process info without errors.

**Step 3: Commit**

```bash
git add scripts/toast-notification.ps1
git commit -m "feat: add process tree walking to find parent terminal"
```

---

### Task 4: Replace Send-ToastNotification with protocol-aware version

**Files:**
- Modify: `scripts/toast-notification.ps1` (replace `Send-ToastNotification` function, lines 44-72)

**Step 1: Check if protocol is registered**

Add this helper function right before `Send-ToastNotification` (before line 44):

```powershell
# Checks if the claude-notify:// protocol handler is registered
# Returns: $true if registered, $false otherwise
function Test-ProtocolRegistered {
    return Test-Path "HKCU:\Software\Classes\claude-notify\shell\open\command"
}
```

**Step 2: Replace the `Send-ToastNotification` function (lines 44-72)**

Replace the entire function with this version that uses custom toast XML with protocol activation:

```powershell
# Sends a Windows toast notification using Windows Runtime API
# If the claude-notify:// protocol is registered and a terminal PID is provided,
# the notification becomes clickable and will focus the terminal on click.
# Parameters:
#   $Title      - Notification title text
#   $Message    - Notification message text
#   $TerminalPid - (Optional) PID of the parent terminal for click-to-focus
# Returns: $true if successful, $false if failed
function Send-ToastNotification {
    param(
        [string]$Title,
        [string]$Message,
        [int]$TerminalPid = 0
    )

    try {
        # Determine if click-to-focus is available
        $ProtocolRegistered = Test-ProtocolRegistered
        $CanFocus = $ProtocolRegistered -and $TerminalPid -gt 0

        # Escape XML special characters in title and message
        $EscTitle = [System.Security.SecurityElement]::Escape($Title)
        $EscMessage = [System.Security.SecurityElement]::Escape($Message)

        if ($CanFocus) {
            $LaunchUri = "claude-notify://focus?pid=$TerminalPid"

            $ToastXml = @"
<toast activationType="protocol" launch="$LaunchUri">
  <visual>
    <binding template="ToastGeneric">
      <text>$EscTitle</text>
      <text>$EscMessage</text>
    </binding>
  </visual>
</toast>
"@
            Write-DebugLog "Using protocol activation: $LaunchUri"
        } else {
            $ToastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$EscTitle</text>
      <text>$EscMessage</text>
    </binding>
  </visual>
</toast>
"@
            if (-not $ProtocolRegistered) {
                Write-DebugLog "Protocol not registered - toast will not be clickable. Run register-protocol.ps1 to enable click-to-focus."
            }
        }

        $XmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]::new()
        $XmlDoc.LoadXml($ToastXml)

        $AppId = "Anthropic.ClaudeCode"
        $Notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier($AppId)
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($XmlDoc)
        $Notifier.Show($Toast)

        $FocusStatus = if ($CanFocus) { " (click to focus terminal)" } else { "" }
        Write-Host "Toast notification sent$FocusStatus"
        return $true
    }
    catch {
        Write-Host "Toast notification failed: $($_.Exception.Message)"
        return $false
    }
}
```

**Step 3: Update the main notification flow (bottom of script, lines 265-285)**

Replace the final section that calls `Send-ToastNotification` to pass the terminal PID:

```powershell
# Find the parent terminal for click-to-focus
$Terminal = Find-ParentTerminal
$TerminalPid = if ($Terminal) { $Terminal.ProcessId } else { 0 }

# Main notification flow with clear fallback chain
Write-DebugLog "Final notification - Title: '$FinalTitle', Message: '$FinalMessage', TerminalPID: $TerminalPid"

# Try Toast notification first (primary method)
if (Send-ToastNotification -Title $FinalTitle -Message $FinalMessage -TerminalPid $TerminalPid) {
    Write-DebugLog "Toast notification succeeded"
    exit 0
}

Write-Host "Falling back to balloon notification..."
Write-DebugLog "Toast failed, trying balloon notification"

# Try Balloon notification (fallback method)
if (Send-BalloonNotification -Title $FinalTitle -Message $FinalMessage) {
    Write-DebugLog "Balloon notification succeeded"
    exit 0
}

# All methods failed
Write-Host "All notification methods failed"
Write-DebugLog "All notification methods failed"
exit 1
```

**Step 4: Verify the modified script has no syntax errors**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "& { $ErrorActionPreference='Stop'; . 'cc-notification/scripts/toast-notification.ps1' -JsonInput '{\"title\":\"Test\",\"message\":\"Syntax check\"}' }" 2>&1 | head -5`
Expected: Toast notification fires without parse errors.

**Step 5: Commit**

```bash
git add scripts/toast-notification.ps1
git commit -m "feat: replace toast with protocol-aware click-to-focus version"
```

---

### Task 5: Update README.md

**Files:**
- Modify: `README.md`

**Step 1: Add click-to-focus setup section**

Add a new "## Setup" section after "## Installation" and before "## Usage":

```markdown
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
```

**Step 2: Update the "How It Works" section**

Append click-to-focus explanation after the existing fallback chain description:

```markdown
### Click-to-Focus

When the protocol handler is registered:
1. On hook trigger, the script walks the process tree to find the parent terminal (Windows Terminal, VS Code, etc.)
2. The toast notification includes a `claude-notify://focus?pid=<terminal-pid>` protocol URI
3. Clicking the notification launches the focus handler, which brings the terminal window to the foreground using Win32 `SetForegroundWindow`
```

**Step 3: Update the Files list**

Add new files to the Files section:

```markdown
- `scripts/focus-handler.ps1` - Protocol handler that focuses the terminal window on notification click
- `scripts/register-protocol.ps1` - One-time setup to register the `claude-notify://` protocol
```

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add click-to-focus setup instructions"
```

---

### Task 6: End-to-end verification

**Step 1: Register the protocol handler**

Run: `powershell.exe -ExecutionPolicy Bypass -File "cc-notification/scripts/register-protocol.ps1"`
Expected: `Protocol 'claude-notify://' registered successfully.`

**Step 2: Verify protocol registration**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "Get-ItemProperty 'HKCU:\Software\Classes\claude-notify\shell\open\command' | Select-Object -ExpandProperty '(Default)'"`
Expected: Shows the command pointing to `focus-handler.ps1`

**Step 3: Test the focus handler directly**

Run: `powershell.exe -ExecutionPolicy Bypass -File "cc-notification/scripts/focus-handler.ps1" "claude-notify://focus?pid=$((Get-Process -Name powershell | Select-Object -First 1).Id)"`
Expected: Script exits without error (may focus a PowerShell window)

**Step 4: Test the full notification with click-to-focus**

Run: `powershell.exe -ExecutionPolicy Bypass -File "cc-notification/scripts/toast-notification.ps1" -JsonInput '{"hook_event_name":"Notification","message":"Click me to focus terminal"}' -DebugLogPath "C:\temp\cc-notify-debug.log"`
Expected: Toast notification appears. Check debug log for `Using protocol activation: claude-notify://focus?pid=XXXX`

**Step 5: Test non-clickable fallback (without protocol)**

Run: `powershell.exe -ExecutionPolicy Bypass -Command "Remove-Item 'HKCU:\Software\Classes\claude-notify' -Recurse -Force"`
Then: `powershell.exe -ExecutionPolicy Bypass -File "cc-notification/scripts/toast-notification.ps1" -JsonInput '{"hook_event_name":"Notification","message":"Non-clickable test"}' -DebugLogPath "C:\temp\cc-notify-debug.log"`
Expected: Toast still fires. Debug log shows `Protocol not registered - toast will not be clickable`

**Step 6: Re-register protocol for normal use**

Run: `powershell.exe -ExecutionPolicy Bypass -File "cc-notification/scripts/register-protocol.ps1"`

---

### Task 7: Push and update the PR

**Step 1: Push to the fork**

```bash
git push origin feat/plugin-manifest
```

**Step 2: Verify the PR is updated**

Run: `gh pr view 2 --repo kmio11/cc-notification`
Expected: PR shows the new commits.
