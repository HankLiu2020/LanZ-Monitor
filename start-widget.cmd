@echo off
cd /d "%~dp0"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  start "LanZ Monitor" pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
) else (
  start "LanZ Monitor" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
)
