Set s=CreateObject("WScript.Shell")
s.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\HomeDashboard\brain\homedash-agent.ps1""", 0, False
