@echo off
REM ============================================================================
REM  Install WSL2 + Docker Desktop on PlexServer (for DeerFlow's sandbox + nginx)
REM  ---------------------------------------------------------------------------
REM  Double-click, approve the UAC prompt. This enables WSL2 and installs Docker
REM  Desktop. A REBOOT is required afterward. After the reboot, launch Docker
REM  Desktop once (accept its terms) so the daemon starts, then tell Claude
REM  "docker is up" and it will finish the DeerFlow install.
REM ============================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

title Install WSL2 + Docker Desktop
color 0b
echo.
echo  =================================================
echo    Installing WSL2 + Docker Desktop
echo  =================================================
echo.
echo  Step 1/2: enabling WSL2 (Windows Subsystem for Linux)...
wsl --install --no-distribution
echo.
echo  Step 2/2: installing Docker Desktop (winget)...
winget install --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
echo.
echo  =================================================
echo    NEXT STEPS (important):
echo    1. REBOOT this PC now.
echo    2. After reboot, open "Docker Desktop" once and accept its terms
echo       (it uses the WSL2 backend; leave it running).
echo    3. Tell Claude: "docker is up"  -- it will finish DeerFlow.
echo  =================================================
echo.
pause
