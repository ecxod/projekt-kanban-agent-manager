@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
rem Let PowerShell read and normalize the WSL distribution list. The cmd.exe
rem for /f loop is not used because wsl.exe emits UTF-16 output there and
rem can pass only the first character (for example, "D" instead of "Devuan").
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT_DIR%agent-manager.ps1"
if errorlevel 1 pause
