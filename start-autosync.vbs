Set s=CreateObject("WScript.Shell")
s.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\HomeDashboard\dashboard-autosync.ps1""", 0, False
