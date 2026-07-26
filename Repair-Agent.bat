@echo off
REM HomeDashboard - Agent Repair v2
REM Run as administrator. Handles the launcher/watchdog that revives the agent.
setlocal
set BRAIN=http://192.168.1.174:8788
set AGENTDIR=%ProgramData%\HomeNetDashboard\agent
set TARGET=%AGENTDIR%\homedash-agent.ps1
set TEMP_PS=%AGENTDIR%\homedash-agent.new.ps1

echo =================================================
echo   HomeDashboard - Agent Repair v2
echo =================================================
echo.

echo [1/5] Downloading the latest agent to a temp file...
powershell -NoProfile -Command "Invoke-WebRequest '%BRAIN%/agent' -UseBasicParsing -OutFile '%TEMP_PS%'"
if not exist "%TEMP_PS%" (
  echo     FAILED to download. Check the network / brain and try again.
  echo.
  pause
  exit /b 1
)
echo     Downloaded OK.

echo [2/5] Stopping the launcher/watchdog so it stops reviving the agent...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*homedash-launcher*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

echo [3/5] Stopping the running agent...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*homedash-agent*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

echo [4/5] Installing the new agent file (retrying until the lock releases)...
powershell -NoProfile -Command "$ok=$false; for($i=0;$i -lt 20;$i++){ try { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*homedash-agent*' -or $_.CommandLine -like '*homedash-launcher*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Copy-Item '%TEMP_PS%' '%TARGET%' -Force -ErrorAction Stop; $ok=$true; break } catch { Start-Sleep -Milliseconds 800 } }; if($ok){ Write-Host '    Installed OK.' } else { Write-Host '    STILL LOCKED after 16s.' }"

echo [5/5] Verifying and starting the agent...
powershell -NoProfile -Command "$v=(Select-String -Path '%TARGET%' -Pattern \"AGENT_VERSION = '([^']+)'\").Matches.Groups[1].Value; Write-Host \"    Installed version: $v\""
del "%TEMP_PS%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%TARGET%"

echo.
echo =================================================
echo   Done. Watch the dashboard - this PC should flip
echo   to v3.9.0 within about 10 seconds.
echo =================================================
echo.
pause
