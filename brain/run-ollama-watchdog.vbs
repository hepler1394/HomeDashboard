' Runs ollama-watchdog.ps1 with no console window, matching the wscript+vbs
' pattern the other HomeDashboard watchdogs use.
Set s = CreateObject("WScript.Shell")
s.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\HomeDashboard\brain\ollama-watchdog.ps1""", 0, False
