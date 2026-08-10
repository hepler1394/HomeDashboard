' Keeps the WSL2 Ubuntu VM alive so the DeerFlow Docker stack keeps running.
' WSL terminates its VM as soon as the last session exits, which stops Docker
' and every container with it. This holds one hidden session open for the life
' of the logon, and starts dockerd on the way in.
Set sh = CreateObject("WScript.Shell")
sh.Run "wsl.exe -d Ubuntu-24.04 -u root -- /bin/bash -lc ""(systemctl start docker 2>/dev/null || service docker start >/dev/null 2>&1); sleep infinity""", 0, False
