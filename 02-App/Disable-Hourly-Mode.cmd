@echo off
if not exist "%~dp0Set-Hourly-Mode.ps1" (
  echo Set-Hourly-Mode.ps1 was not found.
  echo Please extract the entire ZIP archive first, then run this file again.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Hourly-Mode.ps1" -Disable
echo.
pause
