# Windows Notification Script for Claude Code
# Supports Claude Code hook integration, manual testing, and direct execution
# Priority order: JsonInput -> Stdin -> Default, with Title/Message force override

param(
    # Manual JSON input for testing/debugging (highest priority)
    # Example: -JsonInput '{"hook_event_name":"Notification","title":"cc-notification","message":"Task completed","session_id":"abc123","transcript_path":"/path"}'
    [string]$JsonInput = "",
    
    # Force override: Custom notification title (overrides parsed title if specified)
    # Works with any input source (stdin, JsonInput, or default)
    # Example: -Title "My Application"
    [string]$Title = "",
    
    # Force override: Custom notification message (overrides parsed message if specified)
    # Useful for customizing Stop hook messages or any other notification
    # Example: -Message "Custom completion message"
    [string]$Message = "",
    
    # Debug log file path (optional)
    # When specified, detailed debug information will be written to this file
    # Example: -DebugLogPath "C:\temp\notification-debug.log"
    [string]$DebugLogPath = ""
)

# Debug logging function - only logs when DebugLogPath is specified
function Write-DebugLog {
    param([string]$Message)
    
    # Only log if debug path is specified
    if ($DebugLogPath -ne "") {
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        
        # Ensure directory exists
        $LogDir = Split-Path $DebugLogPath -Parent
        if (!(Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        
        "$Timestamp - $Message" | Out-File -FilePath $DebugLogPath -Append -Encoding UTF8
    }
}

# Checks if the claude-notify:// protocol handler is registered
# Returns: $true if registered, $false otherwise
function Test-ProtocolRegistered {
    return Test-Path "HKCU:\Software\Classes\claude-notify\shell\open\command"
}

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
        [string]$Detail = "",
        [int]$TerminalPid = 0
    )

    try {
        # Determine if click-to-focus is available
        $ProtocolRegistered = Test-ProtocolRegistered
        $CanFocus = $ProtocolRegistered -and $TerminalPid -gt 0

        # Escape XML special characters in title and message
        $EscTitle = [System.Security.SecurityElement]::Escape($Title)
        $EscMessage = [System.Security.SecurityElement]::Escape($Message)

        $DetailXml = ""
        if ($Detail -ne "") {
            $EscDetail = [System.Security.SecurityElement]::Escape($Detail)
            $DetailXml = "`n      <text>$EscDetail</text>"
        }
        Write-DebugLog "Toast params - Detail: '$Detail', DetailXml: '$DetailXml'"

        if ($CanFocus) {
            $LaunchUri = "claude-notify://focus?pid=$TerminalPid&shellpid=$ShellPid"
            $EscLaunchUri = [System.Security.SecurityElement]::Escape($LaunchUri)

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
            Write-DebugLog "Using protocol activation: $LaunchUri"
        } else {
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
            if (-not $ProtocolRegistered) {
                Write-DebugLog "Protocol not registered - toast will not be clickable. Run register-protocol.ps1 to enable click-to-focus."
            } elseif ($TerminalPid -eq 0) {
                Write-DebugLog "Protocol registered but no parent terminal found - toast will not be clickable."
            }
        }

        $XmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]::new()
        $XmlDoc.LoadXml($ToastXml)

        $AppId = "cc-notification"
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

# Sends a balloon tip notification from system tray
# Uses Windows Forms NotifyIcon for compatibility with older systems
# Parameters:
#   $Title   - Notification title text
#   $Message - Notification message text
# Returns: $true if successful, $false if failed
function Send-BalloonNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Detail = ""
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        # Balloon tips only support Title + Text, so fold Detail into Message
        $BalloonText = $Message
        if ($Detail -ne "" -and $Detail -ne $Message) {
            $BalloonText = "$Message`n$Detail"
        }

        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = $BalloonText
        $balloon.BalloonTipTitle = $Title
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000)

        Write-Host "Balloon notification sent successfully"
        return $true
    }
    catch {
        Write-Host "Balloon notification failed: $($_.Exception.Message)"
        return $false
    }
}

