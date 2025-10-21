# Gensyn heartbeat agent (Windows)
# Run via Task Scheduler every minute (SYSTEM account recommended)

Param()

# --- Config --------------------------------------------------------------------
# Set these as Environment Variables or directly edit below:
$SERVER_URL    = $env:SERVER_URL    # e.g. http://MONITOR_HOST:8080
$SHARED_SECRET = $env:SHARED_SECRET # must match server .env
$NODE_ID       = $env:NODE_ID       # default -> "<COMPUTERNAME>-gensyn"
$META          = $env:META          # e.g. "dc=home-lab,ram=32g"
$CHECK_PORT    = $env:CHECK_PORT    # "true"/"false" (default true)
$PORT          = $env:PORT          # default 3000
$IP_CMD        = $env:IP_CMD        # e.g. https://ifconfig.me

if ([string]::IsNullOrWhiteSpace($NODE_ID))    { $NODE_ID = "$($env:COMPUTERNAME)-gensyn" }
if ([string]::IsNullOrWhiteSpace($CHECK_PORT)) { $CHECK_PORT = "true" }
if ([string]::IsNullOrWhiteSpace($PORT))       { $PORT = 3000 }
if ([string]::IsNullOrWhiteSpace($IP_CMD))     { $IP_CMD = "https://ifconfig.me" }

function Test-ProcOk {
  try {
    $procs = Get-CimInstance Win32_Process | Where-Object {
      $_.CommandLine -match 'run_rl_swarm\.sh|rl-swarm|python.*rl-swarm'
    }
    return [bool]$procs
  } catch { return $false }
}

function Test-PortOk {
  if ($CHECK_PORT -ne "true") { return $true }
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1",[int]$PORT,$null,$null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1000,$false)
    if ($ok -and $client.Connected) { $client.Close(); return $true }
    $client.Close(); return $false
  } catch { return $false }
}

function Get-PublicIP {
  try {
    return (Invoke-WebRequest -UseBasicParsing -Uri $IP_CMD -TimeoutSec 2).Content.Trim()
  } catch { return "" }
}

# Windows has no "screen", so we rely on process + optional port
$healthy = (Test-ProcOk) -and (Test-PortOk)
$status  = if ($healthy) { "UP" } else { "DOWN" }
$ip      = Get-PublicIP

$payload = @{
  node_id = $NODE_ID
  ip      = $ip
  meta    = $META
  status  = $status
} | ConvertTo-Json -Compress

try {
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri ("{0}/api/heartbeat" -f $SERVER_URL.TrimEnd('/')) `
    -Headers @{ Authorization = "Bearer $SHARED_SECRET"; "Content-Type" = "application/json" } `
    -Body $payload | Out-Null
} catch {
  # swallow to avoid Scheduler spam; could log to Event Log if needed
}

# Optional console output when running manually
Write-Output ("[{0}] beat node_id={1} status={2} ip={3}" -f (Get-Date).ToString("s"), $NODE_ID, $status, $ip)
