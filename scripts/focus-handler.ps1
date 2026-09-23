# Focus handler for claude-notify:// protocol
# Invoked by Windows when a toast notification is clicked
# Usage: focus-handler.ps1 "claude-notify://focus?pid=12345"

param([string]$Uri)

# Debug log (same location as toast-notification.ps1 debug log)
$LogPath = Join-Path $env:TEMP "cc-notification-focus.log"
function Write-Log { param([string]$Msg); "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') - $Msg" | Out-File -FilePath $LogPath -Append -Encoding UTF8 }

Write-Log "=== Focus handler invoked ==="
Write-Log "URI: $Uri"

# Parse the URI to extract PID and shell PID
$TargetPid = $null
if ($Uri -match '[?&]pid=(\d+)') {
    $TargetPid = [int]$Matches[1]
}

$ShellPid = 0
if ($Uri -match '[?&]shellpid=(\d+)') {
    $ShellPid = [int]$Matches[1]
}

Write-Log "Parsed PID: $TargetPid, ShellPID: $ShellPid"

if (-not $TargetPid) {
    Write-Log "No PID found in URI"
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

        uint foregroundPid;
        uint foregroundThreadId = GetWindowThreadProcessId(foregroundHwnd, out foregroundPid);
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

# Best-effort tab selection for Windows Terminal
# Uses UI Automation to find tabs and CIM to find shell children.
# Only selects a tab when shell-to-tab mapping is unambiguous (1:1).
function Select-TerminalTab {
    param(
        [int]$TerminalPid,
        [int]$ShellPid
    )

    if ($ShellPid -eq 0) {
        Write-Log "No shell PID provided - skipping tab selection"
        return $false
    }

    try {
        # Load UI Automation assemblies
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes

        # Find the WT automation element by PID
        $RootElement = [System.Windows.Automation.AutomationElement]::RootElement
        $Condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $TerminalPid
        )
        $WtElement = $RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $Condition
        )

        if (-not $WtElement) {
            Write-Log "Could not find WT automation element for PID $TerminalPid"
            return $false
        }

        # Enumerate TabItem descendants
        $TabCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
        $Tabs = $WtElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants, $TabCondition
        )

        $TabCount = $Tabs.Count
        Write-Log "Found $TabCount tab(s) via UI Automation"

        if ($TabCount -le 1) {
            Write-Log "Single tab or no tabs - no selection needed"
            return $true
        }

        # Get shell children of WT, sorted by creation date
        $ShellNames = @("pwsh.exe", "powershell.exe", "bash.exe", "cmd.exe", "zsh.exe", "fish.exe", "wsl.exe")
        $ShellNameFilter = ($ShellNames | ForEach-Object { "Name = '$_'" }) -join " OR "
        $WmiFilter = "ParentProcessId = $TerminalPid AND ($ShellNameFilter)"
        $ShellChildren = @(Get-CimInstance Win32_Process -Filter $WmiFilter | Sort-Object CreationDate)

        $ShellCount = $ShellChildren.Count
        Write-Log "Found $ShellCount shell child process(es) of WT"

        foreach ($s in $ShellChildren) {
            Write-Log "  Shell: $($s.Name) PID=$($s.ProcessId) Created=$($s.CreationDate)"
        }

        # Only attempt tab selection if 1:1 mapping
        if ($ShellCount -ne $TabCount) {
            Write-Log "Shell count ($ShellCount) != tab count ($TabCount) - ambiguous mapping, skipping tab selection"
            return $false
        }

        # Find our shell's index in the sorted list
        $TargetIndex = -1
        for ($i = 0; $i -lt $ShellChildren.Count; $i++) {
            if ($ShellChildren[$i].ProcessId -eq $ShellPid) {
                $TargetIndex = $i
                break
            }
        }

        if ($TargetIndex -lt 0) {
            Write-Log "Shell PID $ShellPid not found among WT's shell children - skipping tab selection"
            return $false
        }

        Write-Log "Target shell is at index $TargetIndex"

        # Select the tab via SelectionItemPattern
        $Tab = $Tabs[$TargetIndex]
        $TabName = $Tab.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::NameProperty)
        Write-Log "Selecting tab '$TabName' at index $TargetIndex"

        $Pattern = $Tab.GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern
        )
        $Pattern.Select()

        Write-Log "Successfully selected tab $TargetIndex"
        return $true
    }
    catch {
        Write-Log "Tab selection failed: $($_.Exception.Message)"
        return $false
    }
}

# Find the process and focus its window
$proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Log "Process $TargetPid not found"
    exit 1
}

Write-Log "Process found: $($proc.ProcessName), MainWindowHandle: $($proc.MainWindowHandle), Title: '$($proc.MainWindowTitle)'"

if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
    Write-Log "Process has no main window handle"
    exit 1
}

$result = [WindowFocusHelper]::ForceForeground($proc.MainWindowHandle)
Write-Log "ForceForeground result: $result"

# Attempt best-effort tab selection for Windows Terminal
if ($result -and $ShellPid -gt 0 -and $proc.ProcessName -eq "WindowsTerminal") {
    $null = Select-TerminalTab -TerminalPid $TargetPid -ShellPid $ShellPid
}

exit 0
