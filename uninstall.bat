@echo off
setlocal
title Uninstalling Wi-Fi Auto-Reconnect...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo.
pause
