' Boot launcher for the brain when started by the SYSTEM scheduled task
' (HomeDashBoot). The account has no password, so the boot task must run as
' SYSTEM - but the brain stores its config/DB under %LOCALAPPDATA%, which for
' SYSTEM would resolve to the (blank) SYSTEM profile. So force LOCALAPPDATA to
' Cory's profile before launching, so the brain finds the real config.
Set sh = CreateObject("WScript.Shell")
sh.Environment("Process").Item("LOCALAPPDATA") = "C:\Users\BigBory\AppData\Local"
sh.Run "C:\Python313\python.exe ""C:\HomeDashboard\brain\brain.py""", 0, False
