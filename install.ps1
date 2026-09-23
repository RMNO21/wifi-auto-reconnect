<#
.SYNOPSIS
    Automated installer for Wi-Fi Auto-Reconnect Service for Windows.
.DESCRIPTION
    Installs the event-driven Wi-Fi monitor into %LOCALAPPDATA%\WiFiAutoReconnect,
    configures auto-start on logon (via Startup / Registry / Task Scheduler),
    and immediately launches the service. Works with or without Administrator rights.
#>

[CmdletBinding()]
param()

$AppName = "WiFi-Auto-Reconnect"
$LegacyTaskName = "WiFi-Aggressive-Reconnect"
$InstallDir = "$env:LOCALAPPDATA\WiFiAutoReconnect"
$SourceDir = Join-Path $PSScriptRoot "scripts"
$StartupFolder = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupFolder "$AppName.lnk"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Wi-Fi Auto-Reconnect Service - Installer" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# 1. Prepare installation folder
Write-Host "[1/5] Setting up installation directory..." -ForegroundColor Yellow
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Write-Host "      Installed path: $InstallDir" -ForegroundColor Gray

# 2. Stop running instances if any
Write-Host "[2/5] Stopping previous instances..." -ForegroundColor Yellow
try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -like "*wifi_reconnect.ps1*" } | 
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# 3. Copy script files
Write-Host "[3/5] Deploying script files..." -ForegroundColor Yellow
Copy-Item (Join-Path $SourceDir "wifi_reconnect.ps1") -Destination $InstallDir -Force
Copy-Item (Join-Path $SourceDir "wifi_hidden.vbs") -Destination $InstallDir -Force

# Migrate existing SSID preference if present
$existingSSID = "$env:USERPROFILE\.wifi_last_ssid"
$targetSSID = Join-Path $InstallDir ".wifi_last_ssid"
if ((Test-Path $existingSSID) -and (-not (Test-Path $targetSSID))) {
    Copy-Item $existingSSID -Destination $targetSSID -Force
}

# 4. Configure Auto-Start on Logon
Write-Host "[4/5] Configuring Auto-Start on Windows Logon..." -ForegroundColor Yellow
$vbsPath = Join-Path $InstallDir "wifi_hidden.vbs"

# Check if running as Admin
$isAdmin = $false
try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

$taskRegistered = $false
if ($isAdmin) {
    try {
        Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $AppName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogon
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit (New-TimeSpan -Days 365)

        Register-ScheduledTask -TaskName $AppName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description "Event-driven Wi-Fi monitor for zero-latency reconnect and VPN resilience." `
            -Force | Out-Null
        $taskRegistered = $true
        Write-Host "      Configured via Windows Task Scheduler (Admin Mode)." -ForegroundColor Green
    } catch {}
}

# Always ensure user-level Startup shortcut & Registry run key (works with 0 admin privileges)
try {
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = "`"$vbsPath`""
    $shortcut.Description = "Wi-Fi Auto-Reconnect Background Monitor"
    $shortcut.WindowStyle = 7 # Minimized
    $shortcut.Save()

    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WiFiAutoReconnect" -Value "wscript.exe `"$vbsPath`"" -Force | Out-Null
    Write-Host "      Configured via Windows User Startup & Registry (Seamless User Mode)." -ForegroundColor Green
} catch {
    Write-Warning "Could not register user startup shortcut: $_"
}

# 5. Launch the background monitor immediately
Write-Host "[5/5] Launching background monitor..." -ForegroundColor Yellow
try {
    Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`""
} catch {
    Write-Warning "Could not start process immediately: $_"
}

Start-Sleep -Seconds 2

$logPath = Join-Path $InstallDir "wifi_reconnect_log.txt"
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "   Installation Completed Successfully!" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "Location  : $InstallDir" -ForegroundColor White
Write-Host "Log File  : $logPath" -ForegroundColor White
Write-Host ""
Write-Host "The service is now running silently in the background." -ForegroundColor Cyan
