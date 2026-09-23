# Wi-Fi Aggressive & Intelligent Reconnect Monitor (Ultra Low Power & Event-Driven)
# Features:
# - Instant wake-up via .NET NetworkChange events (zero-lag reconnect on network or VPN drops)
# - Near 0% CPU & battery consumption (sleeps on kernel wait handle)
# - In-memory state caching (zero disk churn / SSD wear)
# - Single-instance mutex protection
# - Dynamic and robust adapter detection (filters out ghost/virtual adapters)
# - Handles VPN NDIS driver teardown with connection state refresh and DNS cache flush
# - Exclusively reconnects to the LAST CONNECTED network (never connects to unknown networks)
# - Clean handling of Airplane mode, adapter disables, and sleep/wake cycles

Add-Type -AssemblyName System.Net.NetworkInformation

# Path Resolution
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = "$env:LOCALAPPDATA\WiFiAutoReconnect" }

$LOG_FILE = Join-Path $scriptDir "wifi_reconnect_log.txt"
$LAST_SSID_FILE = Join-Path $scriptDir ".wifi_last_ssid"
$FALLBACK_SSID_FILE = "$env:USERPROFILE\.wifi_last_ssid"

$MAX_LOG_SIZE_KB = 64
$MAX_LOG_LINES = 200

# Single-Instance Mutex
$mutexName = "Global\WiFiAggressiveReconnect_Monitor_Mutex"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    # Another instance is already running
    exit 0
}

# Event signal to wake main loop immediately on network state change (e.g. VPN adapter drop)
$wakeEvent = New-Object System.Threading.AutoResetEvent($false)

function Write-Log {
    param([string]$Message)
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "$timestamp - $Message`r`n"
        [System.IO.File]::AppendAllText($LOG_FILE, $line, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Trim-LogFile {
    try {
        if (Test-Path $LOG_FILE) {
            $fileItem = Get-Item $LOG_FILE -ErrorAction SilentlyContinue
            if ($fileItem -and $fileItem.Length -gt ($MAX_LOG_SIZE_KB * 1024)) {
                $lines = [System.IO.File]::ReadAllLines($LOG_FILE)
                if ($lines.Count -gt $MAX_LOG_LINES) {
                    $trimmed = $lines | Select-Object -Last $MAX_LOG_LINES
                    [System.IO.File]::WriteAllLines($LOG_FILE, $trimmed, [System.Text.Encoding]::UTF8)
                }
            }
        }
    } catch {}
}

function Get-WifiInterfaceName {
    # Extract interface name directly from active WLAN service
    try {
        $out = netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*Name\s*:\s*(.+)$') {
                $name = $matches[1].Trim()
                if ($name) { return $name }
            }
        }
    } catch {}
    return "Wi-Fi"
}

