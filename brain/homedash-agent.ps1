# ============================================================================
#  Home Network Dashboard - PER-PC AGENT  (3.x "bulletproof")
#  Polls the brain for jobs, runs them locally in the user session (so winget,
#  VLC and piactl work), reports results, and sends a live heartbeat each poll.
#  Config lives in %LOCALAPPDATA%\HomeNetDashboard\agent.json (written by
#  bootstrap.ps1) and is NEVER synced. Outbound-only: works behind PIA/NAT.
#
#  3.x additions:
#   - $AGENT_VERSION reported in every heartbeat; self-updates when the brain
#     serves a newer agent (poll response carries the expected version).
#   - Self-registers its own startup (HKCU Run key -> start-agent.vbs), plus
#     the brain's startup on the brain host. No admin needed.
#   - Watchdog tick every 60s: revives the local launcher (:8799) and, on the
#     brain host, the brain itself (:8788) - even while the brain is down.
#   - Single-instance guard (no more duplicate agents).
# ============================================================================
param([switch]$Updated)   # set when relaunched by self-update (skips the guard race)
$ErrorActionPreference = "Stop"
$AGENT_VERSION = '3.9.6'

# ---- Single-instance guard ---------------------------------------------------
if (-not $Updated) {
  try {
    $twin = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*homedash-agent*' }
    if ($twin) { exit 0 }
  } catch {}
}

# ---- Config ----------------------------------------------------------------
$CfgFile = Join-Path $env:LOCALAPPDATA "HomeNetDashboard\agent.json"
if (-not (Test-Path $CfgFile)) {
  Write-Host "No agent config at $CfgFile - run bootstrap.ps1 first." ; exit 1
}
$Cfg    = Get-Content -Raw $CfgFile | ConvertFrom-Json
$Brain  = $Cfg.brain.TrimEnd('/')          # e.g. http://192.168.1.174:8788
$Token  = [string]$Cfg.token
$Agent  = if ($Cfg.agent) { [string]$Cfg.agent } else { $env:COMPUTERNAME.ToLower() }
$PollSec = if ($Cfg.pollSec) { [int]$Cfg.pollSec } else { 3 }
$AllowRaw = $true                          # GOD MODE: dashboard may run ANY command on this PC (fleet-wide, opted in 2026-07-23). Was: [bool]$Cfg.allowRaw

$IsBrainHost = Test-Path 'C:\HomeDashboard\brain\brain.py'
$LauncherPs  = Join-Path (Split-Path $CfgFile) 'homedash-launcher.ps1'
$AliveFile   = Join-Path (Split-Path $CfgFile) 'agent-alive.txt'   # heartbeat marker the launcher watches (detects a HUNG agent, not just a missing one)

# winget's PATH alias isn't resolvable in every session (Run-key/service context),
# so find the real exe once. Without this, remote installs fail "not recognized".
function Get-WinGet {
  $c = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path $alias) { return $alias }
  try {
    $real = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
    if ($real) { return $real.FullName }
  } catch {}
  return $null
}
$WinGet = Get-WinGet

# Run winget non-interactively and BOUNDED so it can never hang the agent loop.
# (winget waits on prompts when there's no terminal; --disable-interactivity +
#  a hard timeout keep the heartbeat alive.)
function Invoke-WinGet([string[]]$wargs, [int]$timeoutSec = 180) {
  if (-not $WinGet) { return @{ ok=$false; exit=-1; stdout=''; stderr='winget not found on this PC' } }
  $o = Join-Path $env:TEMP ('wg_' + [guid]::NewGuid().ToString('N') + '.out')
  $e = "$o.err"
  try {
    $p = Start-Process $WinGet -ArgumentList (@($wargs) + '--disable-interactivity') -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
      try { $p.Kill() } catch {}
      $t = if (Test-Path $o) { Get-Content -Raw $o } else { '' }
      return @{ ok=$false; exit=-1; stdout=$t; stderr="winget timed out after ${timeoutSec}s" }
    }
    $t  = if (Test-Path $o) { Get-Content -Raw $o } else { '' }
    $er = if (Test-Path $e) { Get-Content -Raw $e } else { '' }
    return @{ ok=($p.ExitCode -eq 0); exit=$p.ExitCode; stdout=$t; stderr=$er }
  } finally {
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
  }
}

