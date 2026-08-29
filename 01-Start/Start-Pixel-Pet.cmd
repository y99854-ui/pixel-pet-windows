@echo off
setlocal
set "PET_LAUNCHER=%~dp0..\02-App\Launch-Pixel-Pet.vbs"
if not exist "%PET_LAUNCHER%" set "PET_LAUNCHER=%~dp0Launch-Pixel-Pet.vbs"
if not exist "%PET_LAUNCHER%" (
  echo Launch-Pixel-Pet.vbs was not found.
  echo Please extract the entire ZIP archive first, then run this file again.
  echo.
  pause
  exit /b 1
)
start "" wscript.exe "%PET_LAUNCHER%"
endlocal
