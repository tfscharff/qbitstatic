' run-hidden.vbs - launches the qbitstatic monitor with NO visible window.
'
' Why this exists: the scheduled task uses a 2-minute "watchdog" repetition
' trigger so a dead monitor is restarted within ~2 minutes (Task Scheduler's
' RestartOnFailure proved unreliable for the 0xC000013A force-kills we see in
' practice). The previous watchdog launched "powershell.exe -WindowStyle Hidden"
' directly, which briefly flashes a conhost window EVERY time the trigger fires -
' even with MultipleInstances=IgnoreNew. Launching through wscript.exe (which has
' no console of its own) and starting PowerShell with window style 0 avoids that
' flash entirely.
'
' bWaitOnReturn = True keeps this wscript process alive for the monitor's whole
' lifetime, so Task Scheduler sees the task as "Running" and IgnoreNew suppresses
' watchdog re-launches while the monitor is already up (no duplicate monitors).

Dim sh, fso, scriptDir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\qbitstatic.ps1""", 0, True
