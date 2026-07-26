# ============================================================================
#  Home Network Dashboard  —  live interactive control panel
#  Pure PowerShell. No installs. Serves a local web UI on 127.0.0.1:8787 that
#  can actually DO things: Remote Desktop, open file shares, Wake-on-LAN,
#  open drives, live status. Launch with HOME-DASHBOARD.bat (or 3-OPEN-DASHBOARD.bat).
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"

# ---- Config (edit these) ---------------------------------------------------
$Port    = 8787
$PlexIp  = "192.168.1.174"
$Devices = @(
  @{ name="Main PC";         ip="192.168.1.189"; role="Main desktop - gaming rig";        mac=""; host="" }
  @{ name="Plex Server";     ip="192.168.1.174"; role="Media library + Plex hub (24/7)"; mac="9C-53-22-99-58-63"; host="PLEXSERVER" }
  @{ name="Media PC";        ip="192.168.1.237"; role="Media PC";                       mac=""; host="" }
)
# Fill in a mac="AA-BB-CC-DD-EE-FF" above to Wake a PC that is fully powered off.
# When a PC is on, its MAC is auto-detected and Wake works with no config.
# (Plex captured on 2026-07-08. Power on the Gaming PC + Projector once so theirs lock in too.)

# ---- File-search index -----------------------------------------------------
$IndexDir  = Join-Path $env:LOCALAPPDATA "HomeNetDashboard"
$IndexFile = Join-Path $IndexDir "file-index.txt"
$IndexStat = Join-Path $IndexDir "index-status.json"
$HistoryFile = Join-Path $IndexDir "history.json"
$script:lastHist = [datetime]::MinValue
# Append a trend sample (cpu, memory, per-drive used%/freeGB) at most every 2 minutes.
function Add-History($snap){
  try {
    if(((Get-Date) - $script:lastHist).TotalSeconds -lt 120){ return }
    $script:lastHist = Get-Date
    $samples = @()
    if(Test-Path $HistoryFile){ try { $j = Get-Content -Raw -Encoding UTF8 $HistoryFile | ConvertFrom-Json; if($j.samples){ $samples = @($j.samples) } } catch {} }
    $dr = @{}
    foreach($d in $snap.drives){ $dr[[string]$d.letter] = @{ u=[int]$d.usedPct; f=[int]$d.freeGB } }
    $samples += [pscustomobject]@{ t=[int64]([datetimeoffset]::UtcNow).ToUnixTimeSeconds(); cpu=[int]$snap.cpu; mem=[int]$snap.memPct; drives=$dr }
    if($samples.Count -gt 720){ $samples = @($samples[($samples.Count-720)..($samples.Count-1)]) }
    (@{ samples=$samples } | ConvertTo-Json -Depth 6 -Compress) | Set-Content -Path $HistoryFile -Encoding UTF8
  } catch {}
}
$IndexBuilder = Join-Path $PSScriptRoot "Build-Index.ps1"

# Everything (voidtools) HTTP servers to query for INSTANT search. If reachable,
# these are used instead of the built-in index. Add other PCs' Everything servers
# here to search the whole house, e.g. 'http://192.168.1.174:8011'.
$EverythingUrls = @('http://127.0.0.1:8011')

# AI search config (your API keys) - lives locally, never hardcoded/committed.
$AiConfigFile = Join-Path $IndexDir "ai-config.json"
# Parsec peer IDs per device (set in Settings) so the Parsec button connects direct.
$PeersFile = Join-Path $IndexDir "device-peers.json"
if (-not (Test-Path $PeersFile) -and (Test-Path (Join-Path $PSScriptRoot "device-peers.json"))) {
  New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null
  Copy-Item (Join-Path $PSScriptRoot "device-peers.json") $PeersFile -Force
}

# LAN access + password. Written by Setup-Plex-Dashboard.ps1. If a password is
# set, EVERY request needs HTTP Basic auth. bindLan=true listens on the whole
# network so any PC can open http://<this-pc-ip>:8787 . Default (no file) =
# localhost only, no password (private to this PC).
$AuthConfigFile = Join-Path $IndexDir "dashboard-auth.json"
$__auth  = if(Test-Path $AuthConfigFile){ try { Get-Content -Raw $AuthConfigFile | ConvertFrom-Json } catch { $null } } else { $null }
$BindLan  = [bool]($__auth.bindLan)
$AuthPass = [string]($__auth.password)

# ---- Status helpers --------------------------------------------------------
function Test-Up([string]$ip,[int]$ms=600){
  try { $p=New-Object Net.NetworkInformation.Ping; $r=$p.Send($ip,$ms)
        if($r.Status -eq 'Success'){ return @{ up=$true; ms=[int]$r.RoundtripTime } } } catch {}
  return @{ up=$false; ms=$null }
}
function Test-Port([string]$ip,[int]$port,[int]$ms=450){
  $c=New-Object Net.Sockets.TcpClient
  try { if($c.BeginConnect($ip,$port,$null,$null).AsyncWaitHandle.WaitOne($ms)){ $c.Close(); return $true } } catch {}
  $c.Close(); return $false
}
function Get-Mac([string]$ip){
  $m = (Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue |
        Where-Object { $_.LinkLayerAddress -and $_.State -ne 'Unreachable' } |
        Select-Object -First 1).LinkLayerAddress
  if($m){ return $m }
  $line = (arp -a | Select-String ([regex]::Escape($ip)+'\s')) | Select-Object -First 1
  if($line -and $line.ToString() -match '([0-9a-fA-F]{2}[-:]){5}[0-9a-fA-F]{2}'){ return $Matches[0] }
  return ""
}

$script:cache = $null
$script:cacheAt = [datetime]::MinValue

