# Windows Notification Script for Claude Code
# Supports Claude Code hook integration, manual testing, and direct execution
# Priority order: JsonInput -> Stdin -> Default, with Title/Message force override

param(
    # Manual JSON input for testing/debugging (highest priority)
    # Example: -JsonInput '{"hook_event_name":"Notification","title":"Claude Code","message":"Task completed","session_id":"abc123","transcript_path":"/path"}'
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

# Sends a Windows toast notification using Windows Runtime API
# Uses Anthropic.ClaudeCode AppID for proper identification in Action Center
# Parameters:
#   $Title   - Notification title text
#   $Message - Notification message text
# Returns: $true if successful, $false if failed
function Send-ToastNotification {
    param([string]$Title, [string]$Message)
    
    try {
        $AppId = "Anthropic.ClaudeCode"
        
        $template = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType, Windows.UI.Notifications, ContentType = WindowsRuntime]::ToastText02)
        
        $template.GetElementsByTagName("text").Item(0).InnerText = $Title
        $template.GetElementsByTagName("text").Item(1).InnerText = $Message
        
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier.Show($toast)
        
        Write-Host "✓ Toast notification sent successfully"
        return $true
    }
    catch {
        Write-Host "✗ Toast notification failed: $($_.Exception.Message)"
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
    param([string]$Title, [string]$Message)
    
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = $Message
        $balloon.BalloonTipTitle = $Title
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000)
        
        Write-Host "✓ Balloon notification sent successfully"
        return $true
    }
    catch {
        Write-Host "✗ Balloon notification failed: $($_.Exception.Message)"
        return $false
    }
}

# Parses JSON input from Claude Code hooks (Notification and Stop events)
# Detects hook type and extracts appropriate data for notification display
# Parameters:
#   $JsonInput - JSON string from Claude Code hook
# Expected formats:
#   Notification: {"hook_event_name":"Notification","title":"Claude Code","message":"Task completed","session_id":"abc123","transcript_path":"/path"}
#   Stop: {"hook_event_name":"Stop","stop_hook_active":false,"session_id":"abc123","transcript_path":"/path"}
# Returns: Hashtable with parsed notification data and metadata
function Parse-ClaudeCodeHookInput {
    param([string]$JsonInput)
    
    # Initialize with defaults
    $ParsedTitle = "Claude Code"
    $ParsedMessage = "Notification"
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
                        $ParsedTitle = "Claude Code"
                        $ParsedMessage = if ($HookData.message) { $HookData.message } else { "Notification" }
                        
                        Write-DebugLog "Detected $EventName hook - Title: '$ParsedTitle', Message: '$ParsedMessage'"
                    }
                    "Stop" {
                        $HookType = "Stop"
                        $ParsedTitle = "Claude Code"
                        $ParsedMessage = "Session completed"
                        
                        if ($HookData.PSObject.Properties.Name -contains "stop_hook_active" -and $HookData.stop_hook_active) {
                            $ParsedMessage = "Session continuing from previous stop"
                        }
                        
                        Write-DebugLog "Detected $EventName hook - Message: '$ParsedMessage'"
                    }
                    default {
                        $HookType = $EventName
                        $ParsedTitle = "Claude Code"
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
                $ParsedTitle = if ($HookData.title) { $HookData.title } else { "Claude Code" }
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
                HookType = $HookType
                SessionId = $HookData.session_id
                TranscriptPath = $HookData.transcript_path
                StopHookActive = $HookData.stop_hook_active
            }
        }
        catch {
            Write-DebugLog "Failed to parse Claude Code hook input: $($_.Exception.Message)"
            Write-Host "Using default notification"
        }
    }
    
    # Return defaults if no JSON or parsing failed
    return @{
        Title = $ParsedTitle
        Message = $ParsedMessage
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
    $NotificationInfo = Parse-ClaudeCodeHookInput -JsonInput $JsonInput
    $FinalTitle = $NotificationInfo.Title
    $FinalMessage = $NotificationInfo.Message
} elseif ($StdinInput -ne "") {
    # Claude Code hook mode (stdin input) - Second priority
    Write-DebugLog "Claude Code hook mode detected (stdin input)"
    $NotificationInfo = Parse-ClaudeCodeHookInput -JsonInput $StdinInput
    $FinalTitle = $NotificationInfo.Title
    $FinalMessage = $NotificationInfo.Message
} else {
    Write-DebugLog "Default notification (no JSON input provided)"

    # Default mode - Lowest priority
    $FinalTitle = "Claude Code"
    $FinalMessage = "Notification"
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

# Main notification flow with clear fallback chain
Write-DebugLog "Final notification - Title: '$FinalTitle', Message: '$FinalMessage'"

# Try Toast notification first (primary method)
if (Send-ToastNotification -Title $FinalTitle -Message $FinalMessage) {
    Write-DebugLog "Toast notification succeeded"
    exit 0
}

Write-Host "→ Falling back to balloon notification..."
Write-DebugLog "Toast failed, trying balloon notification"

# Try Balloon notification (fallback method)
if (Send-BalloonNotification -Title $FinalTitle -Message $FinalMessage) {
    Write-DebugLog "Balloon notification succeeded"
    exit 0
}

# All methods failed
Write-Host "✗ All notification methods failed"
Write-DebugLog "All notification methods failed"
exit 1