# Walks up the process tree from the current process to find the parent terminal window
# Checks for Windows Terminal, VS Code, ConHost, and standalone PowerShell windows
# Returns: Hashtable with ProcessId, ProcessName, MainWindowHandle, or $null if not found
function Find-ParentTerminal {
    $TerminalProcessNames = @(
        "WindowsTerminal"
        "Code"
        "conhost"
    )
    $ShellProcessNames = @("pwsh", "powershell", "bash", "cmd", "zsh", "fish", "wsl")

    $CurrentPid = $PID
    $Visited = @{}
    $WalkPath = @()

    while ($CurrentPid -and $CurrentPid -ne 0 -and -not $Visited.ContainsKey($CurrentPid)) {
        $Visited[$CurrentPid] = $true

        $Proc = Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
        if (-not $Proc) { break }

        # Get parent PID via CIM (needed for walk path and tree traversal)
        $CimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $CurrentPid" -ErrorAction SilentlyContinue
        if (-not $CimProc) { break }
        $ParentPid = $CimProc.ParentProcessId

        $WalkPath += @{ Pid = $CurrentPid; Name = $Proc.ProcessName; ParentPid = $ParentPid }

        if ($Proc.MainWindowHandle -ne [IntPtr]::Zero -and
            $TerminalProcessNames -contains $Proc.ProcessName) {
            Write-DebugLog "Found parent terminal: $($Proc.ProcessName) (PID $($Proc.Id))"

            # Find the shell in our ancestry that is a direct child of this terminal
            $ShellPid = 0
            foreach ($Step in $WalkPath) {
                if ($Step.ParentPid -eq $Proc.Id -and $ShellProcessNames -contains $Step.Name) {
                    $ShellPid = $Step.Pid
                    Write-DebugLog "Found ancestor shell: $($Step.Name) (PID $ShellPid) - direct child of terminal"
                    break
                }
            }

            return @{
                ProcessId = $Proc.Id
                ProcessName = $Proc.ProcessName
                MainWindowHandle = $Proc.MainWindowHandle
                ShellPid = $ShellPid
            }
        }

        $CurrentPid = $ParentPid
    }

    Write-DebugLog "No parent terminal found in process tree"
    return $null
}

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

# Parses JSON input from Claude Code hook events (Notification, Stop, and PermissionRequest)
# Detects hook type and extracts appropriate data for notification display
# Parameters:
#   $JsonInput - JSON string from Claude Code hook
# Expected formats:
#   Notification: {"hook_event_name":"Notification","title":"cc-notification","message":"Task completed","session_id":"abc123","transcript_path":"/path"}
#   Stop: {"hook_event_name":"Stop","stop_hook_active":false,"session_id":"abc123","transcript_path":"/path"}
# Returns: Hashtable with parsed notification data and metadata
function Parse-HookInput {
    param([string]$JsonInput)
    
    # Initialize with defaults
    $ParsedTitle = "cc-notification"
    $ParsedMessage = "Notification"
    $ParsedDetail = $null
    $HookType = "Unknown"
    
    if ($JsonInput -ne "") {
        try {
            Write-DebugLog "Raw JSON input: $JsonInput"
            $HookData = $JsonInput | ConvertFrom-Json
            
            # Debug: Show all available properties
            $PropsString = $HookData.PSObject.Properties.Name -join ', '
            Write-DebugLog "Available properties: $PropsString"
            
            # Detect hook type based on hook_event_name field
            if ($HookData.PSObject.Properties.Name -contains "hook_event_name") {
                $EventName = $HookData.hook_event_name
                
                switch ($EventName) {
                    "Notification" {
                        $HookType = "Notification"
                        $ParsedTitle = "cc-notification"
                        $ParsedMessage = if ($HookData.message) { $HookData.message } else { "Notification" }
                        
                        Write-DebugLog "Detected $EventName hook - Title: '$ParsedTitle', Message: '$ParsedMessage'"
                    }
                    "Stop" {
                        $HookType = "Stop"
                        $ParsedTitle = "cc-notification"
                        $ParsedMessage = "Session completed"

                        if ($HookData.PSObject.Properties.Name -contains "stop_hook_active" -and $HookData.stop_hook_active) {
                            $ParsedMessage = "Session continuing from previous stop"
                        }

                        Write-DebugLog "Detected $EventName hook - Message: '$ParsedMessage'"
                    }
                    "PermissionRequest" {
                        $HookType = "PermissionRequest"
                        $ToolName = if ($HookData.tool_name) { $HookData.tool_name } else { "Tool" }
                        $Preview = Get-ToolPreview -ToolName $ToolName -ToolInput $HookData.tool_input

                        $ParsedTitle = [char]::ConvertFromUtf32(0x1F512) + " Permission Required"
                        $ParsedMessage = $ToolName
                        $ParsedDetail = $Preview

                        Write-DebugLog "Detected $EventName hook - Tool: '$ToolName', Preview: '$Preview'"
                    }
                    default {
                        $HookType = $EventName
                        $ParsedTitle = "cc-notification"
                        $ParsedMessage = "Event: $EventName"
                        
                        if ($HookData.message) {
                            $ParsedMessage = $HookData.message
                        }
                        
                        Write-DebugLog "Detected $EventName hook - Title: '$ParsedTitle', Message: '$ParsedMessage'"
                    }
                }
            }
            else {
                # No hook_event_name field - fallback for manual testing
                $HookType = "Manual"
                $ParsedTitle = if ($HookData.title) { $HookData.title } else { "cc-notification" }
                $ParsedMessage = if ($HookData.message) { $HookData.message } else { "Manual notification" }
                
                Write-DebugLog "Detected manual notification - Title: '$ParsedTitle', Message: '$ParsedMessage'"
            }
            
            # Common fields
            if ($HookData.session_id) {
                Write-DebugLog "  Session ID: $($HookData.session_id)"
            }
            if ($HookData.transcript_path) {
                Write-DebugLog "  Transcript: $($HookData.transcript_path)"
            }
            
            return @{
                Title = $ParsedTitle
                Message = $ParsedMessage
                Detail = $ParsedDetail
                HookType = $HookType
                SessionId = $HookData.session_id
                TranscriptPath = $HookData.transcript_path
                StopHookActive = $HookData.stop_hook_active
            }
        }
        catch {
            Write-DebugLog "Failed to parse hook input: $($_.Exception.Message)"
            Write-Host "Using default notification"
        }
    }
    
    # Return defaults if no JSON or parsing failed
    return @{
        Title = $ParsedTitle
        Message = $ParsedMessage
        Detail = $null
        HookType = $HookType
        SessionId = $null
        TranscriptPath = $null
        StopHookActive = $null
    }
}

