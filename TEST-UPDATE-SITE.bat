@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Test-Packwiz.ps1"
if errorlevel 1 (
  echo.
  echo Validation failed. See VALIDATION-REPORT.md.
  pause
  exit /b 1
)
echo.
echo Validation passed. See VALIDATION-REPORT.md.
pause
