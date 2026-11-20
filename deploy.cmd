@echo off
rem Sync this repo's dsh-floating-ball into the local DSH desktop profile.
rem Usage: double-click, or run "deploy.cmd --dry-run" from a terminal.
setlocal
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo [error] node.exe not found in PATH. Install Node.js or run it from a terminal that has node.
  pause
  exit /b 1
)
node deploy.mjs %*
echo.
pause
