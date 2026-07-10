' iGemini - launch the local web service TRULY hidden (no console window at all).
' Why this exists: a startup shortcut that runs
'     powershell -WindowStyle Hidden -File run-server.ps1
' does NOT reliably hide powershell's own console window (powershell creates the window
' first, then hides it -> a persistent visible "command window" the user complained about).
' wscript + Run(cmd, 0, False) launches powershell hidden from the very start; powershell
' then runs run-server.ps1 (-> node), and node inherits that hidden console -> zero windows.
' (Verified on the a test machine: 0 visible service windows.)
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & dir & "run-server.ps1" & Chr(34)
sh.Run cmd, 0, False
