# Rich Permission Toast Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a rich toast notification when Claude Code asks for permission, displaying the tool name and command preview. Clicking the toast focuses the correct terminal tab.

**Architecture:** Add `PermissionRequest` hook to `hooks.json` (same script). Extend `Parse-ClaudeCodeHookInput` with a new case that extracts tool name + command preview. Add optional third text line to `Send-ToastNotification`. No changes to `focus-handler.ps1`.

**Tech Stack:** PowerShell, Windows Runtime API (toast), existing click-to-focus infrastructure

**Design doc:** `docs/plans/2026-03-01-permission-toast-design.md`

---

### Task 1: Add PermissionRequest hook to hooks.json

**Files:**
- Modify: `hooks/hooks.json`

**Step 1: Add the PermissionRequest entry**

Add a `PermissionRequest` key alongside the existing `Notification` and `Stop` keys. Same command, same timeout.

Replace the entire file with:

```json
{
  "description": "Windows desktop notifications for Claude Code events including permission requests",
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/scripts/toast-notification.ps1\"",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/scripts/toast-notification.ps1\"",
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell.exe -ExecutionPolicy Bypass -File \"${CLAUDE_PLUGIN_ROOT}/scripts/toast-notification.ps1\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

**Step 2: Verify JSON is valid**

Run: `pwsh -NoProfile -Command "Get-Content 'cc-notification/hooks/hooks.json' | ConvertFrom-Json | ConvertTo-Json -Depth 5"`
Expected: Outputs the JSON without errors. Should show three hook event keys.

**Step 3: Commit**

```bash
git -C cc-notification add hooks/hooks.json
git -C cc-notification commit -m "feat: add PermissionRequest hook for rich permission toasts"
```

---

### Task 2: Add command preview extraction helper

**Files:**
- Modify: `scripts/toast-notification.ps1` (add function after `Find-ParentTerminal`, before `Parse-ClaudeCodeHookInput`)

**Step 1: Add `Get-ToolPreview` function**

Insert after the closing `}` of `Find-ParentTerminal` (after line 210) and before the comment block for `Parse-ClaudeCodeHookInput` (line 212):

```powershell
# Extracts a human-readable command preview from a PermissionRequest's tool_input
# Parameters:
#   $ToolName  - The tool being requested (e.g., "Bash", "Write", "Edit")
#   $ToolInput - The tool_input object from the hook JSON
# Returns: A preview string truncated to ~120 characters
function Get-ToolPreview {
    param(
        [string]$ToolName,
        [object]$ToolInput
    )

    $Preview = ""

    if (-not $ToolInput) {
        return $ToolName
    }

    switch ($ToolName) {
        "Bash" {
            if ($ToolInput.command) {
                $Preview = $ToolInput.command
            }
        }
        "Write" {
            if ($ToolInput.file_path) {
                $Preview = $ToolInput.file_path
            }
        }
        "Edit" {
            if ($ToolInput.file_path) {
                $Preview = $ToolInput.file_path
            }
        }
        default {
            # For other tools, try common field names
            if ($ToolInput.file_path) {
                $Preview = $ToolInput.file_path
            } elseif ($ToolInput.path) {
                $Preview = $ToolInput.path
            } elseif ($ToolInput.url) {
                $Preview = $ToolInput.url
            }
        }
    }

    if ($Preview -eq "") {
        return $ToolName
    }

    # Truncate long previews
    if ($Preview.Length -gt 120) {
        $Preview = $Preview.Substring(0, 117) + "..."
    }

    return $Preview
}
```

**Step 2: Verify the function works in isolation**

Run:
```
pwsh -NoProfile -Command "
function Get-ToolPreview { param([string]`$ToolName, [object]`$ToolInput); if (-not `$ToolInput) { return `$ToolName }; switch (`$ToolName) { 'Bash' { if (`$ToolInput.command) { `$p = `$ToolInput.command } } 'Write' { if (`$ToolInput.file_path) { `$p = `$ToolInput.file_path } } default { `$p = '' } }; if (`$p.Length -gt 120) { `$p = `$p.Substring(0,117) + '...' }; if (`$p) { `$p } else { `$ToolName } }
Get-ToolPreview -ToolName 'Bash' -ToolInput ([PSCustomObject]@{command='git push origin main'})
Get-ToolPreview -ToolName 'Write' -ToolInput ([PSCustomObject]@{file_path='src/app.ts'})
Get-ToolPreview -ToolName 'Agent' -ToolInput `$null
"
```

