@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-Release.ps1"
if errorlevel 1 (
  echo.
  echo Final release build failed.
  pause
  exit /b 1
)
echo.
echo Final updater-enabled migration ZIP is ready under 1. setup.
pause