# Initialize debug log
Write-DebugLog "=== Notification Script Started ==="
Write-DebugLog "Parameters: JsonInput='$JsonInput', Title='$Title', Message='$Message'"

# Check if input is available from stdin (Claude Code hook mode)
$StdinInput = ""
if (-not [Console]::IsInputRedirected -eq $false) {
    try {
        $StdinInput = [Console]::In.ReadToEnd()
        Write-DebugLog "Stdin input detected, length: $($StdinInput.Length)"
        Write-DebugLog "Stdin content: $StdinInput"
    }
    catch {
        # Stdin not available or empty
        Write-DebugLog "Failed to read from stdin: $($_.Exception.Message)"
    }
} else {
    Write-DebugLog "No stdin input detected"
}

# Determine notification content with priority: JsonInput -> Stdin -> Default
# Title/Message parameters override parsed values if specified
if ($JsonInput -ne "") {
    # Manual JSON input mode (for testing) - Highest priority
    Write-DebugLog "Manual JSON input mode (highest priority)"
    $NotificationInfo = Parse-HookInput -JsonInput $JsonInput
    $FinalTitle = $NotificationInfo.Title
    $FinalMessage = $NotificationInfo.Message
    $FinalDetail = $NotificationInfo.Detail
} elseif ($StdinInput -ne "") {
    # Claude Code hook mode (stdin input) - Second priority
    Write-DebugLog "Claude Code hook mode detected (stdin input)"
    $NotificationInfo = Parse-HookInput -JsonInput $StdinInput
    $FinalTitle = $NotificationInfo.Title
    $FinalMessage = $NotificationInfo.Message
    $FinalDetail = $NotificationInfo.Detail
} else {
    Write-DebugLog "Default notification (no JSON input provided)"

    # Default mode - Lowest priority
    $FinalTitle = "cc-notification"
    $FinalMessage = "Notification"
    $FinalDetail = $null
}

# Override with Title/Message parameters if specified (force override)
if ($Title -ne "" -or $Message -ne "") {
    Write-DebugLog "Applying parameter overrides:"
    
    if ($Title -ne "") {
        Write-DebugLog "  Title override: $FinalTitle -> $Title"
        $FinalTitle = $Title
    }
    
    if ($Message -ne "") {
        Write-DebugLog "  Message override: $FinalMessage -> $Message"
        $FinalMessage = $Message
    }
}

# Find the parent terminal for click-to-focus
$Terminal = Find-ParentTerminal
$TerminalPid = if ($Terminal) { $Terminal.ProcessId } else { 0 }
$ShellPid = if ($Terminal) { $Terminal.ShellPid } else { 0 }

# Main notification flow with clear fallback chain
Write-DebugLog "Final notification - Title: '$FinalTitle', Message: '$FinalMessage', Detail: '$FinalDetail', TerminalPID: $TerminalPid, ShellPID: $ShellPid"

# Try Toast notification first (primary method)
if (Send-ToastNotification -Title $FinalTitle -Message $FinalMessage -Detail $FinalDetail -TerminalPid $TerminalPid) {
    Write-DebugLog "Toast notification succeeded"
    exit 0
}

Write-Host "Falling back to balloon notification..."
Write-DebugLog "Toast failed, trying balloon notification"

# Try Balloon notification (fallback method)
if (Send-BalloonNotification -Title $FinalTitle -Message $FinalMessage -Detail $FinalDetail) {
    Write-DebugLog "Balloon notification succeeded"
    exit 0
}

# All methods failed
Write-Host "All notification methods failed"
Write-DebugLog "All notification methods failed"
exit 1