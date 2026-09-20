@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
attrib +h "%~dp0.patch" >nul 2>&1
echo Eiyu Senki Gold Korean Patch v0.9.0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0.patch\install.ps1" -Mode Install
set "result=%errorlevel%"
if not "%result%"=="0" echo Installation failed. See the message above.
pause
exit /b %result%
