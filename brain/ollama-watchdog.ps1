<#
    Keeps Ollama serving on 0.0.0.0:11434 so DeerFlow's container can reach it.

    What this fixes: Ollama was simply not running on 2026-08-08 despite being
    in the Startup folder and the HKCU Run key, so DeerFlow's local models were
    dead. This restarts it whenever nothing is serving.

    A 127.0.0.1 bind is FINE for DeerFlow, contrary to what you might expect:
    Docker Desktop presents host.docker.internal traffic as loopback, so the
    container reaches a loopback-only listener without trouble (verified). The
    OLLAMA_HOST=0.0.0.0 below is therefore not required by DeerFlow — it is
    there so other machines on the LAN can also reach the GPU. Ollama's tray app
    ignores it and binds 127.0.0.1 anyway; that is not a fault worth chasing.

    Idempotent and cheap: if something is already listening on 11434 it exits
    immediately, so it is safe to run on a short repeating schedule.

    NOTE ON REBOOTS: this runs as BigBory with an interactive logon type, so it
    cannot start Ollama before someone signs in. AutoAdminLogon is currently 0 on
    this box, meaning a headless reboot leaves the console at the sign-in screen
    and nothing here runs. Making local models genuinely headless requires either
    enabling auto-logon or registering this as a SYSTEM boot task from an
    elevated shell -- see install-ollama-watchdog.ps1.
#>
$ErrorActionPreference = 'SilentlyContinue'

$port = 11434
$exe  = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$log  = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\ollama-watchdog.log'

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Add-Content -Path $log
    # Keep the log from growing without bound.
    $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 500) { $lines[-200..-1] | Set-Content $log }
}

if (-not (Test-Path $exe)) { Write-Log "ollama.exe not found at $exe"; exit 1 }

# Already serving? Nothing to do. Check the port rather than the process: the
# tray app can be running while bound to the wrong interface or wedged.
$listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listening) { exit 0 }

# Persist the bind address so a manually-launched tray app also binds correctly.
if ([Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User') -ne "0.0.0.0:$port") {
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', "0.0.0.0:$port", 'User')
    Write-Log "set user OLLAMA_HOST=0.0.0.0:$port"
}
$env:OLLAMA_HOST = "0.0.0.0:$port"

# Set the model store explicitly rather than relying on the user-level
# OLLAMA_MODELS variable. If this ever runs as SYSTEM (a boot task, so local
# models come back without anyone logging in) none of BigBory's user
# environment applies, and Ollama would start against an empty default store
# and report no models. C:\ollama-models is deliberately outside the user
# profile so SYSTEM can read it -- the store used to live on Z:\.ollama, a
# per-user RaiDrive mapping of Google Drive that SYSTEM cannot see at all.
$models = 'C:\ollama-models'
if (Test-Path $models) {
    $env:OLLAMA_MODELS = $models
} else {
    Write-Log "WARNING: $models missing; falling back to the inherited model store"
}

Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden
Write-Log 'started ollama serve'

# Confirm it actually came up rather than assuming.
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
        Write-Log "listening on $port after $((($i + 1) * 2))s"
        exit 0
    }
}
Write-Log "FAILED: nothing listening on $port after 30s"
exit 1