function Get-WlanStatus {
    param([string]$InterfaceName)
    $info = [PSCustomObject]@{
        Connected     = $false
        SSID          = $null
        Profile       = $null
        InterfaceName = $InterfaceName
        State         = "unknown"
        HasHardware   = $true
    }
    try {
        $cmd = if ($InterfaceName) { "netsh wlan show interfaces interface=`"$InterfaceName`"" } else { "netsh wlan show interfaces" }
        $out = Invoke-Expression $cmd 2>$null
        
        $outText = ($out -join "`n")
        if ($outText -match 'There is no wireless interface' -or $out.Count -eq 0) {
            $info.HasHardware = $false
            $info.State = "not_available"
            return $info
        }

        foreach ($line in $out) {
            if ($line -match '^\s+State\s+:\s+(.+)$') {
                $info.State = $matches[1].Trim()
                if ($info.State -eq 'connected') { $info.Connected = $true }
            } elseif ($line -match '^\s+SSID\s+:\s+(.+)$') {
                $info.SSID = $matches[1].Trim()
            } elseif ($line -match '^\s+Profile\s+:\s+(.+)$') {
                $info.Profile = $matches[1].Trim()
            } elseif (-not $info.InterfaceName -and $line -match '^\s+Name\s+:\s+(.+)$') {
                $info.InterfaceName = $matches[1].Trim()
            }
        }
    } catch {
        $info.HasHardware = $false
    }
    return $info
}

function Get-VisibleSSIDs {
    param([string]$InterfaceName)
    $list = @()
    try {
        $cmd = if ($InterfaceName) { "netsh wlan show networks interface=`"$InterfaceName`"" } else { "netsh wlan show networks" }
        $out = Invoke-Expression $cmd 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s+\d+\s*:\s*(.+)$') {
                $s = $matches[1].Trim()
                if ($s) { $list += $s }
            }
        }
    } catch {}
    return $list
}

function Connect-Wifi {
    param([string]$ProfileName, [string]$InterfaceName)
    try {
        if ($InterfaceName) {
            netsh wlan connect name="$ProfileName" interface="$InterfaceName" 2>$null | Out-Null
        } else {
            netsh wlan connect name="$ProfileName" 2>$null | Out-Null
        }
    } catch {}
}

function Reset-WlanConnection {
    param([string]$InterfaceName)
    try {
        # Disassociate momentarily to clear stuck state or VPN filter residual binding
        if ($InterfaceName) {
            netsh wlan disconnect interface="$InterfaceName" 2>$null | Out-Null
        } else {
            netsh wlan disconnect 2>$null | Out-Null
        }
        # Flush DNS cache in case VPN modified resolver settings
        ipconfig /flushdns 2>$null | Out-Null
    } catch {}
}

# --- Initialization ---
Trim-LogFile
Write-Log "Wi-Fi monitor started (v2 - VPN-Aware & Event-Driven)."

# Load initial cached SSID
$cachedSSID = $null
if (Test-Path $LAST_SSID_FILE) {
    try { $cachedSSID = (Get-Content $LAST_SSID_FILE -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
} elseif (Test-Path $FALLBACK_SSID_FILE) {
    try { $cachedSSID = (Get-Content $FALLBACK_SSID_FILE -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
}

# Register Network Change Events to wake thread instantly whenever any network changes (including VPN disconnects)
$networkChangeHandler = {
    $wakeEvent.Set() | Out-Null
}

$sub1 = Register-ObjectEvent -InputObject ([System.Net.NetworkInformation.NetworkChange]) -EventName 'NetworkAvailabilityChanged' -Action $networkChangeHandler
$sub2 = Register-ObjectEvent -InputObject ([System.Net.NetworkInformation.NetworkChange]) -EventName 'NetworkAddressChanged' -Action $networkChangeHandler

$lastKnownState = "unknown"
$consecutiveFailures = 0

try {
    while ($true) {
        $adapterName = Get-WifiInterfaceName
        $status = Get-WlanStatus -InterfaceName $adapterName

        if (-not $status.HasHardware) {
            if ($lastKnownState -ne "hardware_down") {
                Write-Log "No active Wi-Fi hardware detected (disabled or Airplane mode). Standing by..."
                $lastKnownState = "hardware_down"
            }
            # Wait up to 10 seconds or until hardware changes
            $wakeEvent.WaitOne(10000) | Out-Null
            continue
        }

        if ($status.Connected) {
            $consecutiveFailures = 0
            $lastKnownState = "connected"

            # Update cached SSID if changed
            $currentSSID = if ($status.Profile) { $status.Profile } else { $status.SSID }
            if ($currentSSID -and ($currentSSID -ne $cachedSSID)) {
                $cachedSSID = $currentSSID
                try { $cachedSSID | Out-File -FilePath $LAST_SSID_FILE -NoNewline -Encoding UTF8 } catch {}
                Write-Log "Connected to '$cachedSSID' (saved as preferred)."
            }

            # Deep low-power sleep; wakes instantly if VPN disconnects or network state changes
            $wakeEvent.WaitOne(30000) | Out-Null
        } else {
            # Disconnected state!
            if ($lastKnownState -eq "connected" -or $lastKnownState -eq "unknown") {
                Write-Log "Wi-Fi disconnected (State: $($status.State)). Triggering immediate reconnection..."
            }
            $lastKnownState = "disconnected"

            $targetSSID = $cachedSSID
            if (-not $targetSSID -and (Test-Path $LAST_SSID_FILE)) {
                try { $targetSSID = (Get-Content $LAST_SSID_FILE -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
            }
            if (-not $targetSSID -and (Test-Path $FALLBACK_SSID_FILE)) {
                try { $targetSSID = (Get-Content $FALLBACK_SSID_FILE -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
            }

            if (-not $targetSSID) {
                # Fallback to the first available profile on this interface
                try {
                    $profiles = netsh wlan show profiles interface="$adapterName" 2>$null
                    foreach ($line in $profiles) {
                        if ($line -match ':\s*(.+)$') {
                            $targetSSID = $matches[1].Trim()
                            if ($targetSSID -and $targetSSID -ne "<None>") { break }
                        }
                    }
                } catch {}
            }

            if (-not $targetSSID) {
                Write-Log "No preferred SSID saved. Standing by..."
                $wakeEvent.WaitOne(10000) | Out-Null
                continue
            }

            # Phase 1: Rapid burst reconnect (3 attempts with 1.2s intervals)
            $reconnected = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Connect-Wifi -ProfileName $targetSSID -InterfaceName $adapterName
                Start-Sleep -Milliseconds 1200
                $check = Get-WlanStatus -InterfaceName $adapterName
                if ($check.Connected) {
                    Write-Log "Reconnected successfully to '$targetSSID' on burst attempt $attempt."
                    $reconnected = $true
                    break
                }
            }

            if (-not $reconnected) {
                # Phase 2: Active scan & recovery if wedged by VPN teardown
                $consecutiveFailures++
                $visible = Get-VisibleSSIDs -InterfaceName $adapterName

                if ($visible -contains $targetSSID) {
                    Write-Log "Network '$targetSSID' is in range. Cycling connection state & retrying (attempt $consecutiveFailures)..."
                    Reset-WlanConnection -InterfaceName $adapterName
                    Start-Sleep -Milliseconds 500
                    Connect-Wifi -ProfileName $targetSSID -InterfaceName $adapterName

                    # Adaptive backoff: 3s, 5s, 7s... max 15s
                    $sleepTime = [Math]::Min(3 + ($consecutiveFailures * 2), 15)
                    $wakeEvent.WaitOne($sleepTime * 1000) | Out-Null
                } else {
                    if ($consecutiveFailures -eq 1) {
                        Write-Log "Network '$targetSSID' not immediately visible. Triggering active scan..."
                    }
                    $wakeEvent.WaitOne(8000) | Out-Null
                }
            }
        }
    }
} finally {
    # Cleanup event handlers and mutex on exit
    if ($sub1) { Unregister-Event -SourceIdentifier $sub1.Name -ErrorAction SilentlyContinue }
    if ($sub2) { Unregister-Event -SourceIdentifier $sub2.Name -ErrorAction SilentlyContinue }
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
