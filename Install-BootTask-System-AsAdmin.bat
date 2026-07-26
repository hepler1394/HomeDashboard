@echo off
REM ============================================================================
REM  HomeDashboard - Install BOOT task (SYSTEM variant, NO password needed)
REM  ---------------------------------------------------------------------------
REM  Creates task "HomeDashBoot" that starts the brain (dashboard, :8788) at
REM  system startup as SYSTEM - so it works even with a blank/awkward account
REM  password and even before anyone logs in. The launcher it runs
REM  (start-brain-system.vbs) forces LOCALAPPDATA to Cory's profile so the brain
REM  still finds its real config/DB (SYSTEM's own profile would be blank).
REM
REM  Double-click this file and approve the UAC prompt. That's it - no password.
REM ============================================================================

REM ---- self-elevate to Administrator ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

setlocal
color 0a
title HomeDashboard - Install Boot Task (SYSTEM)
set LOGFILE=C:\HomeDashboard\boot-task-install.log
echo. >> "%LOGFILE%"
echo ===== SYSTEM boot task install %date% %time% ===== >> "%LOGFILE%"

echo.
echo =================================================
echo    HomeDashboard - Install BOOT Task (SYSTEM)
echo =================================================
echo.
echo Starts the dashboard (brain) at every reboot, before login.
echo No password required.
echo.

schtasks /delete /tn "HomeDashBoot" /f >nul 2>&1

schtasks /create /tn "HomeDashBoot" ^
  /tr "wscript.exe \"C:\HomeDashboard\brain\start-brain-system.vbs\"" ^
  /sc onstart /ru "SYSTEM" /rl highest /f >> "%LOGFILE%" 2>&1

set RC=%ERRORLEVEL%
echo Result: %RC% >> "%LOGFILE%"

if %RC% EQU 0 (
    echo =================================================
    echo    SUCCESS - "HomeDashBoot" created ^(runs as SYSTEM^).
    echo    The brain will start after every reboot.
    echo =================================================
    echo SUCCESS >> "%LOGFILE%"
    echo.
    echo Testing it now...
    schtasks /run /tn "HomeDashBoot" >nul 2>&1
) else (
    echo =================================================
    echo    ERROR creating the task ^(code %RC%^). See %LOGFILE%
    echo =================================================
    echo FAILED code %RC% >> "%LOGFILE%"
)
echo.
pause
