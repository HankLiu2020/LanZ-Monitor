@echo off
cd /d "%~dp0"
set "LANZ_STATE=%LOCALAPPDATA%\LanZ-Monitor\secrets"
if not exist "%LANZ_STATE%\connection.bin" goto configure
if not exist "%LANZ_STATE%\session.bin" goto configure
goto launch

:configure
call "%~dp0setup-session.cmd"
if not exist "%LANZ_STATE%\connection.bin" exit /b 1
if not exist "%LANZ_STATE%\session.bin" exit /b 1

:launch
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  start "LanZ Monitor" pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
) else (
  start "LanZ Monitor" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LanZMonitor.ps1"
)
