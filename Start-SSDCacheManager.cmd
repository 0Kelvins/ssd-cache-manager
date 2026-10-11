@echo off
REM ---------------------------------------------------------------
REM  SSD Cache Manager launcher
REM
REM  Self-elevates to Administrator because creating an NTFS junction
REM  requires elevation. Also bypasses the PowerShell execution policy
REM  for this process only, which otherwise blocks loading any .ps1.
REM ---------------------------------------------------------------

setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SSDCacheGUI.ps1" %*

if errorlevel 1 (
    echo.
    echo The tool exited with an error. See the message above.
    pause
)
endlocal