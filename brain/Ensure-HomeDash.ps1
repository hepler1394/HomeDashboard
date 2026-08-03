# ============================================================================
#  HomeDashboard EXTERNAL watchdog
#  ---------------------------------------------------------------------------
#  The launcher (8799) and agent watch each other, and the agent revives the
#  brain (8788). But when Windows Update / RestartManager shuts down apps, it
#  can kill the launcher AND agent together — and the mutual watchdog can't
#  recover from that (both halves gone), so the stack stays down until reboot.
#  The only boot task is AtStartup, so a no-reboot mass-kill = dead until a human.
#
#  This script is that missing external trigger. It's idempotent — if a service
#  is already up its start is a no-op (launcher self-exits on the bound port;
#  brain single-instances on 8788). Run every few minutes by the per-user
#  'HomeDashWatchdog' scheduled task. Needs no admin and no reboot.
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'

function Test-Port([int]$port) {
  $c = [Net.Sockets.TcpClient]::new()
  try   { return ($c.ConnectAsync('127.0.0.1', $port).Wait(600) -and $c.Connected) }
  catch { return $false }
  finally { $c.Dispose() }
}

# 1) Launcher/watchdog (8799) — once up it revives the agent, which revives the brain.
if (-not (Test-Port 8799)) {
  Start-Process 'wscript.exe' -WindowStyle Hidden -ArgumentList `
    '"C:\Users\BigBory\AppData\Local\HomeNetDashboard\start-launcher.vbs"'
}

# 2) Brain (8788) — start directly on the brain host too, so the dashboard is
#    back within a minute instead of waiting a full agent poll cycle.
if ((Test-Path 'C:\HomeDashboard\brain\brain.py') -and -not (Test-Port 8788)) {
  Start-Process 'C:\Python313\python.exe' -WindowStyle Hidden -ArgumentList '"C:\HomeDashboard\brain\brain.py"'
}

# 3) Syncthing (8384) — keeps C:\HomeShare syncing across the fleet. Its autostart
#    is logon-only, so an outage (like Windows Update) can leave it dead with no
#    recovery until login. Revive it here too. (Went down in the 2026-07-22 outage.)
$stVbs = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\syncthing-config\start-syncthing.vbs'
if ((Test-Path $stVbs) -and -not (Test-Port 8384)) {
  Start-Process 'wscript.exe' -ArgumentList ('"' + $stVbs + '"')
}
