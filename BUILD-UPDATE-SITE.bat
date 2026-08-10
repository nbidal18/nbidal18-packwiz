@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Sync-Packwiz.ps1" -RefreshModrinth
if errorlevel 1 (
  echo.
  echo Update-site build failed.
  pause
  exit /b 1
)
echo.
echo Update site is ready under 5. updater\site.
pause
