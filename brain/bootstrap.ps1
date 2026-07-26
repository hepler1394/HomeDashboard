# ============================================================================
#  Home Network Dashboard 3.0 - ONE-LINE PC SETUP
#  Run this ONCE on a new PC to enroll it. After this, everything else
#  (installing apps, VPN, playing movies) is done remotely from the dashboard.
#
#  Easiest: on the new PC, open PowerShell and run
#     irm http://192.168.1.174:8788/bootstrap | iex
#  (the brain fills in its URL + token automatically when it serves this)
#
#  Or explicitly:
#     .\bootstrap.ps1 -Brain http://192.168.1.174:8788 -Token <token>
# ============================================================================
param(
  [string]$Brain = "__BRAIN_URL__",
  [string]$Token = "__BRAIN_TOKEN__",
  [string]$Agent = "",
  [switch]$SkipTailscale
)
$ErrorActionPreference = "Stop"

# Guard: check the SHAPE of the values, not the placeholder text. (The brain
# fills the placeholders with a blind find/replace when it serves this file,
# so the guard must not reference the placeholder tokens - they'd be rewritten
# too and invert the check.)
if ($Brain -notlike 'http*' -or [string]::IsNullOrWhiteSpace($Token) -or $Token.Length -lt 8) {
  Write-Host "Brain URL / token not provided. Run via 'irm <brain>/bootstrap | iex' or pass -Brain/-Token." -ForegroundColor Red
  return
}
if (-not $Agent) { $Agent = $env:COMPUTERNAME.ToLower() }
$Brain = $Brain.TrimEnd('/')

Write-Host "=== Home Dashboard 3.0 - enrolling '$Agent' ===" -ForegroundColor Cyan

# 1. Folders
$AppDir = Join-Path $env:LOCALAPPDATA "HomeNetDashboard"
$AgentDir = Join-Path $env:ProgramData "HomeNetDashboard\agent"
New-Item -ItemType Directory -Path $AppDir  -Force | Out-Null
New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null

# 2. Write agent config (never synced, holds the shared secret)
$cfg = @{ brain=$Brain; token=$Token; agent=$Agent; pollSec=3; allowRaw=$false } | ConvertTo-Json
Set-Content -Path (Join-Path $AppDir "agent.json") -Value $cfg -Encoding UTF8
Write-Host "  [ok] wrote agent config"

# 3. Get the agent script: download the current one from the brain; if that
#    fails (offline), fall back to a copy sitting next to this script (USB).
#    NOTE: $PSScriptRoot is EMPTY when this runs via 'irm <brain>/bootstrap | iex'
#    (no script file), so guard every sibling lookup against an empty root.
$agentPs = Join-Path $AgentDir "homedash-agent.ps1"
$here    = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { "" }
$sibling = if ($here) { Join-Path $here "homedash-agent.ps1" } else { "" }
try {
  Invoke-WebRequest "$Brain/agent" -UseBasicParsing -OutFile $agentPs -TimeoutSec 15
  Write-Host "  [ok] downloaded the latest agent from the brain"
} catch {
  if ($sibling -and (Test-Path $sibling)) {
    Copy-Item $sibling $agentPs -Force
    Write-Host "  [ok] brain not reachable - used the bundled agent from this folder" -ForegroundColor Yellow
  } else {
    Write-Host "  [!!] could not download the agent and no bundled copy found: $($_.Exception.Message)" -ForegroundColor Red
    return
  }
}
# Stage the launcher too so Remote/Files/Parsec work even offline (agent refreshes it when online).
$launcherSib = if ($here) { Join-Path $here "homedash-launcher.ps1" } else { "" }
if ($launcherSib -and (Test-Path $launcherSib)) { Copy-Item $launcherSib (Join-Path $AppDir "homedash-launcher.ps1") -Force -ErrorAction SilentlyContinue }

