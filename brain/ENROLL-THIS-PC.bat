@echo off
title Home Dashboard - Add This PC
color 0b
echo(
echo   =================================================
echo      HOME DASHBOARD  -  add THIS computer
echo   =================================================
echo(
echo   This connects the computer you're sitting at to your
echo   Home Brain dashboard by installing a small background
echo   helper. It is safe to run more than once.
echo(
echo   Working, please wait...
echo(
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; try { iex (irm http://192.168.1.174:8788/bootstrap -TimeoutSec 20) } catch { Write-Host '  network path unavailable - using the copy on this USB...' -ForegroundColor Yellow; $d='%~dp0'; $bs=Join-Path $d 'bootstrap.ps1'; if(-not (Test-Path $bs)){ $bs=Join-Path $d 'HomePC-Setup\bootstrap.ps1' }; if(Test-Path $bs){ & $bs -Brain 'http://192.168.1.174:8788' -Token 'EOdUyQQwCWW1VXiYgMDdOPseACJQcFdX' } else { Write-Host '  Could not reach the brain and no offline copy found. Turn PIA VPN off (or Allow-LAN) and run again.' -ForegroundColor Red } }"
echo(
echo   =================================================
echo      Done. This PC should appear in the dashboard
echo      within about a minute:
echo         http://192.168.1.174:8788
echo   =================================================
echo(
pause