Expected:
```
git push origin main
src/app.ts
Agent
```

**Step 3: Commit**

```bash
git -C cc-notification add scripts/toast-notification.ps1
git -C cc-notification commit -m "feat: add Get-ToolPreview helper for command preview extraction"
```

---

### Task 3: Add PermissionRequest case to Parse-ClaudeCodeHookInput

**Files:**
- Modify: `scripts/toast-notification.ps1` (add case in `switch` block inside `Parse-ClaudeCodeHookInput`)

**Step 1: Add PermissionRequest case to the switch statement**

In `Parse-ClaudeCodeHookInput`, find the `switch ($EventName)` block (line 241). Add the `"PermissionRequest"` case between the `"Stop"` case (ends around line 258) and the `default` case (line 260):

```powershell
                    "PermissionRequest" {
                        $HookType = "PermissionRequest"
                        $ToolName = if ($HookData.tool_name) { $HookData.tool_name } else { "Tool" }
                        $Preview = Get-ToolPreview -ToolName $ToolName -ToolInput $HookData.tool_input

                        $ParsedTitle = [char]0x1F512 + " Permission Required"
                        $ParsedMessage = $ToolName
                        $ParsedDetail = $Preview

                        Write-DebugLog "Detected $EventName hook - Tool: '$ToolName', Preview: '$Preview'"
                    }
```

**Step 2: Add `Detail` field to both return hashtables**

Find the return hashtable inside the `try` block (line 290). Add `Detail = $ParsedDetail`:

```powershell
            return @{
                Title = $ParsedTitle
                Message = $ParsedMessage
                Detail = $ParsedDetail
                HookType = $HookType
                SessionId = $HookData.session_id
                TranscriptPath = $HookData.transcript_path
                StopHookActive = $HookData.stop_hook_active
            }
```

Also update the defaults return hashtable at the bottom of the function (line 306):

```powershell
    return @{
        Title = $ParsedTitle
        Message = $ParsedMessage
        Detail = $null
        HookType = $HookType
        SessionId = $null
        TranscriptPath = $null
        StopHookActive = $null
    }
```

**Step 3: Initialize `$ParsedDetail` with the other defaults**

At the top of `Parse-ClaudeCodeHookInput`, after line 226 (`$HookType = "Unknown"`), add:

```powershell
    $ParsedDetail = $null
```

**Step 4: Verify PermissionRequest JSON parses correctly**

Run:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push origin main"},"session_id":"test123"}' -DebugLogPath "$env:TEMP/cc-perm-test.log" 2>&1; Get-Content "$env:TEMP/cc-perm-test.log" | Select-String "PermissionRequest|Permission Required|Tool:|Preview:"
```

Expected: Debug log lines showing `Detected PermissionRequest hook`, the tool name, and the preview.

**Step 5: Commit**

```bash
git -C cc-notification add scripts/toast-notification.ps1
git -C cc-notification commit -m "feat: parse PermissionRequest events with tool name and command preview"
```

---

### Task 4: Add third text line to Send-ToastNotification

**Files:**
- Modify: `scripts/toast-notification.ps1` (modify `Send-ToastNotification` function and the main flow)

**Step 1: Add `$Detail` parameter to `Send-ToastNotification`**

In the `param` block of `Send-ToastNotification` (line 59-63), add `$Detail`:

```powershell
    param(
        [string]$Title,
        [string]$Message,
        [string]$Detail = "",
        [int]$TerminalPid = 0
    )
```

**Step 2: Add the third `<text>` element to the toast XML**

After the line `$EscMessage = [System.Security.SecurityElement]::Escape($Message)` (line 72), add:

```powershell
        $DetailXml = ""
        if ($Detail -ne "") {
            $EscDetail = [System.Security.SecurityElement]::Escape($Detail)
            $DetailXml = "`n      <text>$EscDetail</text>"
        }
