# Registers the claude-notify:// protocol handler in the Windows registry
# Run once after installing the plugin: powershell.exe -ExecutionPolicy Bypass -File register-protocol.ps1
# Requires no elevation (writes to HKCU only)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HandlerScript = Join-Path $ScriptDir "focus-handler.ps1"
$LauncherScript = Join-Path $ScriptDir "launch-hidden.vbs"

if (-not (Test-Path $HandlerScript)) {
    Write-Host "Error: focus-handler.ps1 not found at $HandlerScript"
    exit 1
}

if (-not (Test-Path $LauncherScript)) {
    Write-Host "Error: launch-hidden.vbs not found at $LauncherScript"
    exit 1
}

$ProtocolName = "claude-notify"
$RegPath = "HKCU:\Software\Classes\$ProtocolName"

# Create protocol key
New-Item -Path $RegPath -Force | Out-Null
Set-ItemProperty -Path $RegPath -Name "(Default)" -Value "URL:cc-notification Protocol"
Set-ItemProperty -Path $RegPath -Name "URL Protocol" -Value ""

# Default icon
New-Item -Path "$RegPath\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$RegPath\DefaultIcon" -Name "(Default)" -Value "powershell.exe,0"

# Shell open command — uses VBScript wrapper to launch PowerShell truly hidden (no window flash)
New-Item -Path "$RegPath\shell\open\command" -Force | Out-Null
$Command = "`"wscript.exe`" `"$LauncherScript`" `"$HandlerScript`" `"%1`""
Set-ItemProperty -Path "$RegPath\shell\open\command" -Name "(Default)" -Value $Command

Write-Host "Protocol 'claude-notify://' registered successfully."
Write-Host "Handler: $HandlerScript"
Write-Host ""
Write-Host "You can test it by running:"
Write-Host "  Start-Process 'claude-notify://focus?pid=<PID>'"
Write-Host "  (Replace <PID> with a real process ID, e.g. a WindowsTerminal or conhost PID)"
