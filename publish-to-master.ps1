# publish-to-master.ps1 — runs every 5 min on the Plex server
# If C:\HomeDashboard files changed, copies them to the master folder
# so other PCs' hourly pull gets the latest version.
$src = 'C:\HomeDashboard'
$dst = 'C:\HomeShare\Dashboard-Setup'
$files = @('HomeDashboard.ps1','index.html','Build-Index.ps1')

if (-not (Test-Path $dst)) { exit 0 }

foreach ($f in $files) {
    $s = Join-Path $src $f
    $d = Join-Path $dst $f
    if (-not (Test-Path $s)) { continue }
    if (-not (Test-Path $d)) { Copy-Item $s $d -Force; continue }
    $sh = (Get-FileHash $s -Algorithm MD5).Hash
    $dh = (Get-FileHash $d -Algorithm MD5).Hash
    if ($sh -ne $dh) { Copy-Item $s $d -Force }
}

# Also sync the peers file
$peersSrc = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\device-peers.json'
$peersDst = Join-Path $dst 'device-peers.json'
if (Test-Path $peersSrc) {
    if (-not (Test-Path $peersDst)) { Copy-Item $peersSrc $peersDst -Force }
    else {
        $ps = (Get-FileHash $peersSrc -Algorithm MD5).Hash
        $pd = (Get-FileHash $peersDst -Algorithm MD5).Hash
        if ($ps -ne $pd) { Copy-Item $peersSrc $peersDst -Force }
    }
}
