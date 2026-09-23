@echo off
setlocal
title Installing Wi-Fi Auto-Reconnect...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
