# ============================================================================
#  Home Brain - LOCAL LAUNCHER  (3.x)
#  Lets the dashboard (a web page) launch Parsec / Remote Desktop / Explorer on
#  THIS PC - exactly like the old dashboard did. Bound to 127.0.0.1 ONLY, so
#  nothing on the network can reach it. Only accepts requests from the dashboard
#  page (Origin check) and only knows a fixed set of safe actions.
#
#  3.x: doubles as the agent's watchdog - every ~60s it checks that the agent
#  process is alive and restarts it if not (the agent returns the favor for the
#  launcher). Uses a non-blocking accept loop so the watchdog can tick.
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'
$LAUNCHER_VERSION = '3.2.0'
$Port = 8799
$AliveFile = Join-Path $env:LOCALAPPDATA 'HomeNetDashboard\agent-alive.txt'  # agent stamps this each loop; stale = hung
try {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
  $listener.Start()
} catch { exit }   # already running - nothing to do

# Only the Home Brain dashboard pages may trigger launches (blocks random websites).
$AllowedOrigins = @('http://192.168.1.174:8788','http://localhost:8788','http://127.0.0.1:8788')
$parsec = @("$env:ProgramFiles\Parsec\parsecd.exe", "${env:ProgramFiles(x86)}\Parsec\parsecd.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1
$AgentPs = Join-Path $env:ProgramData 'HomeNetDashboard\agent\homedash-agent.ps1'

function Send-Resp($ns, $status, $body) {
  $b = [Text.Encoding]::UTF8.GetBytes([string]$body)
  $head = "HTTP/1.1 $status`r`n" +
          "Content-Type: application/json`r`n" +
          "Content-Length: $($b.Length)`r`n" +
          "Access-Control-Allow-Origin: *`r`n" +
          "Access-Control-Allow-Methods: GET, OPTIONS`r`n" +
          "Access-Control-Allow-Private-Network: true`r`n" +
          "Access-Control-Allow-Headers: *`r`n" +
          "Cache-Control: no-cache`r`nConnection: close`r`n`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $ns.Write($hb, 0, $hb.Length); $ns.Write($b, 0, $b.Length); $ns.Flush()
}

function Watch-Agent {
  # Revive the agent if it's GONE or HUNG. A hung agent still has a process, so
  # checking existence alone isn't enough (that's how MainPC sat dead) - we also
  # check the agent's alive-stamp: if it hasn't ticked in >4 min, the loop is
  # stuck, so kill the zombie and start fresh.
  if (-not (Test-Path $AgentPs)) { return }
  $procs = @()
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -like '*homedash-agent*' })
  } catch {}
  $hung = $false
  if ($procs.Count -gt 0 -and (Test-Path $AliveFile)) {
    try {
      $stamp = [long](Get-Content -Raw $AliveFile).Trim()
      $ageSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $stamp
      if ($ageSec -gt 240) { $hung = $true }
    } catch {}
  }
  if ($procs.Count -eq 0 -or $hung) {
    if ($hung) { $procs | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }; Start-Sleep -Seconds 1 }
    Start-Process wscript.exe -WindowStyle Hidden -ArgumentList '"C:\ProgramData\HomeNetDashboard\agent\start-agent.vbs"'
  }
}

$lastWatch = Get-Date
while ($true) {
  try {
    if (-not $listener.Pending()) {
      Start-Sleep -Milliseconds 150
      if (((Get-Date) - $lastWatch).TotalSeconds -ge 60) { $lastWatch = Get-Date; Watch-Agent }
      continue
    }
    $c = $listener.AcceptTcpClient(); $c.ReceiveTimeout = 3000
    $ns = $c.GetStream(); $sr = New-Object IO.StreamReader($ns)
    $req = $sr.ReadLine()
    $origin = ''
    while (($h = $sr.ReadLine())) { if ($h -eq '') { break }; if ($h -imatch '^Origin:\s*(.+)$') { $origin = $Matches[1].Trim() } }
    if (-not $req) { $c.Close(); continue }
    $method = ($req -split ' ')[0]; $url = ($req -split ' ')[1]
    if ($method -eq 'OPTIONS') { Send-Resp $ns '204 No Content' ''; $c.Close(); continue }
    $path = ($url -split '\?',2)[0]
    $qs = @{}; if ($url -match '\?') { foreach ($kv in (($url -split '\?',2)[1] -split '&')) { $p = $kv -split '=',2; $qs[$p[0]] = [Uri]::UnescapeDataString(($p[1] -replace '\+',' ')) } }

    if ($path -eq '/whoami') {
      Send-Resp $ns '200 OK' (@{ host = $env:COMPUTERNAME; agent = $env:COMPUTERNAME.ToLower(); ver = $LAUNCHER_VERSION } | ConvertTo-Json -Compress)
      $c.Close(); continue
    }
    if ($path -eq '/launch') {
      # Origin gate: reject browser requests from any page that isn't the dashboard.
      if ($origin -and ($AllowedOrigins -notcontains $origin)) { Send-Resp $ns '403 Forbidden' '{"ok":false,"msg":"origin"}'; $c.Close(); continue }
      $app = [string]$qs['app']; $ip = [string]$qs['ip']; $peer = [string]$qs['peer']; $msg = 'ok'; $ok = $true
      $okIp = $ip -match '^\d{1,3}(\.\d{1,3}){3}$'
      switch ($app) {
        'rdp'    { if ($okIp) { Start-Process mstsc.exe -ArgumentList "/v:$ip" } else { $ok=$false; $msg='bad ip' } }
        'files'  { if ($okIp) { Start-Process explorer.exe "\\$ip" } else { $ok=$false; $msg='bad ip' } }
        'parsec' { if ($parsec) { if ($peer -match '^[A-Za-z0-9]+$') { Start-Process $parsec -ArgumentList "peer_id=$peer" } else { Start-Process $parsec } } else { $ok=$false; $msg='parsec not installed' } }
        default  { $ok=$false; $msg='unknown app' }
      }
      Send-Resp $ns '200 OK' (@{ ok = $ok; msg = $msg } | ConvertTo-Json -Compress)
      $c.Close(); continue
    }
    Send-Resp $ns '404 Not Found' '{"ok":false}'; $c.Close()
  } catch {}
}
