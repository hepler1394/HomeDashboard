' Launches YT Grabber headless (no console, no browser) using its bundled venv.
' Registered as the "YTGrabberStartup" scheduled task so it runs on boot.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = scriptDir
sh.Environment("Process").Item("YTG_NO_BROWSER") = "1"
pyw = fso.BuildPath(scriptDir, ".venv\Scripts\pythonw.exe")
If Not fso.FileExists(pyw) Then pyw = "pythonw.exe"
sh.Run """" & pyw & """ app.py", 0, False
