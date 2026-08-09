<#
    Registers the scheduled task(s) that keep Ollama serving.

        .\install-ollama-watchdog.ps1          # user watchdog (no elevation needed)
        .\install-ollama-watchdog.ps1 -Boot    # ALSO a SYSTEM boot task (needs admin)

    Two tasks, because they solve different halves of the problem:

    OllamaWatchdog (user, no elevation)
        Runs at logon and every 10 minutes, restarting Ollama whenever nothing
        is listening on 11434. Fixes the failure actually observed on
        2026-08-08: Ollama was in the Startup folder and the HKCU Run key yet
        simply was not running, so DeerFlow's local models were dead. Because
        its logon type is Interactive it cannot run before someone signs in.

    OllamaBoot (SYSTEM, requires an elevated shell)
        Runs at machine startup, so local models come back after a reboot with
        nobody logged in. AutoAdminLogon is 0 on this box, so without this the
        console sits at the sign-in screen and nothing in Startup executes.
        This only became possible after the model store moved off Z:\.ollama --
        a per-user RaiDrive mapping of Google Drive that SYSTEM cannot see --
        to C:\ollama-models. ollama-watchdog.ps1 sets OLLAMA_MODELS explicitly
        for exactly this reason.

    NOT VERIFIED: whether Ollama under SYSTEM gets the GPU. If models turn out
    to run on CPU after a reboot, prefer enabling auto-logon and relying on the
    user watchdog alone.
#>
param([switch]$Boot)

$ErrorActionPreference = 'Stop'
$vbs = 'C:\HomeDashboard\brain\run-ollama-watchdog.vbs'
$ps1 = 'C:\HomeDashboard\brain\ollama-watchdog.ps1'
foreach ($f in @($vbs, $ps1)) { if (-not (Test-Path $f)) { throw "missing $f" } }

# ── user watchdog ────────────────────────────────────────────────────────────
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wscript.exe' -Argument "`"$vbs`""
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$every10 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName 'OllamaWatchdog' -Action $action `
    -Trigger @($atLogon, $every10) -Principal $principal -Settings $settings -Force | Out-Null
Write-Host 'registered OllamaWatchdog (user, logon + every 10 min)'

# ── SYSTEM boot task ─────────────────────────────────────────────────────────
if ($Boot) {
    $admin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'the -Boot task must be registered from an elevated shell' }

    $bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
    $bootPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'OllamaBoot' -Action $bootAction `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $bootPrincipal `
        -Settings $settings -Force | Out-Null
    Write-Host 'registered OllamaBoot (SYSTEM, at startup)'
    Write-Host 'verify after a reboot that models load AND that they are on the GPU'
}