function Get-Snapshot {
  if($script:cache -and ((Get-Date) - $script:cacheAt).TotalSeconds -lt 4){ return $script:cache }

  $localIps = @()
  try { $localIps = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' }).IPAddress) } catch {}
  if(-not $localIps){ try { $localIps = @(([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' }).IPAddressToString) } catch {} }

  $peers = if(Test-Path $PeersFile){ try { Get-Content -Raw $PeersFile | ConvertFrom-Json } catch { $null } } else { $null }
  $devs = @()
  foreach($d in $Devices){
    $isLocal = ($localIps -contains $d.ip)
    $s = if($isLocal){ @{ up=$true; ms=0 } } else { Test-Up $d.ip }
    $smb=$false;$rdp=$false;$plex=$null;$mac=$d.mac
    if($s.up){
      $smb = if($isLocal){$true}else{ Test-Port $d.ip 445 }
      $rdp = if($isLocal){$true}else{ Test-Port $d.ip 3389 }
      if($d.ip -eq $PlexIp){ $plex = Test-Port $d.ip 32400 }
      if(-not $mac -and -not $isLocal){ $mac = Get-Mac $d.ip }
    } elseif($d.ip -eq $PlexIp){ $plex=$false }
    $devs += [pscustomobject]@{
      name=$d.name; ip=$d.ip; role=$d.role; up=$s.up; ms=$s.ms
      smb=$smb; rdp=$rdp; plex=$plex; mac=$mac; isPlex=($d.ip -eq $PlexIp); isLocal=$isLocal
      parsec=$(if($peers){ [string]$peers.$($d.ip) } else { '' }); host=$d.host
    }
  }

  $drives=@()
  foreach($v in (Get-PSDrive -PSProvider FileSystem | Where-Object { ($_.Used+$_.Free) -gt 0 } | Sort-Object Name)){
    $total=$v.Used+$v.Free; if($total -le 0){continue}
    $owner = if($v.DisplayRoot -and ($v.DisplayRoot -match '^\\\\([^\\]+)')){ $Matches[1] } else { $env:COMPUTERNAME }
    $drives += [pscustomobject]@{
      letter=$v.Name
      source=$(if($v.DisplayRoot){$v.DisplayRoot}else{"Local disk"})
      network=[bool]$v.DisplayRoot; owner=$owner
      usedPct=[math]::Round(($v.Used/$total)*100)
      usedGB=[math]::Round($v.Used/1GB); freeGB=[math]::Round($v.Free/1GB); totalGB=[math]::Round($total/1GB)
    }
  }

  $os  = Get-CimInstance Win32_OperatingSystem
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  $memPct = if($os.TotalVisibleMemorySize){ [math]::Round((($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize)*100) } else { 0 }
  $up = (Get-Date) - $os.LastBootUpTime
  $uptime = "{0}d {1}h {2}m" -f $up.Days,$up.Hours,$up.Minutes
  $inet = Test-Port "1.1.1.1" 443 800

  $snap = [pscustomobject]@{
    host=$env:COMPUTERNAME
    time=(Get-Date -Format "ddd, MMM d  h:mm:ss tt")
    internet=$inet
    cpu=[int]$cpu; memPct=$memPct; uptime=$uptime
    memUsedGB=[math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB)
    memTotalGB=[math]::Round($os.TotalVisibleMemorySize/1MB)
    devices=$devs; drives=$drives
  }
  $script:cache=$snap; $script:cacheAt=Get-Date
  return $snap
}

function Send-WOL([string]$mac){
  $mac = ($mac -replace '[^0-9a-fA-F]','')
  if($mac.Length -ne 12){ return $false }
  $mb = New-Object byte[] 6
  for($i=0;$i -lt 6;$i++){ $mb[$i]=[Convert]::ToByte($mac.Substring($i*2,2),16) }
  $pkt = New-Object byte[] 102
  for($i=0;$i -lt 6;$i++){ $pkt[$i]=0xFF }
  for($i=6;$i -lt 102;$i+=6){ [Array]::Copy($mb,0,$pkt,$i,6) }
  try {
    $u=New-Object Net.Sockets.UdpClient; $u.EnableBroadcast=$true
    $u.Connect([Net.IPAddress]::Broadcast,9); [void]$u.Send($pkt,$pkt.Length); $u.Close()
    return $true
  } catch { return $false }
}

$script:evOk = $null
$script:evAt = [datetime]::MinValue
function Test-Everything {
  if($null -ne $script:evOk -and ((Get-Date) - $script:evAt).TotalSeconds -lt 20){ return $script:evOk }
  $ok = $false
  foreach($base in $EverythingUrls){
    try { Invoke-RestMethod "$base/?search=a&json=1&count=1" -TimeoutSec 1 | Out-Null; $ok = $true; break } catch {}
  }
  $script:evOk = $ok; $script:evAt = Get-Date; return $ok
}
function Search-Everything($q){
  $out = New-Object System.Collections.ArrayList
  $any = $false
  foreach($base in $EverythingUrls){
    try {
      $resp = Invoke-RestMethod "$base/?search=$([uri]::EscapeDataString($q))&json=1&path_column=1&count=300" -TimeoutSec 3
      $any = $true
      foreach($r in $resp.results){
        if($r.name){
          $dir = [string]$r.path
          $full = if($dir){ Join-Path $dir $r.name } else { $r.name }
          [void]$out.Add([pscustomobject]@{ name=$r.name; dir=$dir; full=$full })
        }
      }
    } catch {}
  }
  $script:evOk = $any; $script:evAt = Get-Date
  return @{ ok=$any; results=$out }
}
function Search-Index($q){
  $res = New-Object System.Collections.ArrayList
  if(-not (Test-Path $IndexFile) -or $q.Length -lt 2){ return $res }
  # Split into words: a line matches only if it contains ALL words (any order).
  # So "zelda switch" matches ...\Nintendo Switch Games\...zelda...  even though
  # those words aren't next to each other.
  $terms = @($q -split '\s+' | Where-Object { $_ })
  try {
    foreach($line in [IO.File]::ReadLines($IndexFile)){
      $all = $true
      foreach($t in $terms){ if($line.IndexOf($t,[StringComparison]::OrdinalIgnoreCase) -lt 0){ $all = $false; break } }
      if($all){
        [void]$res.Add([pscustomobject]@{ name=(Split-Path $line -Leaf); dir=(Split-Path $line -Parent); full=$line })
        if($res.Count -ge 300){ break }
      }
    }
  } catch {}
  return $res
}
function Start-Reindex {
  if(Test-Path $IndexBuilder){
    Start-Process powershell -WindowStyle Hidden -ArgumentList `
      '-NoProfile','-ExecutionPolicy','Bypass','-File',$IndexBuilder,'-OutDir',$IndexDir
    return $true
  }
  return $false
}

# ---- AI search (multi-provider) --------------------------------------------
function Get-AiConfig { if(Test-Path $AiConfigFile){ try { Get-Content -Raw $AiConfigFile | ConvertFrom-Json } catch { $null } } else { $null } }
function New-DefaultAiConfig {
  [pscustomobject]@{
    default='gemini'; fallback=@('deepseek','claude','aimlapi')
    providers=[pscustomobject]@{
      aimlapi =[pscustomobject]@{ style='openai';    baseUrl='https://api.aimlapi.com/v1';                               key=''; model='gpt-4o-mini' }
      claude  =[pscustomobject]@{ style='anthropic'; baseUrl='https://api.anthropic.com/v1';                             key=''; model='claude-haiku-4-5-20251001' }
      gemini  =[pscustomobject]@{ style='openai';    baseUrl='https://generativelanguage.googleapis.com/v1beta/openai'; key=''; model='gemini-2.5-flash' }
      deepseek=[pscustomobject]@{ style='openai';    baseUrl='https://api.deepseek.com/v1';                              key=''; model='deepseek-chat' }
    }
  }
}
# Ordered list of usable providers: default first, then fallback list, then any
# other provider that has a key. Each entry = @{ name; p }.
function Get-AiOrder($cfg){
  if(-not $cfg -or -not $cfg.providers){ return @() }
  $names = @()
  if($cfg.default){ $names += [string]$cfg.default }
  if($cfg.fallback){ $names += @($cfg.fallback) }
  $names += @($cfg.providers.PSObject.Properties.Name)
  $seen=@{}; $out=@()
  foreach($n in $names){
    if($n -and -not $seen.ContainsKey($n)){
      $seen[$n]=$true
      $p = $cfg.providers.$n
      if($p -and $p.key -and ([string]$p.key).Trim()){ $out += ,@{ name=$n; p=$p } }
    }
  }
  return $out
}
function Invoke-OneAi($p,$system,$user){
  if($p.style -eq 'anthropic'){
    $body = @{ model=$p.model; max_tokens=500; system=$system; messages=@(@{role='user';content=$user}) } | ConvertTo-Json -Depth 6
    $h = @{ 'x-api-key'=$p.key; 'anthropic-version'='2023-06-01'; 'content-type'='application/json' }
    $r = Invoke-RestMethod "$($p.baseUrl.TrimEnd('/'))/messages" -Method Post -Headers $h -Body $body -TimeoutSec 25
    return [string]$r.content[0].text
  } else {
    $body = @{ model=$p.model; max_tokens=500; messages=@(@{role='system';content=$system},@{role='user';content=$user}) } | ConvertTo-Json -Depth 6
    $h = @{ 'Authorization'="Bearer $($p.key)"; 'content-type'='application/json' }
    $r = Invoke-RestMethod "$($p.baseUrl.TrimEnd('/'))/chat/completions" -Method Post -Headers $h -Body $body -TimeoutSec 25
    return [string]$r.choices[0].message.content
  }
}
# Try each provider in order; on ANY failure (throttle, error, bad key) fall
# through to the next. Returns @{ text; provider } or $null if all fail.
function Invoke-Ai($system,$user){
  foreach($sel in (Get-AiOrder (Get-AiConfig))){
    try { $t = Invoke-OneAi $sel.p $system $user; if($t){ return @{ text=$t; provider=$sel.name } } } catch { continue }
  }
  return $null
}
function Search-AiQuery($q){
  $sys = 'You convert a person''s plain-English request to find files on their Windows PC into literal filename search queries. Reply with ONLY compact JSON: {"queries":["..."],"note":"one short sentence"}. Each query is words or extensions that would literally appear in a filename or folder path (e.g. resume or cv; .mp4 .mkv .mov for videos; .pdf for documents). Words within one query are ANDed; give separate queries for alternatives. 1-6 queries. No prose, JSON only.'
  $ai = Invoke-Ai $sys $q
  if(-not $ai){ return $null }
  $txt = $ai.text
  $obj = $null
  $m = [regex]::Match($txt,'\{[\s\S]*\}')
  if($m.Success){ try { $obj = $m.Value | ConvertFrom-Json } catch {} }
  $queries = if($obj -and $obj.queries){ @($obj.queries) } else { @($q) }
  $note = if($obj){ [string]$obj.note } else { '' }
  $seen = @{}; $out = New-Object System.Collections.ArrayList
  $useEv = Test-Everything
  foreach($qq in $queries){
    if(-not $qq){ continue }
    $rs = if($useEv){ (Search-Everything $qq).results } else { Search-Index $qq }
    foreach($r in $rs){ if(-not $seen.ContainsKey($r.full)){ $seen[$r.full]=$true; [void]$out.Add($r); if($out.Count -ge 300){ break } } }
    if($out.Count -ge 300){ break }
  }
  return @{ note=$note; queries=$queries; results=$out; provider=$ai.provider }
}

function Invoke-Action($qs){
  $ip=$qs['ip']; $drive=$qs['drive']; $mac=$qs['mac']; $local=($qs['local'] -eq '1')
  $okIp    = $ip    -match '^\d{1,3}(\.\d{1,3}){3}$'
  $okDrive = $drive -match '^[A-Za-z]$'
  switch($qs['do']){
    'rdp'      { if(-not $okIp){ return "Invalid address" }; Start-Process mstsc.exe -ArgumentList "/v:$ip";      return "Launching Remote Desktop to $ip" }
    'share'    { if(-not $okIp){ return "Invalid address" }; Start-Process explorer.exe "\\$ip";                  return "Opening file share \\$ip" }
    'open'     { if(-not $okDrive){ return "Invalid drive" }; Start-Process explorer.exe "$($drive.ToUpper()):\"; return "Opening $($drive.ToUpper()): in Explorer" }
    'wol'      { if(Send-WOL $mac){ return "Wake signal sent" } else { return "No MAC known - power the PC on once so it can be detected" } }
    'parsec'   { $peer=$qs['peer']; $exe="$env:ProgramFiles\Parsec\parsecd.exe"
                 if(-not (Test-Path $exe)){ $exe = Join-Path ${env:ProgramFiles(x86)} 'Parsec\parsecd.exe' }
                 if(Test-Path $exe){ if($peer -match '^[A-Za-z0-9]+$'){ Start-Process $exe -ArgumentList "peer_id=$peer" } else { Start-Process $exe }; return "Launching Parsec" }
                 return "Parsec not found - install it from parsec.app" }
    'reveal'   { $path=$qs['path']; if($path -and (Test-Path -LiteralPath $path)){ Start-Process explorer.exe "/select,`"$path`""; return "Opening folder for $(Split-Path $path -Leaf)" }
                 if($path -and (Test-Path -LiteralPath (Split-Path $path -Parent))){ Start-Process explorer.exe (Split-Path $path -Parent); return "Opening folder" }
                 return "That file is no longer there - try Rebuild index" }
    'openfile' { $path=$qs['path']; if($path -and (Test-Path -LiteralPath $path)){ Start-Process $path; return "Opening $(Split-Path $path -Leaf)" }; return "File not found" }
    'sleep'    { if($local){ Start-Process rundll32.exe -ArgumentList "powrprof.dll,SetSuspendState 0,1,0"; return "Sleeping this PC" }
                 return "Remote sleep isn't supported - use Restart or Shut down" }
    'restart'  { if($local){ Start-Process shutdown.exe -ArgumentList "/r","/t","5","/f" -WindowStyle Hidden; return "Restarting this PC in 5s" }
                 if(-not $okIp){ return "Invalid address" }
                 Start-Process shutdown.exe -ArgumentList "/r","/m","\\$ip","/t","5","/f" -WindowStyle Hidden; return "Restart sent to $ip (needs admin rights on that PC)" }
    'shutdown' { if($local){ Start-Process shutdown.exe -ArgumentList "/s","/t","5","/f" -WindowStyle Hidden; return "Shutting down this PC in 5s" }
                 if(-not $okIp){ return "Invalid address" }
                 Start-Process shutdown.exe -ArgumentList "/s","/m","\\$ip","/t","5","/f" -WindowStyle Hidden; return "Shutdown sent to $ip (needs admin rights on that PC)" }
    'copy'     { $src=$qs['src']; $dst=$qs['dst']
                 if(-not ($src -and (Test-Path -LiteralPath $src))){ return "That item no longer exists" }
                 if(-not ($dst -and (Test-Path -LiteralPath $dst -PathType Container))){ return "Pick a destination folder" }
                 $srcFull=(Resolve-Path -LiteralPath $src).Path; $dstFull=(Resolve-Path -LiteralPath $dst).Path
                 if($dstFull -ieq (Split-Path $srcFull -Parent)){ return "It's already in that folder" }
                 if($dstFull.StartsWith($srcFull.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)){ return "Can't copy a folder into itself" }
                 $leaf=Split-Path $srcFull -Leaf
                 try { Copy-Item -LiteralPath $srcFull -Destination $dstFull -Recurse -Force -ErrorAction Stop; return "Copied '$leaf' to $(Split-Path $dstFull -Leaf)" }
                 catch { return "Copy failed: $($_.Exception.Message)" } }
    'move'     { $src=$qs['src']; $dst=$qs['dst']
                 if(-not ($src -and (Test-Path -LiteralPath $src))){ return "That item no longer exists" }
                 if(-not ($dst -and (Test-Path -LiteralPath $dst -PathType Container))){ return "Pick a destination folder" }
                 $srcFull=(Resolve-Path -LiteralPath $src).Path; $dstFull=(Resolve-Path -LiteralPath $dst).Path
                 if($dstFull -ieq (Split-Path $srcFull -Parent)){ return "It's already in that folder" }
                 if($dstFull.StartsWith($srcFull.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)){ return "Can't move a folder into itself" }
                 $leaf=Split-Path $srcFull -Leaf
                 try { Move-Item -LiteralPath $srcFull -Destination $dstFull -Force -ErrorAction Stop; return "Moved '$leaf' to $(Split-Path $dstFull -Leaf)" }
                 catch { return "Move failed: $($_.Exception.Message)" } }
    default    { return "Unknown action" }
  }
}

# ---- Web UI ----------------------------------------------------------------
$INDEX_HTML = @'
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Home Network</title>
<style>
:root{
  --bg1:#0a0e15;--bg2:#0e1524;--panel:rgba(255,255,255,.035);--panel2:rgba(255,255,255,.055);
  --line:rgba(255,255,255,.09);--line2:rgba(255,255,255,.14);
  --txt:#e8eef6;--mut:#8895a8;--dim:#5f6c7e;
  --acc:#38bdf8;--acc2:#818cf8;--ok:#34d399;--bad:#f87171;--warn:#fbbf24;
  --shadow:0 10px 30px rgba(0,0,0,.45);
}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;color:var(--txt);
  font-family:"Segoe UI Variable Text","Segoe UI",system-ui,Arial,sans-serif;
  background:radial-gradient(1200px 700px at 12% -8%,#12203a 0%,transparent 55%),
             radial-gradient(1000px 600px at 100% 0%,#1a1330 0%,transparent 50%),
             linear-gradient(160deg,var(--bg1),var(--bg2));background-attachment:fixed}
.wrap{max-width:1240px;margin:0 auto;padding:22px 26px 60px}
a{color:inherit;text-decoration:none}
.hidden{display:none!important}

/* header */
.top{display:flex;align-items:center;gap:16px;margin-bottom:22px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:13px}
.logo{width:44px;height:44px;border-radius:13px;display:grid;place-items:center;
  background:linear-gradient(140deg,var(--acc),var(--acc2));box-shadow:0 6px 20px rgba(56,189,248,.35)}
.logo svg{width:24px;height:24px;stroke:#06121f;fill:none;stroke-width:2}
.brand h1{margin:0;font-size:20px;letter-spacing:.2px;font-weight:650}
.brand .hostline{font-size:12.5px;color:var(--mut);margin-top:2px}
.top .spacer{flex:1}
.pill{display:inline-flex;align-items:center;gap:7px;padding:7px 12px;border-radius:999px;
  background:var(--panel);border:1px solid var(--line);font-size:12.5px;color:var(--mut)}
.pill b{color:var(--txt);font-weight:600}
.pdot{width:8px;height:8px;border-radius:50%;background:var(--dim)}
.pdot.on{background:var(--ok);box-shadow:0 0 8px var(--ok)}
.pdot.off{background:var(--bad);box-shadow:0 0 8px var(--bad)}
.btn{display:inline-flex;align-items:center;gap:7px;padding:8px 13px;border-radius:10px;cursor:pointer;
  background:var(--panel);border:1px solid var(--line2);color:var(--txt);font-size:12.5px;font-weight:550;
  transition:.15s;user-select:none}
.btn:hover{background:var(--panel2);border-color:var(--acc);transform:translateY(-1px)}
.btn svg{width:15px;height:15px;stroke:currentColor;fill:none;stroke-width:2}
.btn.ghost{background:transparent}
.btn.warn:hover{border-color:var(--bad);color:var(--bad)}

/* kpi row */
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(158px,1fr));gap:13px;margin-bottom:26px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:15px;padding:15px 16px;box-shadow:var(--shadow)}
.kpi .kh{display:flex;align-items:center;gap:8px;color:var(--mut);font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.4px}
.kpi .kh svg{width:15px;height:15px;stroke:var(--acc);fill:none;stroke-width:2}
.kpi .kv{font-size:26px;font-weight:680;margin-top:9px;letter-spacing:.3px}
.kpi .kv small{font-size:14px;color:var(--mut);font-weight:500}
.kpi .kbar{height:6px;border-radius:6px;background:rgba(255,255,255,.08);margin-top:11px;overflow:hidden}
.kpi .kbar>i{display:block;height:100%;border-radius:6px;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .6s}
.kpi .ksub{font-size:11.5px;color:var(--dim);margin-top:8px}

/* section */
.sec{margin:8px 0 14px;display:flex;align-items:center;gap:10px}
.sec h2{font-size:14px;text-transform:uppercase;letter-spacing:1.2px;color:var(--mut);margin:0;font-weight:650}
.sec .ln{flex:1;height:1px;background:var(--line)}

/* devices */
.devs{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin-bottom:34px}
.dev{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:17px 18px;box-shadow:var(--shadow);
  position:relative;overflow:hidden;transition:.18s}
.dev:hover{border-color:var(--line2)}
.dev::before{content:"";position:absolute;inset:0 auto 0 0;width:3px;background:var(--dim)}
.dev.on::before{background:linear-gradient(var(--ok),#059669)}
.dev.off::before{background:linear-gradient(var(--bad),#b91c1c)}
.dev.off{opacity:.72}
.dhead{display:flex;align-items:center;gap:12px}
.ring{width:14px;height:14px;border-radius:50%;flex:0 0 auto;background:var(--bad)}
.ring.on{background:var(--ok);box-shadow:0 0 0 0 rgba(52,211,153,.55);animation:pulse 2.2s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(52,211,153,.5)}70%{box-shadow:0 0 0 9px rgba(52,211,153,0)}100%{box-shadow:0 0 0 0 rgba(52,211,153,0)}}
.dname{font-size:16.5px;font-weight:640}
.drole{font-size:12px;color:var(--mut);margin-top:1px}
.dstat{margin-left:auto;font-size:11px;font-weight:750;letter-spacing:.6px;padding:4px 9px;border-radius:999px}
.dstat.on{color:var(--ok);background:rgba(52,211,153,.12);border:1px solid rgba(52,211,153,.35)}
.dstat.off{color:var(--bad);background:rgba(248,113,113,.1);border:1px solid rgba(248,113,113,.32)}
.dip{display:flex;align-items:center;gap:9px;margin:13px 0 12px;font-family:"Cascadia Code",Consolas,monospace;font-size:13px;color:var(--acc)}
.dip .cp{cursor:pointer;color:var(--dim);transition:.15s}.dip .cp:hover{color:var(--acc)}
.dip .lat{margin-left:auto;color:var(--mut);font-family:inherit;font-size:11.5px}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:14px}
.chip{font-size:11px;padding:4px 10px;border-radius:999px;display:inline-flex;align-items:center;gap:5px;font-weight:550}
.chip i{width:6px;height:6px;border-radius:50%}
.chip.ok{background:rgba(52,211,153,.1);color:#6ee7b7;border:1px solid rgba(52,211,153,.28)}.chip.ok i{background:var(--ok)}
.chip.no{background:rgba(248,113,113,.08);color:#fca5a5;border:1px solid rgba(248,113,113,.22)}.chip.no i{background:var(--bad)}
.acts{display:flex;flex-wrap:wrap;gap:8px}
.acts .btn{padding:7px 11px;font-size:12px}
.btn[disabled]{opacity:.38;pointer-events:none}
.thispc{font-size:9.5px;font-weight:750;letter-spacing:.5px;color:var(--acc);border:1px solid rgba(56,189,248,.45);
  padding:1px 6px;border-radius:6px;margin-left:9px;vertical-align:middle}
.pwrwrap{position:relative}
.pwrmenu{position:absolute;bottom:calc(100% + 6px);right:0;background:#141c2b;border:1px solid var(--line2);border-radius:11px;
  padding:6px;display:none;flex-direction:column;gap:2px;min-width:140px;box-shadow:var(--shadow);z-index:30}
.pwrmenu.open{display:flex}
.pwrmenu button{background:transparent;border:0;color:var(--txt);text-align:left;padding:9px 11px;border-radius:8px;
  font-size:12.5px;cursor:pointer;font-family:inherit;font-weight:550}
.pwrmenu button:hover{background:var(--panel2)}
.pwrmenu button.danger{color:var(--bad)}.pwrmenu button.danger:hover{background:rgba(248,113,113,.12)}

/* storage */
.panel{background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden}
.ptools{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.search{display:flex;align-items:center;gap:8px;background:rgba(0,0,0,.25);border:1px solid var(--line);border-radius:10px;padding:7px 11px;flex:1;min-width:180px}
.search svg{width:15px;height:15px;stroke:var(--mut);fill:none;stroke-width:2}
.search input{background:transparent;border:0;outline:0;color:var(--txt);font-size:13px;width:100%;font-family:inherit}
.seg{display:flex;background:rgba(0,0,0,.25);border:1px solid var(--line);border-radius:10px;padding:3px}
.seg button{border:0;background:transparent;color:var(--mut);font-size:12px;padding:6px 12px;border-radius:7px;cursor:pointer;font-family:inherit;font-weight:550}
.seg button.act{background:var(--panel2);color:var(--txt)}
table{width:100%;border-collapse:collapse}
th{text-align:left;color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.6px;padding:11px 16px;border-bottom:1px solid var(--line);font-weight:650}
td{padding:11px 16px;border-bottom:1px solid rgba(255,255,255,.05);font-size:13px}
tr:last-child td{border-bottom:none}
tbody tr{cursor:pointer;transition:.12s}tbody tr:hover{background:rgba(255,255,255,.035)}
.dl{font-weight:750;font-size:14px}
.tag{font-size:10px;padding:2px 7px;border-radius:6px;margin-left:8px;vertical-align:middle;font-weight:600}
.tag.loc{background:rgba(56,189,248,.12);color:var(--acc)}
.tag.net{background:rgba(129,140,248,.14);color:var(--acc2)}
.src{color:var(--mut);font-family:Consolas,monospace;font-size:12px}
.num{text-align:right;white-space:nowrap;color:#c7d2de;font-variant-numeric:tabular-nums}
.track{background:rgba(255,255,255,.08);border-radius:6px;height:8px;width:180px;max-width:34vw;overflow:hidden}
.fill{height:100%;border-radius:6px;transition:width .6s}
.fill.cool{background:linear-gradient(90deg,#22d3ee,#38bdf8)}
.fill.warm{background:linear-gradient(90deg,#fbbf24,#f59e0b)}
.fill.hot{background:linear-gradient(90deg,#fb7185,#ef4444)}
.foot{color:var(--dim);font-size:12px;margin-top:22px;text-align:center}

/* find files */
.findwrap{margin-bottom:34px}
.idxstat{font-size:12px;color:var(--mut);margin-left:auto;white-space:nowrap}
.idxstat b{color:var(--txt)}
.results{max-height:360px;overflow:auto}
.results .rrow{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid rgba(255,255,255,.05);cursor:pointer;transition:.12s}
.results .rrow:hover{background:rgba(255,255,255,.04)}
.results .rrow:last-child{border-bottom:none}
.results .ri{width:16px;height:16px;flex:0 0 auto;stroke:var(--acc);fill:none;stroke-width:2}
.results .rn{font-weight:600;font-size:13.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:38%}
.results .rd{color:var(--mut);font-family:Consolas,monospace;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;direction:rtl;text-align:left}
.results .ropen{opacity:0;color:var(--acc);font-size:11.5px;font-weight:600}
.results .rrow:hover .ropen{opacity:1}
.results .empty{padding:34px;text-align:center;color:var(--dim);font-size:13px}
.airow{padding:12px 16px;border-bottom:1px solid var(--line);background:linear-gradient(90deg,rgba(56,189,248,.08),transparent);
  font-size:13px;color:var(--txt);display:flex;align-items:center;gap:8px}
.airow .sp{color:var(--acc);font-weight:700}
.airow .pv{margin-left:auto;font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.5px}

/* toasts */
#toasts{position:fixed;right:20px;bottom:20px;display:flex;flex-direction:column;gap:10px;z-index:50}
.toast{background:#141c2b;border:1px solid var(--line2);border-left:3px solid var(--acc);border-radius:11px;
  padding:12px 16px;font-size:13px;box-shadow:var(--shadow);min-width:230px;animation:slide .25s ease}
.toast.err{border-left-color:var(--bad)}
@keyframes slide{from{opacity:0;transform:translateX(20px)}to{opacity:1;transform:none}}
.skel{color:var(--dim);padding:40px;text-align:center}
</style></head>
<body><div class="wrap">

<div class="top">
  <div class="brand">
    <div class="logo"><svg viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/></svg></div>
    <div><h1>Home Network</h1><div class="hostline" id="hostline">connecting...</div></div>
  </div>
  <div class="spacer"></div>
  <div class="pill"><span class="pdot" id="inetDot"></span><span id="inetTxt">Internet</span></div>
  <div class="pill"><b id="clock">--:--</b></div>
  <div class="btn ghost" id="autoBtn" title="Toggle live auto-refresh"><svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-2.6-6.4M21 3v6h-6"/></svg><span>Live</span></div>
  <div class="btn ghost" onclick="load(true)"><svg viewBox="0 0 24 24"><path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.5 9a9 9 0 0 1 14.9-3.4L23 10M1 14l4.6 4.4A9 9 0 0 0 20.5 15"/></svg><span>Refresh</span></div>
  <div class="btn ghost warn" onclick="quit()" title="Stop the dashboard server"><svg viewBox="0 0 24 24"><path d="M18.36 6.64a9 9 0 1 1-12.73 0M12 2v10"/></svg></div>
</div>

<div class="kpis" id="kpis"></div>

<div class="sec"><h2>Find files</h2><div class="ln"></div></div>
<div class="panel findwrap">
  <div class="ptools">
    <div class="search"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
      <input id="fq" placeholder="Search for any file on any drive by name..." autocomplete="off"></div>
    <div class="seg" id="aiseg"><button class="act" data-m="instant">Instant</button><button data-m="ai">Ask AI</button></div>
    <span class="idxstat" id="idxstat">index: loading...</span>
    <div class="btn" onclick="reindex()"><svg viewBox="0 0 24 24"><path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.5 9a9 9 0 0 1 14.9-3.4L23 10M1 14l4.6 4.4A9 9 0 0 0 20.5 15"/></svg>Rebuild index</div>
  </div>
  <div class="results" id="results"><div class="empty">Type at least 2 letters to search across every drive this PC can see.</div></div>
</div>

<div class="sec"><h2>Devices</h2><div class="ln"></div></div>
<div class="devs" id="devs"><div class="skel">Scanning your network...</div></div>

<div class="sec"><h2>Storage</h2><div class="ln"></div></div>
<div class="panel">
  <div class="ptools">
    <div class="search"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
      <input id="q" placeholder="Filter drives by letter or source..."></div>
    <div class="seg" id="seg">
      <button class="act" data-f="all">All</button>
      <button data-f="local">Local</button>
      <button data-f="net">Network</button>
    </div>
  </div>
  <table><thead><tr>
    <th>Drive</th><th>Source</th><th>Usage</th><th class="num">Used</th><th class="num">Free</th><th class="num">Size</th>
  </tr></thead><tbody id="drives"><tr><td colspan="6" class="skel">Reading drives…</td></tr></tbody></table>
</div>

<div class="foot" id="foot"></div>
</div>
<div id="toasts"></div>

<script>
const $=s=>document.querySelector(s), el=(t,c,h)=>{const e=document.createElement(t);if(c)e.className=c;if(h!=null)e.innerHTML=h;return e;};
let AUTO=true, filter='all', DATA=null;

const IC={
  rdp:'<svg viewBox="0 0 24 24"><rect x="2" y="4" width="20" height="14" rx="2"/><path d="M8 21h8"/></svg>',
  share:'<svg viewBox="0 0 24 24"><path d="M4 20h16M4 20V8l8-4 8 4v12M9 20v-6h6v6"/></svg>',
  wol:'<svg viewBox="0 0 24 24"><path d="M18.4 6.6A9 9 0 1 1 5.6 6.6M12 2v10"/></svg>',
  plex:'<svg viewBox="0 0 24 24"><path d="m5 3 14 9-14 9z"/></svg>',
  open:'<svg viewBox="0 0 24 24"><path d="M3 7h6l2 2h10v9a2 2 0 0 1-2 2H3z"/></svg>',
  pwr:'<svg viewBox="0 0 24 24"><path d="M12 2v9"/><path d="M6.6 6.6a8 8 0 1 0 10.8 0"/></svg>'
};
function toast(msg,err){const t=el('div','toast'+(err?' err':''),msg);$('#toasts').appendChild(t);setTimeout(()=>{t.style.opacity=0;setTimeout(()=>t.remove(),300)},3200);}
async function act(params,label){try{const r=await fetch('/api/action?'+params);const j=await r.json();toast(j.msg||label);}catch(e){toast('Action failed',true);}}
function copyIp(ip){navigator.clipboard.writeText(ip).then(()=>toast('Copied '+ip));}

function bar(p){return p>=90?'hot':p>=75?'warm':'cool';}
function tb(gb){return gb>=1024?(gb/1024).toFixed(gb>=10240?0:1)+' TB':gb+' GB';}

function render(d){
  DATA=d;
  $('#hostline').textContent='This machine: '+d.host+'  •  '+d.time;
  $('#clock').textContent=d.time.split('  ').pop();
  const idot=$('#inetDot'), it=$('#inetTxt');
  idot.className='pdot '+(d.internet?'on':'off'); it.textContent=d.internet?'Internet up':'Internet down';

  const on=d.devices.filter(x=>x.up).length;
  const loc=d.drives.filter(x=>!x.network);
  const uTB=loc.reduce((a,x)=>a+(x.totalGB-x.freeGB),0), tTB=loc.reduce((a,x)=>a+x.totalGB,0);
  const fTB=loc.reduce((a,x)=>a+x.freeGB,0);
  const stpct=tTB?Math.round(uTB/tTB*100):0;
  $('#kpis').innerHTML=[
    kpi('Devices',IC.rdp,on+'<small>/'+d.devices.length+' online</small>',on/d.devices.length*100,''),
    kpi('Local storage',IC.open,tb(uTB)+' <small>used</small>',stpct,tb(fTB)+' free of '+tb(tTB)),
    kpi('CPU load','<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M9 2v2M15 2v2M9 20v2M15 20v2M2 9h2M2 15h2M20 9h2M20 15h2"/></svg>',d.cpu+'<small>%</small>',d.cpu,'host processor'),
    kpi('Memory','<svg viewBox="0 0 24 24"><rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 7V4M12 7V4M17 7V4"/></svg>',d.memPct+'<small>%</small>',d.memPct,d.memUsedGB+' / '+d.memTotalGB+' GB'),
    kpi('Uptime','<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/></svg>','<span style="font-size:19px">'+d.uptime+'</span>',null,'since last boot')
  ].join('');

  const devsHtml=d.devices.map(dev=>{
    const b=(l,ok)=>`<span class="chip ${ok?'ok':'no'}"><i></i>${l}</span>`;
    let chips=b('File share',dev.smb)+b('Remote Desktop',dev.rdp);
    if(dev.isPlex)chips+=b('Plex',dev.plex);
    const canWake=!!dev.mac && !dev.up;
    let acts='';
    if(!dev.isLocal){
      acts+=`<div class="btn" ${dev.up?'':'disabled'} onclick="act('do=rdp&ip=${dev.ip}','Remote Desktop')">${IC.rdp}Remote</div>`
        +`<div class="btn" ${dev.up?'':'disabled'} onclick="act('do=share&ip=${dev.ip}','Files')">${IC.share}Files</div>`;
    }
    if(dev.isPlex)acts+=`<div class="btn" ${dev.plex?'':'disabled'} onclick="window.open('http://${dev.ip}:32400/web','_blank')">${IC.plex}Plex</div>`;
    if(!dev.isLocal)acts+=`<div class="btn" ${canWake?'':'disabled'} title="${dev.up?'Already on':(canWake?'Send Wake-on-LAN':'MAC unknown - power PC on once')}" onclick="act('do=wol&mac=${encodeURIComponent(dev.mac)}','Wake')">${IC.wol}Wake</div>`;
    acts+=`<div class="pwrwrap"><div class="btn" ${dev.up?'':'disabled'} onclick="togglePwr(event,this)">${IC.pwr}Power</div>
      <div class="pwrmenu">
        ${dev.isLocal?`<button onclick="pwr('sleep','${dev.ip}',true,'${dev.name}')">Sleep this PC</button>`:''}
        <button onclick="pwr('restart','${dev.ip}',${dev.isLocal},'${dev.name}')">Restart</button>
        <button class="danger" onclick="pwr('shutdown','${dev.ip}',${dev.isLocal},'${dev.name}')">Shut down</button>
      </div></div>`;
    return `<div class="dev ${dev.up?'on':'off'}">
      <div class="dhead"><span class="ring ${dev.up?'on':''}"></span>
        <div><div class="dname">${dev.name}${dev.isLocal?'<span class="thispc">THIS PC</span>':''}</div><div class="drole">${dev.role}</div></div>
        <span class="dstat ${dev.up?'on':'off'}">${dev.up?'ONLINE':'OFFLINE'}</span></div>
      <div class="dip"><span>${dev.ip}</span>
        <svg class="cp" onclick="copyIp('${dev.ip}')" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>
        <span class="lat">${dev.up?(dev.ms+' ms'):'—'}</span></div>
      <div class="chips">${chips}</div>
      <div class="acts">${acts}</div></div>`;
  }).join('');
  if(!document.querySelector('.pwrmenu.open')) $('#devs').innerHTML=devsHtml;

  drawDrives();
  $('#foot').textContent='Home Network control panel • live on '+d.host+' • '+d.drives.length+' drives, '+d.devices.length+' devices monitored';
}
function kpi(label,icon,val,pct,sub){
  return `<div class="kpi"><div class="kh">${icon}<span>${label}</span></div>
    <div class="kv">${val}</div>
    ${pct!=null?`<div class="kbar"><i style="width:${Math.min(100,pct)}%"></i></div>`:''}
    ${sub?`<div class="ksub">${sub}</div>`:''}</div>`;
}
function drawDrives(){
  const q=$('#q').value.toLowerCase();
  let rows=DATA.drives.filter(x=>filter==='all'||(filter==='local'&&!x.network)||(filter==='net'&&x.network));
  rows=rows.filter(x=>(x.letter+' '+x.source).toLowerCase().includes(q));
  $('#drives').innerHTML=rows.length?rows.map(x=>`
    <tr onclick="act('do=open&drive=${x.letter}','Open ${x.letter}:')" title="Open ${x.letter}: in Explorer">
      <td class="dl">${x.letter}:<span class="tag ${x.network?'net':'loc'}">${x.network?'NET':'LOCAL'}</span></td>
      <td class="src">${x.source}</td>
      <td><div class="track"><div class="fill ${bar(x.usedPct)}" style="width:${x.usedPct}%"></div></div></td>
      <td class="num">${x.usedPct}%</td><td class="num">${tb(x.freeGB)}</td><td class="num">${tb(x.totalGB)}</td>
    </tr>`).join(''):'<tr><td colspan="6" class="skel">No drives match.</td></tr>';
}
async function load(manual){
  try{const r=await fetch('/api/status');DATA=await r.json();render(DATA);if(manual)toast('Refreshed');}
  catch(e){$('#hostline').textContent='Server not responding';}
}
function quit(){if(confirm('Stop the dashboard server?')){fetch('/api/quit');document.body.innerHTML='<div class="wrap"><div class="skel" style="margin-top:80px">Dashboard stopped. You can close this tab.<br><br>Re-open it any time with HOME-DASHBOARD.bat</div></div>';}}
function togglePwr(e,btn){e.stopPropagation();const m=btn.nextElementSibling;const wasOpen=m.classList.contains('open');closePwr();if(!wasOpen)m.classList.add('open');}
function closePwr(){document.querySelectorAll('.pwrmenu.open').forEach(m=>m.classList.remove('open'));}
function pwr(dowhat,ip,isLocal,name){
  const label={sleep:'Sleep',restart:'Restart',shutdown:'Shut down'}[dowhat];
  const note=dowhat==='sleep'?'':'\n\nA 5-second warning shows on that PC first.';
  closePwr();
  if(!confirm(label+' '+name+'?'+note))return;
  act('do='+dowhat+'&ip='+ip+(isLocal?'&local=1':''),label);
}
document.addEventListener('click',closePwr);

// ---- Find files ----
let fqTimer=null;
function esc(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function rowHtml(f){
  const safe=f.full.replace(/\\/g,'\\\\').replace(/'/g,"\\'");
  return `<div class="rrow" onclick="reveal('${safe}')">
    <svg class="ri" viewBox="0 0 24 24"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M13 2v7h7"/></svg>
    <span class="rn">${esc(f.name)}</span><span class="rd">${esc(f.dir)}</span><span class="ropen">Open folder</span></div>`;
}
async function search(){
  const q=$('#fq').value.trim();
  if(q.length<2){$('#results').innerHTML='<div class="empty">Type at least 2 letters to search across every drive this PC can see.</div>';return;}
  try{
    const r=await fetch('/api/search?q='+encodeURIComponent(q));const j=await r.json();
    if(!j.results.length){$('#results').innerHTML='<div class="empty">No files matching "'+esc(q)+'". If it is new, hit Rebuild index.</div>';return;}
    $('#results').innerHTML=j.results.map(rowHtml).join('')
      +(j.count>=300?'<div class="empty">Showing first 300 matches - narrow your search to see more.</div>':'');
  }catch(e){$('#results').innerHTML='<div class="empty">Search unavailable.</div>';}
}
async function aisearch(){
  const q=$('#fq').value.trim(); if(q.length<2)return;
  $('#results').innerHTML='<div class="empty">Thinking...</div>';
  try{
    const r=await fetch('/api/aisearch?q='+encodeURIComponent(q));const j=await r.json();
    if(j.error){$('#results').innerHTML='<div class="empty">'+esc(j.msg||'AI search unavailable')+'</div>';return;}
    const head=j.note?`<div class="airow"><span class="sp">AI</span><span>${esc(j.note)}</span>${j.provider?`<span class="pv">via ${esc(j.provider)}</span>`:''}</div>`:'';
    if(!j.results.length){$('#results').innerHTML=head+'<div class="empty">Nothing matched what the AI looked for. Try rephrasing.</div>';return;}
    $('#results').innerHTML=head+j.results.map(rowHtml).join('');
  }catch(e){$('#results').innerHTML='<div class="empty">AI search failed.</div>';}
}
function reveal(full){act('do=reveal&path='+encodeURIComponent(full),'Opening folder');}
function reindex(){fetch('/api/reindex');toast('Rebuilding file index in the background...');setTimeout(idxstat,1500);}
async function idxstat(){
  try{const r=await fetch('/api/indexstat');const j=await r.json();
    if(j.everything){ $('#idxstat').innerHTML='<b>Everything</b> · instant search'; return; }
    const n=(j.count||0).toLocaleString();
    $('#idxstat').innerHTML=j.building?('indexing... <b>'+n+'</b> files so far'):('<b>'+n+'</b> files indexed'+(j.updated?' · '+j.updated.split(' ')[1]:''));
  }catch(e){}
}
let aiMode=false;
$('#aiseg').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;aiMode=(b.dataset.m==='ai');
  [...$('#aiseg').children].forEach(c=>c.classList.toggle('act',c===b));
  $('#fq').placeholder=aiMode?'Ask in plain English, then press Enter  -  e.g. "find my resume"':'Search for any file on any drive by name...';
  $('#results').innerHTML='<div class="empty">'+(aiMode?'Ask a question and press Enter. (Needs an AI key in ai-config.json.)':'Type at least 2 letters to search across every drive this PC can see.')+'</div>';});
$('#fq').addEventListener('keydown',e=>{ if(e.key==='Enter'&&aiMode){ e.preventDefault(); aisearch(); } });
$('#fq').addEventListener('input',()=>{ if(aiMode)return; clearTimeout(fqTimer);fqTimer=setTimeout(search,220);});
setInterval(idxstat,4000); idxstat();

$('#q').addEventListener('input',()=>DATA&&drawDrives());
$('#seg').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;filter=b.dataset.f;[...$('#seg').children].forEach(c=>c.classList.toggle('act',c===b));drawDrives();});
$('#autoBtn').addEventListener('click',function(){AUTO=!AUTO;this.style.opacity=AUTO?1:.45;toast(AUTO?'Live refresh on':'Live refresh paused');});
setInterval(()=>{const d=new Date();$('#clock').textContent=d.toLocaleTimeString();},1000);
setInterval(()=>AUTO&&load(),8000);
load();
</script>
</body></html>
'@

# ---- HTTP server (raw TCP, no admin / no urlacl needed) --------------------
function Send-Response($ns,[string]$status,[string]$ct,$body){
  $b = if($body -is [byte[]]){ $body } else { [Text.Encoding]::UTF8.GetBytes([string]$body) }
  $head = "HTTP/1.1 $status`r`nContent-Type: $ct`r`nContent-Length: $($b.Length)`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $ns.Write($hb,0,$hb.Length); $ns.Write($b,0,$b.Length); $ns.Flush()
}

try {
  $bindAddr = if($BindLan){ [Net.IPAddress]::Any } else { [Net.IPAddress]::Loopback }
  $listener = [Net.Sockets.TcpListener]::new($bindAddr,$Port)
  $listener.Start()
} catch {
  # Already running on this port — nothing to do, launcher will open the browser.
  exit
}

# ---- Home Brain agent auto-bootstrap (added 2026-07-11) --------------------
# Rides this dashboard's existing auto-sync: when this dashboard starts on any
# PC, it also makes sure the new "Home Brain" agent is running (and, on the
# brain host, that the brain service is up). Fully wrapped so it can never break
# the dashboard. This is why enrolled PCs appear in the Home Brain by themselves.
try {
  $BrainUrl   = 'http://192.168.1.174:8788'
  $BrainToken = 'EOdUyQQwCWW1VXiYgMDdOPseACJQcFdX'
  $hnAppDir   = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard'
  $agentCfg   = Join-Path $hnAppDir 'agent.json'
  $agentDir   = Join-Path $env:ProgramData 'HomeNetDashboard\agent'
  $agentPs    = Join-Path $agentDir 'homedash-agent.ps1'
  New-Item -ItemType Directory -Path $hnAppDir -Force | Out-Null
  New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

  # On the brain host only: make sure the brain service is listening.
  if (Test-Path 'C:\HomeDashboard\brain\brain.py') {
    $brainUp = $false
    try { $brainUp = [bool](Get-NetTCPConnection -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue) } catch {}
    $brainVbs = 'C:\HomeDashboard\brain\start-brain.vbs'
    if (-not $brainUp -and (Test-Path $brainVbs)) { Start-Process wscript.exe -ArgumentList "`"$brainVbs`""; Start-Sleep -Seconds 2 }
  }

  # Write the agent config once (brain address + shared token, LAN only).
  if (-not (Test-Path $agentCfg)) {
    (@{ brain=$BrainUrl; token=$BrainToken; agent=$env:COMPUTERNAME.ToLower(); pollSec=3; allowRaw=$false } | ConvertTo-Json) |
      Set-Content -Path $agentCfg -Encoding UTF8
  }

  # Ensure the agent script is present AND current (hash-compare against the
  # brain's copy). If it changed, restart the running agent so even pre-3.x
  # agents (no self-update) get pulled onto the new code.
  $newAgent = $null
  if (Test-Path 'C:\HomeDashboard\brain\homedash-agent.ps1') { $newAgent = 'C:\HomeDashboard\brain\homedash-agent.ps1' }
  else {
    $tmpAgent = Join-Path $env:TEMP 'homedash-agent.dl.ps1'
    try { Invoke-WebRequest "$BrainUrl/agent" -UseBasicParsing -OutFile $tmpAgent -TimeoutSec 10; $newAgent = $tmpAgent } catch {}
  }
  $agentChanged = $false
  if ($newAgent) {
    $newHash = (Get-FileHash $newAgent -Algorithm MD5).Hash
    $oldHash = if (Test-Path $agentPs) { (Get-FileHash $agentPs -Algorithm MD5).Hash } else { '' }
    if ($newHash -ne $oldHash) { Copy-Item $newAgent $agentPs -Force; $agentChanged = $true }
  }

  # Start the agent if it isn't running; restart it if its code just changed.
  $agentProcs = @()
  try { $agentProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*homedash-agent*' }) } catch {}
  if ($agentChanged -and $agentProcs.Count) {
    $agentProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    $agentProcs = @()
  }
  if (-not $agentProcs.Count -and (Test-Path $agentPs)) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agentPs`""
  }
} catch {}

# Build the file index on first run (or if it's over a day old) so search stays fresh.
$needIndex = $true
if(Test-Path $IndexFile){ $needIndex = ((Get-Date) - (Get-Item $IndexFile).LastWriteTime).TotalHours -ge 24 }
if($needIndex){ Start-Reindex | Out-Null }

$script:running = $true
while($script:running){
  try {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 3000
    $isLoopback = $false
    try { $isLoopback = [Net.IPAddress]::IsLoopback(([Net.IPEndPoint]$client.Client.RemoteEndPoint).Address) } catch {}
    $ns = $client.GetStream()
    $sr = New-Object IO.StreamReader($ns)
    $reqline = $sr.ReadLine()
    $authHeader = ''; $contentLen = 0
    while(($h = $sr.ReadLine())){ if($h -eq ''){ break }
      if($h -imatch '^Authorization:\s*(.+)$'){ $authHeader = $Matches[1].Trim() }
      elseif($h -imatch '^Content-Length:\s*(\d+)'){ $contentLen = [int]$Matches[1] } }
    if(-not $reqline){ $client.Close(); continue }
    $reqBody = ''
    if($contentLen -gt 0 -and $contentLen -lt 1000000){ $buf = New-Object char[] $contentLen; $n = $sr.Read($buf,0,$contentLen); if($n -gt 0){ $reqBody = -join $buf[0..($n-1)] } }

    # Password gate (only when a password is configured, i.e. LAN mode).
    # Loopback (this host via http://localhost:8787) is trusted and skips the password;
    # every other client on the network must still authenticate.
    if($AuthPass -and -not $isLoopback){
      $okAuth = $false
      if($authHeader -imatch '^Basic\s+(.+)$'){
        try { $dec=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])); $pw=($dec -split ':',2)[1]; if($pw -eq $AuthPass){ $okAuth=$true } } catch {}
      }
      if(-not $okAuth){
        $b=[Text.Encoding]::UTF8.GetBytes('Home Network Dashboard - password required')
        $head="HTTP/1.1 401 Unauthorized`r`nWWW-Authenticate: Basic realm=""Home Network Dashboard""`r`nContent-Type: text/plain`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n"
        $hb=[Text.Encoding]::ASCII.GetBytes($head); $ns.Write($hb,0,$hb.Length); $ns.Write($b,0,$b.Length); $ns.Flush(); $client.Close(); continue
      }
    }

    $url  = ($reqline -split ' ')[1]
    $path = ($url -split '\?',2)[0]
    $qs = @{}
    if($url -match '\?'){
      foreach($kv in (($url -split '\?',2)[1] -split '&')){
        if($kv){ $p = $kv -split '=',2; $qs[$p[0]] = [Uri]::UnescapeDataString(($p[1] -replace '\+',' ')) }
      }
    }

    switch -Regex ($path){
      '^/api/status'  { $snap = Get-Snapshot; Add-History $snap; Send-Response $ns "200 OK" "application/json" ($snap | ConvertTo-Json -Depth 6 -Compress) }
      '^/api/history' { $hj = if(Test-Path $HistoryFile){ Get-Content -Raw -Encoding UTF8 $HistoryFile } else { '{"samples":[]}' }; Send-Response $ns "200 OK" "application/json" $hj }
      '^/api/search'  {
        $q = [string]$qs['q']
        if($q.Length -lt 2){ Send-Response $ns "200 OK" "application/json" '{"results":[],"count":0,"engine":"none"}' }
        else {
          $ev = Search-Everything $q
          if($ev.ok){ $r = @($ev.results); $eng = 'everything' } else { $r = @(Search-Index $q); $eng = 'index' }
          Send-Response $ns "200 OK" "application/json" (@{results=$r; count=$r.Count; engine=$eng} | ConvertTo-Json -Depth 4 -Compress)
        }
      }
      '^/api/aistatus' { $order = @(Get-AiOrder (Get-AiConfig)); Send-Response $ns "200 OK" "application/json" (@{ ready=($order.Count -gt 0); provider=$(if($order.Count){$order[0].name}else{''}); chain=@($order | ForEach-Object { $_.name }) } | ConvertTo-Json -Compress) }
      '^/api/aisearch' {
        $q = [string]$qs['q']
        if($q.Length -lt 2){ Send-Response $ns "200 OK" "application/json" '{"results":[],"count":0}' }
        else {
          $order = @(Get-AiOrder (Get-AiConfig))
          if($order.Count -eq 0){ Send-Response $ns "200 OK" "application/json" (@{ error='no-key'; msg='Add an AI key to ai-config.json to enable AI search.' } | ConvertTo-Json -Compress) }
          else {
            $a = Search-AiQuery $q
            if($a){ Send-Response $ns "200 OK" "application/json" (@{ results=@($a.results); count=@($a.results).Count; note=$a.note; queries=$a.queries; provider=$a.provider } | ConvertTo-Json -Depth 4 -Compress) }
            else { Send-Response $ns "200 OK" "application/json" (@{ error='ai-failed'; msg='All AI providers failed - check keys/credit in ai-config.json.' } | ConvertTo-Json -Compress) }
          }
        }
      }
      '^/api/reindex' { $ok = Start-Reindex; Send-Response $ns "200 OK" "application/json" (@{started=$ok} | ConvertTo-Json -Compress) }
      '^/api/indexstat' {
        $st = if(Test-Path $IndexStat){ Get-Content -Raw $IndexStat | ConvertFrom-Json } else { $null }
        $obj = @{ building=[bool]($st.building); count=[int]($st.count); updated=[string]($st.updated); everything=(Test-Everything) }
        Send-Response $ns "200 OK" "application/json" ($obj | ConvertTo-Json -Compress)
      }
      '^/api/keys' {
        $cfg = Get-AiConfig; if(-not $cfg){ $cfg = New-DefaultAiConfig }
        $provs = @()
        foreach($n in $cfg.providers.PSObject.Properties.Name){ $pp=$cfg.providers.$n; $k=[string]$pp.key
          $provs += @{ id=$n; model=$pp.model; hasKey=[bool]($k -and $k.Trim()); masked=$(if($k -and $k.Length -gt 8){ $k.Substring(0,4)+'...'+$k.Substring($k.Length-4) }else{''}) } }
        Send-Response $ns "200 OK" "application/json" (@{ providers=$provs; default=[string]$cfg.default } | ConvertTo-Json -Depth 4 -Compress)
      }
      '^/api/setkey' {
        $ok=$false; $msg='bad request'
        try {
          $bd = $reqBody | ConvertFrom-Json
          $cfg = Get-AiConfig; if(-not $cfg){ $cfg = New-DefaultAiConfig }
          if($bd.provider -and ($cfg.providers.PSObject.Properties.Name -contains $bd.provider)){
            if($null -ne $bd.key){ $cfg.providers.$($bd.provider).key = [string]$bd.key }
            if($bd.setDefault){ $cfg.default = [string]$bd.provider }
            New-Item -ItemType Directory -Path (Split-Path $AiConfigFile) -Force | Out-Null
            $cfg | ConvertTo-Json -Depth 5 | Set-Content $AiConfigFile -Encoding UTF8
            $ok=$true; $msg='saved'
          } else { $msg='unknown provider' }
        } catch { $msg='bad json' }
        Send-Response $ns "200 OK" "application/json" (@{ ok=$ok; msg=$msg } | ConvertTo-Json -Compress)
      }
      '^/api/setpeer' {
        $ok=$false
        try {
          $bd = $reqBody | ConvertFrom-Json
          if($bd.ip -match '^\d{1,3}(\.\d{1,3}){3}$'){
            $peers = if(Test-Path $PeersFile){ try { Get-Content -Raw $PeersFile | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
            $peers | Add-Member -NotePropertyName $bd.ip -NotePropertyValue ([string]$bd.peer) -Force
            New-Item -ItemType Directory -Path (Split-Path $PeersFile) -Force | Out-Null
            $peers | ConvertTo-Json | Set-Content $PeersFile -Encoding UTF8
            $script:cache = $null
            $ok=$true
          }
        } catch {}
        Send-Response $ns "200 OK" "application/json" (@{ ok=$ok } | ConvertTo-Json -Compress)
      }
      '^/api/ls' {
        $lp = $qs['path']; $items=@(); $err=''
        if($lp -and (Test-Path -LiteralPath $lp)){
          try {
            foreach($di in @(Get-ChildItem -LiteralPath $lp -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 4000)){
              $items += @{ name=$di.Name; dir=$true; full=$di.FullName; size=0 } }
            foreach($fi in @(Get-ChildItem -LiteralPath $lp -File -Force -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 4000)){
              $items += @{ name=$fi.Name; dir=$false; full=$fi.FullName; size=[int64]$fi.Length } }
          } catch { $err='Cannot read this folder' }
        } else { $err='Path not found or unreachable' }
        Send-Response $ns "200 OK" "application/json" (@{ path=$lp; items=$items; err=$err } | ConvertTo-Json -Depth 4 -Compress)
      }
      '^/api/action'  { $m = Invoke-Action $qs; Send-Response $ns "200 OK" "application/json" (@{msg=$m} | ConvertTo-Json -Compress) }
      '^/api/quit'    { Send-Response $ns "200 OK" "application/json" '{"ok":true}'; $script:running=$false; $listener.Stop() }
      '^/$'           {
        # Retired 2026-07-11: this old dashboard now just redirects to Home Brain
        # (port 8788). It keeps running only to auto-start the agent on this PC.
        $redir = @'
<!doctype html><html><head><meta charset="utf-8"><title>Home Brain</title></head>
<body style="background:#0a0e17;color:#e9eef7;font-family:system-ui,Arial,sans-serif;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center"><div style="font-size:42px">&#129504;</div><p>Taking you to your dashboard&hellip;</p>
<p><a id="l" style="color:#38bdf8" href="#">Open Home Brain</a></p></div>
<script>var u='http://'+location.hostname+':8788'+location.search;document.getElementById('l').href=u;location.replace(u);</script>
</body></html>
'@
        Send-Response $ns "200 OK" "text/html; charset=utf-8" $redir }
      default         { Send-Response $ns "404 Not Found" "text/plain" "Not found" }
    }
    $client.Close()
  } catch { if(-not $script:running){ break } }
}
try { $listener.Stop() } catch {}
