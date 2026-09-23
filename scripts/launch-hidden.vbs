' Launches a PowerShell script completely hidden (no window flash).
' Used as a wrapper for the focus handler to avoid the brief console window
' that powershell.exe -WindowStyle Hidden still creates.
'
' Usage: wscript.exe launch-hidden.vbs "script.ps1" "arg1"
'
' The first argument is the PowerShell script path.
' All remaining arguments are passed through to the script.

Set args = WScript.Arguments
If args.Count < 1 Then
    WScript.Quit 1
End If

scriptPath = args(0)

' Build the argument string for the PowerShell script
scriptArgs = ""
For i = 1 To args.Count - 1
    If i > 1 Then scriptArgs = scriptArgs & " "
    scriptArgs = scriptArgs & """" & args(i) & """"
Next

cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """ " & scriptArgs

Set shell = CreateObject("WScript.Shell")
' Run with window style 0 (vbHide) — completely invisible, no flash
shell.Run cmd, 0, False
