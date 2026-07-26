# ============================================================================
#  Builds a fast filename index of this PC's drives for the dashboard's
#  "Find files" search. Local disks are indexed FIRST (instant), then LAN
#  network shares (other PCs). Cloud mounts (RaiDrive / Google Drive) are
#  skipped by default - they enumerate one folder per API call and are far
#  too slow to crawl. Publishes snapshots as it goes so search works mid-build.
# ============================================================================
param([string]$OutDir)
$ErrorActionPreference = "SilentlyContinue"
if(-not $OutDir){ $OutDir = Join-Path $env:LOCALAPPDATA "HomeNetDashboard" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$idx  = Join-Path $OutDir "file-index.txt"
$tmp  = "$idx.tmp"
$stat = Join-Path $OutDir "index-status.json"

# Folder names skipped at any depth (system + churn noise).
$skip = @('windows','program files','program files (x86)','programdata','$recycle.bin',
          'windows.old','system volume information','recovery','$winreagent','msocache',
          'perflogs','$sysreset','$getcurrent','appdata','node_modules','.git','__pycache__',
          'packages','config.msi','intel','$windows.~ws','$windows.~bt')
# Drive sources skipped entirely (cloud mounts are too slow to crawl).
$skipSource = @('raidrive','google drive','onedrive','dropbox')

function Write-Stat($building,$count){
  ('{{"building":{0},"count":{1},"updated":"{2}"}}' -f ($building.ToString().ToLower()),$count,(Get-Date -Format "yyyy-MM-dd HH:mm:ss")) |
    Set-Content -Path $stat -Encoding ASCII
}

# Order drives: local disks first, then LAN shares, skipping cloud mounts.
$all   = Get-PSDrive -PSProvider FileSystem | Where-Object { ($_.Used + $_.Free) -gt 0 }
$local = @($all | Where-Object { -not $_.DisplayRoot })
$net   = @()
foreach($d in $all){
  if(-not $d.DisplayRoot){ continue }
  $dr = $d.DisplayRoot.ToLower()
  $isCloud = $false
  foreach($s in $skipSource){ if($dr -like "*$s*"){ $isCloud = $true; break } }
  if(-not $isCloud){ $net += $d }
}

Write-Stat $true 0
$sw = New-Object IO.StreamWriter($tmp,$false,[Text.UTF8Encoding]::new($false))
$count = 0
# Local first: push network first, then local, so the stack pops local first.
$stack = New-Object System.Collections.Stack
foreach($d in $net){   $stack.Push("$($d.Name):\") }
foreach($d in $local){ $stack.Push("$($d.Name):\") }
try {
  while($stack.Count -gt 0){
    $dir = $stack.Pop()
    try { foreach($f in [IO.Directory]::EnumerateFiles($dir)){
            $sw.WriteLine($f); $count++
            if($count % 4000 -eq 0){ $sw.Flush(); Copy-Item -LiteralPath $tmp -Destination $idx -Force; Write-Stat $true $count }
          } } catch {}
    try { foreach($sub in [IO.Directory]::EnumerateDirectories($dir)){
            if($skip -notcontains ([IO.Path]::GetFileName($sub)).ToLower()){ $stack.Push($sub) }
          } } catch {}
  }
} finally {
  $sw.Close()
}
Move-Item -Force $tmp $idx
Write-Stat $false $count
