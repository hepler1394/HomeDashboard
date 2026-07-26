# dashboard-pull.ps1 — hourly updater for Home Network Dashboard
# Checks \\PLEXSERVER\HomeShare\Dashboard-Setup for changes, copies only
# when files differ, and restarts the local dashboard instance.
# NEVER touches %LOCALAPPDATA%\HomeNetDashboard (auth/keys stay local).

$src = '\\PLEXSERVER\HomeShare\Dashboard-Setup'
$dst = 'C:\HomeDashboard'
$files = @('HomeDashboard.ps1','index.html','Build-Index.ps1')
$cfgDir = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard'

if (-not (Test-Path $src)) { exit 0 }
New-Item -ItemType Directory -Path $dst -Force | Out-Null

$changed = $false
foreach ($f in $files) {
    $s = Join-Path $src $f
    $d = Join-Path $dst $f
    if (-not (Test-Path $s)) { continue }
    if (-not (Test-Path $d)) { $changed = $true; break }
    $sh = (Get-FileHash $s -Algorithm MD5).Hash
    $dh = (Get-FileHash $d -Algorithm MD5).Hash
    if ($sh -ne $dh) { $changed = $true; break }
}

$peersSrc = Join-Path $src 'device-peers.json'
$peersDst = Join-Path $cfgDir 'device-peers.json'
if (Test-Path $peersSrc) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $ps = (Get-FileHash $peersSrc -Algorithm MD5).Hash
    $pd = if (Test-Path $peersDst) { (Get-FileHash $peersDst -Algorithm MD5).Hash } else { '' }
    if ($ps -ne $pd) { Copy-Item $peersSrc $peersDst -Force }
}

if (-not $changed) { exit 0 }

foreach ($f in $files) {
    $s = Join-Path $src $f
    if (Test-Path $s) { Copy-Item $s $dst -Force }
}

$conn = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$vbs = Join-Path $dst 'start-hidden.vbs'
if (Test-Path $vbs) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" }
