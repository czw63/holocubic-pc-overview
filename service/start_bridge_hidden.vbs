Option Explicit

Dim shell, fso, dir, bridge, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
bridge = fso.BuildPath(dir, "pc_bridge.ps1")
command = "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Chr(34) & bridge & Chr(34) & " -ServiceMode -SaltPluginUrl http://127.0.0.1:8091"
shell.Run command, 0, False
