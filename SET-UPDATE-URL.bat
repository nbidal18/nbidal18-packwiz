@echo off
setlocal
set /p "PACKURL=Public Packwiz URL ending in /pack.toml: "
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Set-UpdateUrl.ps1" -UpdateUrl "%PACKURL%"
if errorlevel 1 (
  echo.
  echo URL was not saved.
  pause
  exit /b 1
)
echo.
echo Commit and push this updater repository, enable GitHub Pages via Actions, then run BUILD-FINAL-MIGRATION-ZIP.bat.
pause
