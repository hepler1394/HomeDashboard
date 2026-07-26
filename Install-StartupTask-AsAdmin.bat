@echo off
REM HomeDashboard - Create Startup Task (requires Admin)
REM Right-click this file and select "Run as administrator"

setlocal enabledelayedexpansion
color 0a
title HomeDashboard - Install Startup Task
set LOGFILE=C:\HomeDashboard\startup-task-install.log

echo. >> %LOGFILE%
echo ===== Installation Log ===== >> %LOGFILE%
echo %date% %time% >> %LOGFILE%
echo. >> %LOGFILE%

echo.
echo =================================================
echo     HomeDashboard - Setup Startup Task
echo =================================================
echo.
echo Creating scheduled task...
echo (logging to: %LOGFILE%)
echo.

REM Delete any existing task first
schtasks /delete /tn "HomeDashboardStartup" /f >nul 2>&1

REM Create the scheduled task
echo Executing: schtasks /create /tn "HomeDashboardStartup" ... >> %LOGFILE%
schtasks /create /tn "HomeDashboardStartup" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"C:\ProgramData\HomeNetDashboard\agent\homedash-agent.ps1\"" /sc onstart /f >> %LOGFILE% 2>&1

echo. >> %LOGFILE%
echo Result: %ERRORLEVEL% >> %LOGFILE%
echo. >> %LOGFILE%

if %ERRORLEVEL% EQU 0 (
    echo.
    echo =================================================
    echo.   SUCCESS! Scheduled task created.
    echo.
    echo =================================================
    echo. >> %LOGFILE%
    echo SUCCESS - Task created >> %LOGFILE%
    echo. >> %LOGFILE%
    echo Your HomeDashboard will now start at boot.
    echo.
    timeout /t 5 /nobreak
) else (
    echo.
    echo =================================================
    echo.   ERROR: Could not create the task.
    echo.   Check the log file for details:
    echo.   %LOGFILE%
    echo.
    echo =================================================
    echo. >> %LOGFILE%
    echo FAILED - Check permissions >> %LOGFILE%
    echo. >> %LOGFILE%
    timeout /t 10 /nobreak
)

REM Show the log file
echo.
echo Opening log file...
timeout /t 2 /nobreak
start notepad.exe %LOGFILE%
