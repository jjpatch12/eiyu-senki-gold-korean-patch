@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0.patch\install.ps1" -Mode Restore
set "result=%errorlevel%"
pause
exit /b %result%
