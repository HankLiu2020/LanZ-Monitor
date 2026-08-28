@echo off
cd /d "%~dp0"
if not exist "%~dp0.lanz-config.bin" goto configure
if not exist "%~dp0.lanz-session.bin" goto configure
goto launch

:configure
call "%~dp0setup-session.cmd"
if not exist "%~dp0.lanz-config.bin" exit /b 1
if not exist "%~dp0.lanz-session.bin" exit /b 1

:launch
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  start "LanZ Monitor" pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
) else (
  start "LanZ Monitor" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
)