```

Then in both toast XML templates (the `$CanFocus` branch and the `else` branch), change:

```xml
      <text>$EscMessage</text>
```

to:

```xml
      <text>$EscMessage</text>$DetailXml
```

The `$CanFocus` toast XML (line 78-87) becomes:

```powershell
            $ToastXml = @"
<toast activationType="protocol" launch="$EscLaunchUri">
  <visual>
    <binding template="ToastGeneric">
      <text>$EscTitle</text>
      <text>$EscMessage</text>$DetailXml
    </binding>
  </visual>
</toast>
"@
```

The non-clickable toast XML (line 90-99) becomes:

```powershell
            $ToastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$EscTitle</text>
      <text>$EscMessage</text>$DetailXml
    </binding>
  </visual>
</toast>
"@
```

**Step 3: Pass `Detail` through in the main flow**

After the `$FinalMessage` assignments in the three input-priority branches (lines 338-356), add `$FinalDetail` extraction. After line 343 (`$FinalMessage = $NotificationInfo.Message`) in the JsonInput branch, add:

```powershell
    $FinalDetail = $NotificationInfo.Detail
```

Add the same line after line 349 in the stdin branch, and set `$FinalDetail = $null` in the default branch.

Then update the `Send-ToastNotification` call (line 382) to pass the detail:

```powershell
if (Send-ToastNotification -Title $FinalTitle -Message $FinalMessage -Detail $FinalDetail -TerminalPid $TerminalPid) {
```

**Step 4: Verify the full flow with a PermissionRequest JSON**

Run:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' -DebugLogPath "$env:TEMP/cc-perm-test.log" 2>&1; Get-Content "$env:TEMP/cc-perm-test.log"
```

Expected: Debug log shows the permission request was parsed and the toast was attempted. On systems where WinRT is available, a toast notification appears with three lines of text.

**Step 5: Verify existing Notification events still work (no regression)**

Run:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"Notification","message":"Task completed"}' -DebugLogPath "$env:TEMP/cc-notif-test.log" 2>&1; Get-Content "$env:TEMP/cc-notif-test.log"
```

Expected: Notification toast fires as before (two text lines, no third line). Debug log shows `Detected Notification hook`.

**Step 6: Commit**

```bash
git -C cc-notification add scripts/toast-notification.ps1
git -C cc-notification commit -m "feat: support third text line in toasts for permission request details"
```

---

### Task 5: End-to-end verification

**Step 1: Test PermissionRequest with all tool types**

Bash:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/cache && echo done"}}' -DebugLogPath "$env:TEMP/cc-e2e.log"
```

Write:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"src/components/App.tsx","content":"..."}}' -DebugLogPath "$env:TEMP/cc-e2e.log"
```

Unknown tool:
```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}' -DebugLogPath "$env:TEMP/cc-e2e.log"
```

Expected: Each shows a toast with the tool name and appropriate preview. Check debug log for correct parsing.

**Step 2: Test long command truncation**

```
pwsh -NoProfile -File cc-notification/scripts/toast-notification.ps1 -JsonInput '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"find /var/log -name *.log -mtime +30 -exec gzip {} ; && find /var/log -name *.gz -mtime +90 -exec rm {} ; && echo cleanup complete && date"}}' -DebugLogPath "$env:TEMP/cc-e2e.log"
```

Expected: Debug log shows the preview truncated to ~120 chars with `...` suffix.

**Step 3: Test that clicking the toast focuses the correct terminal**

Fire a permission toast, alt-tab away, click the toast. Verify it focuses the Windows Terminal window and (when 1:1 mapping holds) selects the correct tab.

**Step 4: Verify hooks.json is loadable by Claude Code**

Run: `pwsh -NoProfile -Command "(Get-Content 'cc-notification/hooks/hooks.json' | ConvertFrom-Json).hooks.PSObject.Properties.Name"`

Expected output:
```
Notification
Stop
PermissionRequest
```