# 4. Install Tailscale (stable name + reach from anywhere). Non-fatal if it fails.
if (-not $SkipTailscale) {
  if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-Host "  [..] installing Tailscale via winget"
    try {
      winget install --silent --accept-package-agreements --accept-source-agreements --id Tailscale.Tailscale | Out-Null
      Write-Host "  [ok] Tailscale installed - run 'tailscale up' once to sign in"
    } catch { Write-Host "  [!!] Tailscale install skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
  } else { Write-Host "  [ok] Tailscale already present" }
}

# 5. Harden PIA so LAN stays reachable + headless control works (if PIA present)
$pia = "C:\Program Files\Private Internet Access\piactl.exe"
if (Test-Path $pia) {
  try { & $pia background enable | Out-Null; & $pia set allowlan true | Out-Null
        Write-Host "  [ok] PIA hardened (background + allow-LAN)" } catch {}
} else { Write-Host "  [--] PIA not installed yet (dashboard can install it later)" }

# 6. Start at logon via HKCU Run key (no admin needed). The agent re-checks and
#    repairs this on its own every minute, so this is just the first stamp.
try {
  $vbs = Join-Path $AgentDir 'start-agent.vbs'
  ('CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $agentPs + '""", 0, False') |
    Set-Content -Path $vbs -Encoding ASCII
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'HomeDashAgent' -Value "wscript.exe `"$vbs`""
  Write-Host "  [ok] agent starts automatically at logon (Run key)"
} catch {
  Write-Host "  [!!] could not set the logon Run key: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 6b. External auto-recovery watchdog (per-user scheduled task, no admin). The
#     agent<->launcher pair watch each other, but when BOTH are killed together
#     (e.g. a Windows Update RestartManager sweep) nothing revives them until a
#     human intervenes - that's what silently dropped MainPC/laptop off the
#     dashboard. This task restarts the launcher (which revives the agent) every
#     10 min if it's down, so no PC stays offline again.
try {
  $ensurePs = Join-Path $AppDir 'Ensure-Agent.ps1'
  $ensureBody = @(
    '$ErrorActionPreference=''SilentlyContinue''',
    'function Test-Port($p){ $c=[Net.Sockets.TcpClient]::new(); try{ return ($c.ConnectAsync(''127.0.0.1'',$p).Wait(600) -and $c.Connected) }catch{ return $false }finally{ $c.Dispose() } }',
    '$lp = Join-Path $env:LOCALAPPDATA ''HomeNetDashboard\homedash-launcher.ps1''',
    'if((Test-Path $lp) -and -not (Test-Port 8799)){ Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',$lp }',
    'if((Test-Path ''C:\HomeDashboard\brain\brain.py'') -and -not (Test-Port 8788)){ Start-Process ''C:\Python313\python.exe'' -WindowStyle Hidden -ArgumentList ''"C:\HomeDashboard\brain\brain.py"'' }'
  ) -join "`r`n"
  Set-Content -Path $ensurePs -Value $ensureBody -Encoding UTF8
  $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ensurePs + '"')
  $trg1 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
  $trg2 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $sets = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
  $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Unregister-ScheduledTask -TaskName 'HomeDashWatchdog' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  Register-ScheduledTask -TaskName 'HomeDashWatchdog' -Action $act -Trigger $trg1,$trg2 -Settings $sets -Principal $prin -Description 'HomeDashboard auto-recovery: restarts the agent/launcher every 10 min if down.' | Out-Null
  Write-Host "  [ok] auto-recovery watchdog installed (HomeDashWatchdog, every 10 min)"
} catch {
  Write-Host "  [!!] could not install watchdog: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 7. Stop any agent already running (this is an explicit (re-)enroll, so replace
#    it — otherwise the new agent's single-instance guard would just defer to the
#    old one and nothing would change).
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*homedash-agent*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# 8. Start the fresh agent now
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agentPs`""
Write-Host "  [ok] agent started"
Write-Host ""
Write-Host "=== '$Agent' enrolled. It now appears in the dashboard. ===" -ForegroundColor Green
Write-Host "    If you installed Tailscale, run 'tailscale up' once to sign in."