$StConfigDir = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\syncthing-config'
function Get-SyncthingExe {
  $c = Get-Command syncthing.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $link = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\syncthing.exe"
  if (Test-Path $link) { return $link }
  @("$env:LOCALAPPDATA\Programs\syncthing\syncthing.exe",
    "$env:ProgramFiles\Syncthing\syncthing.exe") | ForEach-Object {
      Get-ChildItem $_ -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  } | Where-Object { $_ } | Select-Object -First 1 -OutVariable found | Out-Null
  if ($found) { return $found[0] }
  # winget nests the real exe under an extra version-named subfolder, e.g.
  # ...\Packages\Syncthing.Syncthing_...\syncthing-windows-amd64-vX.Y.Z\syncthing.exe
  Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Syncthing.Syncthing_*" -Filter 'syncthing.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
function Get-StApiKey {
  $cfgFile = Join-Path $StConfigDir 'config.xml'
  if (-not (Test-Path $cfgFile)) { return $null }
  try { return ([xml](Get-Content -Raw $cfgFile)).configuration.gui.apikey } catch { return $null }
}
function Invoke-StApi([string]$method, [string]$path, $body) {
  $key = Get-StApiKey
  if (-not $key) { throw "syncthing not configured yet" }
  $h = @{ 'X-API-Key' = $key }
  $u = "http://127.0.0.1:8384$path"
  try {
    if ($null -ne $body) {
      return Invoke-RestMethod $u -Method $method -Headers $h -Body ($body | ConvertTo-Json -Depth 10 -Compress) -ContentType 'application/json' -TimeoutSec 15
    }
    return Invoke-RestMethod $u -Method $method -Headers $h -TimeoutSec 15
  } catch {
    # Surface the REST body (Syncthing's actual reason) - the bare status line is useless.
    $detail = ''
    try { $detail = $_.ErrorDetails.Message } catch {}
    throw "$method $path -> $($_.Exception.Message) :: $detail"
  }
}

$PiaExe = "C:\Program Files\Private Internet Access\piactl.exe"
$VlcExe = @("C:\Program Files\VideoLAN\VLC\vlc.exe",
            "C:\Program Files (x86)\VideoLAN\VLC\vlc.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1

# Allow-list for the 'run' job type (safe read-only diagnostics by default).
$AllowedRun = @('ipconfig','hostname','whoami','systeminfo','tasklist','ver',
                'echo','ping','nslookup','getmac','wmic','powercfg','sc','net')

$Headers = @{ 'X-Brain-Token' = $Token; 'Content-Type' = 'application/json' }

function Post($route, $obj) {
  $json = ($obj | ConvertTo-Json -Depth 8 -Compress)
  return Invoke-RestMethod "$Brain$route" -Method Post -Headers $Headers -Body $json -TimeoutSec 30
}

function Test-LocalPort([int]$port) {
  try {
    $t = New-Object Net.Sockets.TcpClient
    $ok = $t.BeginConnect('127.0.0.1', $port, $null, $null).AsyncWaitHandle.WaitOne(400)
    $t.Close(); return [bool]$ok
  } catch { return $false }
}

# ---- Self-reliance: persistence + watchdogs ---------------------------------
$script:LauncherUp = $false
$script:PersistOk  = $false
$script:ExpectedVer = ''   # agent version the brain currently serves (from /poll)

function Reap-Duplicates {
  # A failed/partial self-update can leave a STALE agent process running the old
  # code alongside the new one - both poll as the same agent id, so the brain's
  # reported version flaps and the dashboard shows an endless "updating". Once we
  # are on the version the brain serves, WE are the healthy instance: kill every
  # other homedash-agent process so exactly one (this one) survives. Only the
  # up-to-date instance reaps, so an old zombie never kills the good one, and a
  # mid-update -Updated handoff (old exits on its own) is left alone.
  if (-not $script:ExpectedVer -or $AGENT_VERSION -ne $script:ExpectedVer) { return }
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*homedash-agent*' } |
      ForEach-Object {
        Write-Host "[$Agent] reaping duplicate agent PID $($_.ProcessId)"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
      }
  } catch {}
}

function Ensure-Persistence {
  # HKCU Run keys (no admin): agent on every PC, brain on the brain host.
  # The .vbs starter keeps it invisible (no console flash at logon).
  try {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $vbs = Join-Path (Split-Path -Parent $PSCommandPath) 'start-agent.vbs'
    $vbsBody = 'CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $PSCommandPath + '""", 0, False'
    $cur = ''
    try { $cur = Get-Content -Raw $vbs -ErrorAction SilentlyContinue } catch {}
    if (($cur -as [string]).Trim() -ne $vbsBody) { Set-Content -Path $vbs -Value $vbsBody -Encoding ASCII }
    Set-ItemProperty -Path $runKey -Name 'HomeDashAgent' -Value "wscript.exe `"$vbs`""
    if ($IsBrainHost -and (Test-Path 'C:\HomeDashboard\brain\start-brain.vbs')) {
      Set-ItemProperty -Path $runKey -Name 'HomeDashBrain' -Value "wscript.exe `"C:\HomeDashboard\brain\start-brain.vbs`""
    }
    $chk = (Get-ItemProperty -Path $runKey -Name 'HomeDashAgent' -ErrorAction SilentlyContinue).HomeDashAgent
    $script:PersistOk = ($chk -eq "wscript.exe `"$vbs`"")
  } catch { $script:PersistOk = $false }
  return $script:PersistOk
}

function Start-Launcher {
  # Keep the launcher file fresh from the brain, then start it if the port is dead.
  try { Invoke-WebRequest "$Brain/launcher" -UseBasicParsing -OutFile $LauncherPs -TimeoutSec 15 } catch {}
  if (Test-Path $LauncherPs) {
    Start-Process wscript.exe -WindowStyle Hidden -ArgumentList '"C:\Users\BigBory\AppData\Local\HomeNetDashboard\start-launcher.vbs"'
  }
}

function Start-Brain {
  $bvbs = 'C:\HomeDashboard\brain\start-brain.vbs'
  if (Test-Path $bvbs) { Start-Process wscript.exe -ArgumentList "`"$bvbs`"" }
  elseif (Test-Path 'C:\Python313\python.exe') {
    Start-Process 'C:\Python313\python.exe' -WindowStyle Hidden -ArgumentList '"C:\HomeDashboard\brain\brain.py"'
  }
}

function Maintain {
  $script:LauncherUp = Test-LocalPort 8799
  if (-not $script:LauncherUp) { Start-Launcher; $script:LauncherUp = Test-LocalPort 8799 }
  if ($IsBrainHost -and -not (Test-LocalPort 8788)) {
    Write-Host "[$Agent] brain is down - restarting it"
    Start-Brain
  }
  if (-not $script:PersistOk) { Ensure-Persistence | Out-Null }
  Reap-Duplicates
}

function Update-Self([string]$expected) {
  # The brain serves a different agent version -> replace this script + relaunch.
  $tmp = "$PSCommandPath.new"
  try {
    Invoke-WebRequest "$Brain/agent" -UseBasicParsing -OutFile $tmp -TimeoutSec 30
    $txt = Get-Content -Raw $tmp
    if ($txt -notmatch "AGENT_VERSION\s*=\s*'([^']+)'") { Remove-Item $tmp -Force; return $false }
    $newVer = $Matches[1]
    if ($newVer -eq $AGENT_VERSION) { Remove-Item $tmp -Force; return $false }   # nothing actually new
    # This process holds its own script file open for its entire run (confirmed:
    # even a plain delete of a live agent's own .ps1 fails with "Access is denied"),
    # so it can never overwrite/replace that file in place - every prior self-update
    # attempt silently failed this way on every PC that was never manually restarted.
    # Hand the actual file swap to a DETACHED helper that waits for this process to
    # fully exit (releasing the lock) before touching the file.
    Write-Host "[$Agent] self-updating $AGENT_VERSION -> $newVer - handing off to updater"
    $helper = "timeout /t 3 /nobreak >nul & move /y `"$tmp`" `"$PSCommandPath`" >nul & start `"`" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Updated"
    Start-Process cmd.exe -ArgumentList "/c $helper" -WindowStyle Hidden
    return $true
  } catch {
    try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
}

# ---- Heartbeat: live snapshot of this PC ------------------------------------
function Get-Stats {
  $s = @{}
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $s.cpu = [int]$cpu
    $s.mem = if ($os.TotalVisibleMemorySize) {
      [int][math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100) } else { 0 }
    $up = (Get-Date) - $os.LastBootUpTime
    $s.uptime = "{0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes
  } catch {}
  # Drives. LOCAL disks via .NET DriveInfo — a fast local syscall (no WMI, no
  # timeout flakiness), so local drives ALWAYS report. Cached so a transient
  # blip never blanks them. NETWORK drives are best-effort via CIM with a short
  # timeout — a hung mapped drive (busy server) can't stall the heartbeat.
  $drives = @()
  try {
    foreach ($di in [System.IO.DriveInfo]::GetDrives()) {
      if ($di.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
      if (-not $di.IsReady) { continue }
      $tot = [double]$di.TotalSize; if ($tot -le 0) { continue }
      $free = [double]$di.TotalFreeSpace
      $drives += @{ letter = ($di.Name -replace '[:\\]',''); freeGB = [math]::Round($free/1GB); totalGB = [math]::Round($tot/1GB)
                    usedPct = [math]::Round((($tot-$free)/$tot)*100); network = $false; source = 'Local disk' }
    }
    if ($drives.Count) { $script:LastLocal = $drives }
  } catch {}
  if (-not $drives.Count -and $script:LastLocal) { $drives = @($script:LastLocal) }
  try {
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=4' -OperationTimeoutSec 3 -ErrorAction Stop | Where-Object { [double]$_.Size -gt 0 })) {
      $tot = [double]$d.Size; $free = [double]$d.FreeSpace
      $drives += @{ letter = $d.DeviceID.TrimEnd(':'); freeGB = [math]::Round($free/1GB); totalGB = [math]::Round($tot/1GB)
                    usedPct = [math]::Round((($tot-$free)/$tot)*100); network = $true; source = $(if($d.ProviderName){[string]$d.ProviderName}else{'Network drive'}) }
    }
  } catch {}
  $s.drives = $drives
  $s.pia = Get-PiaState
  $s.host = $env:COMPUTERNAME
  $s.ver = $AGENT_VERSION
  $s.launcher = $script:LauncherUp
  $s.persist = $script:PersistOk
  # Real LAN IPv4 (for Remote/Files buttons) - skip VPN/APIPA/loopback.
  try {
    $s.lanip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' -or $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.' } |
      Select-Object -First 1).IPAddress
  } catch {}
  # MAC of the active adapter (stored by the brain so Wake-on-LAN works while offline).
  try { $s.mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).MacAddress } catch {}
  return $s
}

function Get-PiaState {
  if (-not (Test-Path $PiaExe)) { return 'not-installed' }
  try { return (& $PiaExe get connectionstate 2>$null | Select-Object -First 1) } catch { return 'unknown' }
}
function Get-TailscaleIp {
  try { $ip = (& tailscale ip -4 2>$null | Select-Object -First 1); if ($ip) { return $ip.Trim() } } catch {}
  return ''
}

# ---- Job handlers -----------------------------------------------------------
function Run-Cmd([string]$cmd) {
  $out = & cmd.exe /c $cmd 2>&1 | Out-String
  return @{ ok = ($LASTEXITCODE -eq 0); exit = $LASTEXITCODE; stdout = $out; stderr = '' }
}

function Handle-Job($job) {
  $a = $job.args
  switch ($job.type) {

    'run' {
      $cmd = [string]$a.cmd
      $first = ($cmd.Trim() -split '\s+')[0].ToLower()
      if (-not $AllowRaw -and ($AllowedRun -notcontains $first)) {
        return @{ ok = $false; exit = -1; stdout = ''; stderr = "'$first' is not allow-listed on this agent" }
      }
      return Run-Cmd $cmd
    }

    'install' {
      $id = [string]$a.id
      if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        return @{ ok = $false; exit = -1; stdout = ''; stderr = "bad package id" }
      }
      $mgr = if ($a.manager) { [string]$a.manager } else { 'winget' }
      if ($mgr -eq 'choco') {
        return Run-Cmd "choco install $id -y"
      }
      return Invoke-WinGet @('install','--silent','--accept-package-agreements','--accept-source-agreements','--id',$id) 300
    }

    'pia' {
      if (-not (Test-Path $PiaExe)) { return @{ ok=$false; exit=-1; stdout=''; stderr='PIA not installed' } }
      switch ([string]$a.action) {
        'on'     { & $PiaExe connect | Out-Null;    return @{ ok=$true; exit=0; stdout=(Get-PiaState); stderr='' } }
        'off'    { & $PiaExe disconnect | Out-Null; return @{ ok=$true; exit=0; stdout=(Get-PiaState); stderr='' } }
        'status' { return @{ ok=$true; exit=0; stdout=(Get-PiaState); stderr='' } }
        'region' { & $PiaExe set region $([string]$a.region) | Out-Null; return @{ ok=$true; exit=0; stdout=(& $PiaExe get region); stderr='' } }
        'harden' { & $PiaExe background enable | Out-Null; & $PiaExe set allowlan true | Out-Null; return @{ ok=$true; exit=0; stdout='background+allowlan enabled'; stderr='' } }
        default  { return @{ ok=$false; exit=-1; stdout=''; stderr='unknown pia action' } }
      }
    }

    'play' {
      if (-not $VlcExe) { return @{ ok=$false; exit=-1; stdout=''; stderr='VLC not installed' } }
      $url = [string]$a.url
      if ($url -notmatch '^https?://') { return @{ ok=$false; exit=-1; stdout=''; stderr='bad url' } }
      $vargs = @("`"$url`"")
      if ($a.startSec -and [int]$a.startSec -gt 0) { $vargs += "--start-time=$([int]$a.startSec)" }  # continue watching
      Start-Process $VlcExe -ArgumentList $vargs
      return @{ ok=$true; exit=0; stdout='launched VLC'; stderr='' }
    }

    'open' {
      # Resolve app by name first, fall back to path
      $app = [string]$a.app
      $path = [string]$a.path

      $appPaths = @{
        'claude'        = @("$env:LOCALAPPDATA\Programs\Claude\Claude.exe", "C:\Program Files\Claude\Claude.exe")
        'code'          = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe", "C:\Program Files\Microsoft VS Code\Code.exe")
        'vscode'        = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe", "C:\Program Files\Microsoft VS Code\Code.exe")
        'discord'       = @("$env:LOCALAPPDATA\Discord\app-*\Discord.exe", "$env:ProgramFiles\Discord\Discord.exe")
        'chrome'        = @("C:\Program Files\Google\Chrome\Application\chrome.exe", "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe")
        'vlc'           = @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "$env:ProgramFiles (x86)\VideoLAN\VLC\vlc.exe")
        'notepad'       = @("C:\Windows\notepad.exe")
        'explorer'      = @("C:\Windows\explorer.exe")
      }

      # Try app name resolution first
      if ($app) {
        $appLower = $app.ToLower()
        if ($appPaths.ContainsKey($appLower)) {
          foreach ($p in $appPaths[$appLower]) {
            $exe = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { Start-Process $exe.FullName; return @{ ok=$true; exit=0; stdout="opened $app"; stderr='' } }
          }
          return @{ ok=$false; exit=-1; stdout=''; stderr="$app not found on this PC" }
        }
        # Treat unrecognized app name as a direct exe name search
        try {
          $cmd = Get-Command $appLower -ErrorAction SilentlyContinue
          if ($cmd) { Start-Process $cmd.Source; return @{ ok=$true; exit=0; stdout="opened $app"; stderr='' } }
        } catch {}
      }

      # Fall back to path-based open
      if ($path -and (Test-Path -LiteralPath $path)) {
        Start-Process explorer.exe -ArgumentList "`"$path`"";
        return @{ ok=$true; exit=0; stdout="opened $path"; stderr='' }
      }

      return @{ ok=$false; exit=-1; stdout=''; stderr='no app name or path given' }
    }

    'power' {
      switch ([string]$a.action) {
        'sleep'    { Start-Process rundll32.exe -ArgumentList "powrprof.dll,SetSuspendState 0,1,0"; return @{ ok=$true; exit=0; stdout='sleeping'; stderr='' } }
        'restart'  { Start-Process shutdown.exe -ArgumentList "/r","/t","5","/f" -WindowStyle Hidden; return @{ ok=$true; exit=0; stdout='restarting in 5s'; stderr='' } }
        'shutdown' { Start-Process shutdown.exe -ArgumentList "/s","/t","5","/f" -WindowStyle Hidden; return @{ ok=$true; exit=0; stdout='shutting down in 5s'; stderr='' } }
        default    { return @{ ok=$false; exit=-1; stdout=''; stderr='unknown power action' } }
      }
    }

    'copy' {
      try { Copy-Item -LiteralPath $a.src -Destination $a.dst -Recurse -Force -ErrorAction Stop
            return @{ ok=$true; exit=0; stdout="copied"; stderr='' } }
      catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'listdir' {
      # List one folder (for the dashboard's file browser). Bounded at 500 entries.
      $path = [string]$a.path
      if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @{ ok=$false; exit=-1; stdout=''; stderr='path not found' } }
      $items = @(); $n = 0
      foreach ($e in (Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
        $items += @{ name = $e.Name; dir = [bool]$e.PSIsContainer
                     sizeMB = $(if ($e.PSIsContainer) { $null } else { [math]::Round($e.Length/1MB, 2) })
                     mod = $e.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $n++; if ($n -ge 500) { break }
      }
      return @{ ok=$true; exit=0; stdout=(@($items) | ConvertTo-Json -Depth 4 -Compress); stderr='' }
    }

    'fsearch' {
      # Recursive filename search under a root (for the Drive browser). Bounded:
      # max hits + 20s wall clock so a huge cloud mount can't hang the agent loop.
      $root = [string]$a.root; $q = ([string]$a.q).ToLower()
      if (-not $root -or -not (Test-Path -LiteralPath $root) -or $q.Length -lt 2) { return @{ ok=$false; exit=-1; stdout=''; stderr='root + q (2+ chars) required' } }
      $max = if ($a.max) { [int]$a.max } else { 200 }
      $hits = @(); $sw = [Diagnostics.Stopwatch]::StartNew()
      $queue = New-Object Collections.Generic.Queue[string]; $queue.Enqueue($root)
      while ($queue.Count -and $hits.Count -lt $max -and $sw.Elapsed.TotalSeconds -lt 20) {
        $dir = $queue.Dequeue()
        foreach ($e in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
          if ($e.PSIsContainer) { $queue.Enqueue($e.FullName) }
          if ($e.Name.ToLower().Contains($q)) {
            $hits += @{ name = $e.Name; path = $e.FullName; dir = [bool]$e.PSIsContainer }
            if ($hits.Count -ge $max) { break }
          }
        }
      }
      return @{ ok=$true; exit=0; stdout=(@($hits) | ConvertTo-Json -Depth 4 -Compress); stderr='' }
    }

    'delete' {
      # Delete a file/folder (dashboard right-click). Refuses drive roots.
      $p = [string]$a.path
      if ($p -match '^[A-Za-z]:[\\/]?\s*$') { return @{ ok=$false; exit=-1; stdout=''; stderr='refusing to delete a drive root' } }
      if (-not (Test-Path -LiteralPath $p)) { return @{ ok=$false; exit=-1; stdout=''; stderr='path not found' } }
      try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            return @{ ok=$true; exit=0; stdout="deleted $p"; stderr='' } }
      catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }
    'move' {
      # Move-Item -Force unreliably overwrites an existing destination file on
      # Windows PowerShell - delete the destination first so Move-Item never
      # has to overwrite anything.
      try {
        if (Test-Path -LiteralPath $a.dst) { Remove-Item -LiteralPath $a.dst -Force -ErrorAction Stop }
        Move-Item -LiteralPath $a.src -Destination $a.dst -Force -ErrorAction Stop
        return @{ ok=$true; exit=0; stdout="moved"; stderr='' } }
      catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'status' { $st = Get-Stats; return @{ ok=$true; exit=0; stdout=($st | ConvertTo-Json -Depth 6 -Compress); stderr='' } }

    'fetch' {
      # download a staged file from the brain to a local dest
      $url = [string]$a.url; $dest = [string]$a.dest
      if (-not $url -or -not $dest) { return @{ ok=$false; exit=-1; stdout=''; stderr='url+dest required' } }
      try {
        $dir = Split-Path $dest -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $h = @{ 'X-Brain-Token' = [string]$a.token }
        Invoke-WebRequest $url -Headers $h -OutFile $dest -UseBasicParsing
        return @{ ok=$true; exit=0; stdout="saved $dest"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'transfer' {
      # push a local file to another PC by staging it through the brain
      $src = [string]$a.src
      if (-not (Test-Path -LiteralPath $src)) { return @{ ok=$false; exit=-1; stdout=''; stderr='source gone' } }
      try {
        $leaf = Split-Path $src -Leaf
        $u = "$Brain/upload?name=$([uri]::EscapeDataString($leaf))&agent=$([uri]::EscapeDataString([string]$a.toAgent))&path=$([uri]::EscapeDataString([string]$a.dest))"
        Invoke-RestMethod $u -Method Post -Headers @{ 'X-Brain-Token' = $Token } -InFile $src | Out-Null
        return @{ ok=$true; exit=0; stdout="sent $leaf to $($a.toAgent)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'backup' {
      # rclone copy src -> remote (additive). rclone must be installed.
      if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { return @{ ok=$false; exit=-1; stdout=''; stderr='rclone not installed' } }
      $src = [string]$a.src; $remote = [string]$a.remote
      $out = & rclone copy "$src" "$remote" --stats-one-line --log-level INFO 2>&1 | Out-String
      return @{ ok = ($LASTEXITCODE -eq 0); exit = $LASTEXITCODE; stdout = $out; stderr = '' }
    }

    'applist' { return Invoke-WinGet @('list','--accept-source-agreements') 90 }
    'updates' { return Invoke-WinGet @('upgrade','--accept-source-agreements') 90 }

    'syncthing' {
      # Real-time bidirectional sync of C:\HomeShare across every enrolled PC.
      # 'bootstrap' = install + generate identity, returns this PC's device ID.
      # 'pair'      = wire this PC up to trust + share HomeShare with every peer ID given.
      # 'status'    = quick health check for the dashboard.
      switch ([string]$a.action) {
        'bootstrap' {
          if (-not (Test-Path 'C:\HomeShare')) { New-Item -ItemType Directory -Path 'C:\HomeShare' -Force | Out-Null }
          $st = Get-SyncthingExe
          if (-not $st) {
            # winget often returns a NONZERO exit code on a perfectly good install
            # (e.g. "Path environment variable modified; restart your shell" or a
            # reboot-suggested state), so DON'T trust the exit code - just re-check
            # for the exe afterward, which is the real success signal.
            $r = Invoke-WinGet @('install','--silent','--accept-package-agreements','--accept-source-agreements','--id','Syncthing.Syncthing','--scope','user') 300
            $st = Get-SyncthingExe
            if (-not $st) { return @{ ok=$false; exit=-1; stdout=''; stderr="install ran but syncthing.exe not found. winget said: $($r.stdout) $($r.stderr)".Trim() } }
          }
          if (-not (Test-Path $StConfigDir)) { New-Item -ItemType Directory -Path $StConfigDir -Force | Out-Null }
          $cfgFile = Join-Path $StConfigDir 'config.xml'
          if (-not (Test-Path $cfgFile)) {
            & $st generate --home "$StConfigDir" --no-port-probing 2>&1 | Out-Null
            if (-not (Test-Path $cfgFile)) {
              # older syncthing CLIs lack 'generate' - a brief headless start also writes config+certs
              $p = Start-Process $st -ArgumentList "--home `"$StConfigDir`"","--no-browser","--no-restart" -WindowStyle Hidden -PassThru
              $sw = [Diagnostics.Stopwatch]::StartNew()
              while (-not (Test-Path $cfgFile) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 500 }
              try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
              Start-Sleep -Seconds 1
            }
          }
          if (-not (Test-Path $cfgFile)) { return @{ ok=$false; exit=-1; stdout=''; stderr='config generation failed' } }

          # Autostart at logon (mirrors the agent's own persistence pattern).
          try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $vbs = Join-Path $StConfigDir 'start-syncthing.vbs'
            $vbsBody = 'CreateObject("Wscript.Shell").Run "' + $st + ' --home ""' + $StConfigDir + '"" --no-browser --no-restart", 0, False'
            Set-Content -Path $vbs -Value $vbsBody -Encoding ASCII
            Set-ItemProperty -Path $runKey -Name 'HomeShareSync' -Value "wscript.exe `"$vbs`""
          } catch {}

          if (-not (Test-LocalPort 8384)) {
            Start-Process wscript.exe -ArgumentList "`"$(Join-Path $StConfigDir 'start-syncthing.vbs')`""
          }
          $sw = [Diagnostics.Stopwatch]::StartNew()
          while (-not (Test-LocalPort 8384) -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 500 }
          if (-not (Test-LocalPort 8384)) { return @{ ok=$false; exit=-1; stdout=''; stderr='syncthing did not come up on :8384' } }
          Start-Sleep -Seconds 1

          try {
            # Fresh installs auto-create a "default" folder - strip it so only the
            # HomeShare folder we add in 'pair' ever syncs on this PC.
            try {
              $cfg0 = Invoke-StApi GET '/rest/config'
              $others = @($cfg0.folders | Where-Object { $_.id -ne 'homeshare' })
              if ($others.Count) {
                $cfg0.folders = @($cfg0.folders | Where-Object { $_.id -eq 'homeshare' })
                Invoke-StApi PUT '/rest/config' $cfg0 | Out-Null
              }
            } catch {}
            $status = Invoke-StApi GET '/rest/system/status'
            return @{ ok=$true; exit=0; stdout=(@{ deviceId=$status.myID } | ConvertTo-Json -Compress); stderr='' }
          } catch { return @{ ok=$false; exit=-1; stdout=''; stderr="status query failed: $($_.Exception.Message)" } }
        }

        'pair' {
          # a.peers = [{id, name, addr}], addr optional ("tcp://ip:22000" or omitted for 'dynamic').
          # Uses the GRANULAR config endpoints (POST /rest/config/devices|folders) - a
          # whole-config PUT returns 400 on Syncthing 2.x, the granular ones don't.
          try {
            $selfId = (Invoke-StApi GET '/rest/system/status').myID
            $cfg = Invoke-StApi GET '/rest/config'
            $added = 0
            # Folder device list must include self + every peer.
            $folderDevs = @(@{ deviceID=$selfId })
            foreach ($peer in @($a.peers)) {
              $pid_ = [string]$peer.id
              if (-not $pid_ -or $pid_ -eq $selfId) { continue }
              if (-not ($cfg.devices | Where-Object { $_.deviceID -eq $pid_ })) {
                $devBody = @{ deviceID=$pid_; name=[string]$peer.name; compression='metadata' }
                # Windows PowerShell 5.1's ConvertTo-Json unwraps a single-element
                # array into a scalar string, which Syncthing rejects ("cannot
                # unmarshal string ... []string"). Pair the explicit address with a
                # 'dynamic' discovery fallback so it's always a 2+ element JSON array
                # (and 'dynamic' is a useful fallback if the LAN IP ever changes).
                if ($peer.addr) { $devBody['addresses'] = @([string]$peer.addr, 'dynamic') }
                Invoke-StApi POST '/rest/config/devices' $devBody | Out-Null
                $added++
              }
              $folderDevs += @{ deviceID=$pid_ }
            }
            $folderBody = @{
              id='homeshare'; label='HomeShare'; path='C:\HomeShare'; type='sendreceive'
              fsWatcherEnabled=$true; rescanIntervalS=3600; devices=$folderDevs
            }
            if ($cfg.folders | Where-Object { $_.id -eq 'homeshare' }) {
              Invoke-StApi PUT '/rest/config/folders/homeshare' $folderBody | Out-Null
            } else {
              Invoke-StApi POST '/rest/config/folders' $folderBody | Out-Null
            }
            return @{ ok=$true; exit=0; stdout="paired, $added new device(s), sharing HomeShare with $($folderDevs.Count) devices"; stderr='' }
          } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
        }

        'status' {
          try {
            $st = Invoke-StApi GET '/rest/system/status'
            $db = Invoke-StApi GET '/rest/db/status?folder=homeshare'
            return @{ ok=$true; exit=0; stdout=(@{ deviceId=$st.myID; state=$db.state; needFiles=$db.needFiles; globalFiles=$db.globalFiles } | ConvertTo-Json -Compress); stderr='' }
          } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
        }

        default { return @{ ok=$false; exit=-1; stdout=''; stderr='unknown syncthing action' } }
      }
    }

    'ollama' {
      # Local AI model server (free, GPU). setup = bind to LAN + restart, pull = download a model.
      $oll = @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe") |
             Where-Object { Test-Path $_ } | Select-Object -First 1
      if (-not $oll) { return @{ ok=$false; exit=-1; stdout=''; stderr='ollama not installed yet' } }
      switch ([string]$a.action) {
        'setup' {
          [Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')
          Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue | Stop-Process -Force
          Start-Sleep -Seconds 1
          $env:OLLAMA_HOST = '0.0.0.0'
          Start-Process $oll -ArgumentList 'serve' -WindowStyle Hidden
          Start-Sleep -Seconds 3
          return @{ ok=$true; exit=0; stdout='ollama serving on LAN (0.0.0.0:11434)'; stderr='' }
        }
        'pull' {
          $m = [string]$a.model
          if ($m -notmatch '^[A-Za-z0-9._:-]+$') { return @{ ok=$false; exit=-1; stdout=''; stderr='bad model name' } }
          $env:OLLAMA_HOST = '127.0.0.1'
          $out = & $oll pull $m 2>&1 | Out-String
          return @{ ok=($LASTEXITCODE -eq 0); exit=$LASTEXITCODE; stdout=$out; stderr='' }
        }
        'list' {
          $env:OLLAMA_HOST = '127.0.0.1'
          $out = & $oll list 2>&1 | Out-String
          return @{ ok=$true; exit=0; stdout=$out; stderr='' }
        }
        default { return @{ ok=$false; exit=-1; stdout=''; stderr='unknown ollama action' } }
      }
    }

    'search' {
      # Fleet-wide file search. Prefer a local Everything HTTP server (instant),
      # else fall back to the dashboard's flat file index on this PC.
      $q = [string]$a.q
      if ($q.Length -lt 2) { return @{ ok=$true; exit=0; stdout='[]'; stderr='' } }
      $max = if ($a.max) { [int]$a.max } else { 40 }
      $hits = @()
      try {
        $u = "http://127.0.0.1:8011/?search=$([uri]::EscapeDataString($q))&json=1&path_column=1&count=$max"
        $r = Invoke-RestMethod $u -TimeoutSec 4
        foreach ($it in $r.results) {
          $p = if ($it.path) { Join-Path $it.path $it.name } else { $it.name }
          $hits += @{ path = $p; name = $it.name }
        }
      } catch {
        $idx = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\file-index.txt'
        if (Test-Path $idx) {
          $needle = $q.ToLower()
          foreach ($line in [IO.File]::ReadLines($idx)) {
            if ($line.ToLower().Contains($needle)) {
              $hits += @{ path = $line; name = [IO.Path]::GetFileName($line) }
              if ($hits.Count -ge $max) { break }
            }
          }
        }
      }
      return @{ ok=$true; exit=0; stdout=(@($hits) | ConvertTo-Json -Depth 4 -Compress); stderr='' }
    }

    'screenshot' {
      # Capture the desktop and POST it to the brain (image is too big for a job
      # result). Runs in the logged-in session so it sees the real screen.
      try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $gfx.Dispose(); $bmp.Dispose()
        $bytes = $ms.ToArray(); $ms.Dispose()
        Invoke-RestMethod "$Brain/screenshot/upload?agent=$([uri]::EscapeDataString($Agent))" -Method Post -Headers @{ 'X-Brain-Token' = $Token } -Body $bytes -ContentType 'application/octet-stream' -TimeoutSec 30 | Out-Null
        return @{ ok=$true; exit=0; stdout="screenshot sent ($([math]::Round($bytes.Length/1KB))KB)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr="capture failed: $($_.Exception.Message)" } }
    }

    'updateagent' { return @{ ok=$true; exit=0; stdout='self-update runs automatically on the next poll'; stderr='' } }

    'rename' {
      # Rename a file/folder: {src, name}
      $src = [string]$a.src
      $name = [string]$a.name
      if (-not $src -or -not $name) { return @{ ok=$false; exit=-1; stdout=''; stderr='src + name required' } }
      try {
        $dst = Join-Path (Split-Path $src) $name
        Rename-Item -LiteralPath $src -NewName $name -Force
        return @{ ok=$true; exit=0; stdout="renamed to $name"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'archive' {
      # Compress a file/folder to .zip: {path}
      $path = [string]$a.path
      if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @{ ok=$false; exit=-1; stdout=''; stderr='path not found' } }
      try {
        $zip = "$path.zip"
        Compress-Archive -Path $path -DestinationPath $zip -Force
        $size = [math]::Round((Get-Item $zip).Length/1MB, 1)
        return @{ ok=$true; exit=0; stdout="archived to $zip ($size MB)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'processes' {
      # List top processes by memory/cpu: {top:10, sort:"mem"}
      $top = if ($a.top) { [int]$a.top } else { 10 }
      $sort = if ($a.sort -eq 'cpu') { 'CPU' } else { 'Memory' }
      try {
        $procs = Get-Process | Sort-Object $sort -Descending | Select-Object -First $top @{N='CPU%';E={[math]::Round($_.CPU,1)}}, @{N='Mem(MB)';E={[math]::Round($_.WorkingSet/1MB,1)}}, Name
        return @{ ok=$true; exit=0; stdout=($procs | ConvertTo-Json); stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'disk-cleanup' {
      # Remove temp files, recycle bin: {targets:"temp,recycle,cache"}
      $targets = @($a.targets -split ',' | ForEach-Object { $_.Trim().ToLower() })
      $freed = 0
      try {
        if ($targets -contains 'temp') {
          Get-ChildItem "$env:TEMP" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
          $freed += 1
        }
        if ($targets -contains 'recycle') {
          Clear-RecycleBin -Force -ErrorAction SilentlyContinue
          $freed += 1
        }
        return @{ ok=$true; exit=0; stdout="cleaned $freed target(s)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'netstat' {
      # Network connections and stats
      try {
        $conns = netstat -an 2>$null | Select-Object -Skip 4 | Measure-Object
        $listening = netstat -an 2>$null | Where-Object { $_ -match 'LISTENING' } | Measure-Object
        return @{ ok=$true; exit=0; stdout="total: $($conns.Count) connections, listening: $($listening.Count)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'gpu-status' {
      # GPU utilization (if NVIDIA installed)
      try {
        $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($nvidia) {
          $out = & nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>$null
          return @{ ok=$true; exit=0; stdout=$out; stderr='' }
        }
        return @{ ok=$false; exit=-1; stdout=''; stderr='NVIDIA GPU not found' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'battery' {
      # Battery status (laptops)
      try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) {
          return @{ ok=$true; exit=0; stdout="$($bat.EstimatedChargeRemaining)% - $($bat.BatteryStatus)"; stderr='' }
        }
        return @{ ok=$false; exit=-1; stdout=''; stderr='no battery (desktop?)' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    'get-file-hash' {
      # Hash a file (MD5, SHA256): {path, algo:"SHA256"}
      $path = [string]$a.path
      $algo = if ($a.algo) { [string]$a.algo } else { 'SHA256' }
      if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @{ ok=$false; exit=-1; stdout=''; stderr='path not found' } }
      try {
        $hash = Get-FileHash -LiteralPath $path -Algorithm $algo
        return @{ ok=$true; exit=0; stdout="$($hash.Algorithm): $($hash.Hash)"; stderr='' }
      } catch { return @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
    }

    default  { return @{ ok=$false; exit=-1; stdout=''; stderr="unknown job type '$($job.type)'" } }
  }
}

# ---- Register once, then poll loop -----------------------------------------
$Caps = @('run','install','pia','play','open','power','copy','move','status','fetch','transfer','backup','applist','updates','updateagent','ollama','search','screenshot','listdir','fsearch','delete','syncthing','rename','archive','processes','services','disk-cleanup','netstat','gpu-status','battery','reboot-schedule','mount','get-file-hash','compare-files','hermes-browser','hermes-ocr','hermes-email','hermes-clipboard','hermes-workflow','hermes-admin')
$tsIp = Get-TailscaleIp
try {
  Post "/register" @{ agent=$Agent; host=$env:COMPUTERNAME; ts_ip=$tsIp; caps=$Caps } | Out-Null
  Write-Host "[$Agent] v$AGENT_VERSION registered with brain at $Brain"
} catch {
  Write-Host "[$Agent] register failed: $($_.Exception.Message) - will retry in poll loop"
}

Ensure-Persistence | Out-Null
Maintain
# Keep the LAUNCHER current: launcher updates don't otherwise propagate (it only
# re-downloads when its port is down). On startup, pull the brain's copy and if
# the running launcher's version differs (or it isn't running), replace + restart.
try {
  Invoke-WebRequest "$Brain/launcher" -UseBasicParsing -OutFile $LauncherPs -TimeoutSec 15
  $fileVer = ''
  if ((Get-Content -Raw $LauncherPs) -match "LAUNCHER_VERSION\s*=\s*'([^']+)'") { $fileVer = $Matches[1] }
  $runVer = $null
  try { $runVer = (Invoke-RestMethod 'http://127.0.0.1:8799/whoami' -TimeoutSec 3).ver } catch {}
  if ($fileVer -and ("$runVer" -ne "$fileVer")) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*homedash-launcher*' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Start-Launcher
  }
} catch {}

$lastReg = Get-Date
$lastMaint = Get-Date
while ($true) {
  # Health heartbeat for the launcher's watchdog: stamp a file at the top of every
  # loop. If this goes stale, the loop is HUNG (not just the process missing), and
  # the launcher will kill + restart us. (This is what MainPC needed — a hung agent
  # process still "exists", so the old exists-only check never revived it.)
  try { Set-Content -Path $AliveFile -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
  # Watchdog tick runs even when the brain is unreachable (it's what revives it).
  if (((Get-Date) - $lastMaint).TotalSeconds -ge 60) { $lastMaint = Get-Date; try { Maintain } catch {} }
  try {
    $resp = Post "/poll" @{ agent=$Agent; host=$env:COMPUTERNAME; stats=(Get-Stats) }
    foreach ($job in @($resp.jobs)) {
      Write-Host "[$Agent] job #$($job.id) $($job.type)"
      $r = try { Handle-Job $job } catch { @{ ok=$false; exit=-1; stdout=''; stderr=$_.Exception.Message } }
      try {
        Post "/result" @{ id=$job.id; ok=$r.ok; exit=$r.exit; stdout=[string]$r.stdout; stderr=[string]$r.stderr } | Out-Null
      } catch { Write-Host "[$Agent] result post failed for #$($job.id)" }
    }
    # Self-update: the brain tells us which agent version it serves.
    if ($resp.agentVersion) {
      $script:ExpectedVer = [string]$resp.agentVersion
      if ([string]$resp.agentVersion -ne $AGENT_VERSION) {
        if (Update-Self ([string]$resp.agentVersion)) { exit 0 }
      } else {
        Reap-Duplicates   # up to date -> clear out any leftover old instance now
      }
    }
    # re-register hourly so caps/ts_ip stay fresh
    if (((Get-Date) - $lastReg).TotalMinutes -ge 60) {
      $tsIp = Get-TailscaleIp
      try { Post "/register" @{ agent=$Agent; host=$env:COMPUTERNAME; ts_ip=$tsIp; caps=$Caps } | Out-Null } catch {}
      $lastReg = Get-Date
    }
  } catch {
    # brain unreachable (PC asleep, brain restarting) - back off a little
    Start-Sleep -Seconds 5
  }
  Start-Sleep -Seconds $PollSec
}
