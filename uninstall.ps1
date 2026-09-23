<#
.SYNOPSIS
    Uninstaller for Wi-Fi Auto-Reconnect Service.
.DESCRIPTION
    Stops background monitor processes, removes startup shortcuts,
    Registry keys, Task Scheduler tasks, and cleans up application files.
#>

[CmdletBinding()]
param(
    [switch]$KeepLogs
)

$AppName = "WiFi-Auto-Reconnect"
$LegacyTaskName = "WiFi-Aggressive-Reconnect"
$InstallDir = "$env:LOCALAPPDATA\WiFiAutoReconnect"
$StartupFolder = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupFolder "$AppName.lnk"

Write-Host "=====================================================" -ForegroundColor Yellow
Write-Host "   Wi-Fi Auto-Reconnect Service - Uninstaller" -ForegroundColor Yellow
Write-Host "=====================================================" -ForegroundColor Yellow

# 1. Stop background processes
Write-Host "[1/4] Terminating active monitor processes..." -ForegroundColor Gray
try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -like "*wifi_reconnect.ps1*" } | 
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# 2. Remove Startup Shortcut & Registry Run Key
Write-Host "[2/4] Removing startup entries..." -ForegroundColor Gray
if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue
}
try {
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WiFiAutoReconnect" -ErrorAction SilentlyContinue
} catch {}

# 3. Remove Scheduled Tasks if any
Write-Host "[3/4] Cleaning up Task Scheduler..." -ForegroundColor Gray
try {
    Unregister-ScheduledTask -TaskName $AppName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

# 4. Cleanup files
Write-Host "[4/4] Cleaning up installation files..." -ForegroundColor Gray
if (Test-Path $InstallDir) {
    if ($KeepLogs) {
        Remove-Item (Join-Path $InstallDir "wifi_reconnect.ps1") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $InstallDir "wifi_hidden.vbs") -Force -ErrorAction SilentlyContinue
        Write-Host "      Logs preserved in $InstallDir" -ForegroundColor Gray
    } else {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Wi-Fi Auto-Reconnect service has been completely uninstalled." -ForegroundColor Green
