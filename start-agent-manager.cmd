@echo off
setlocal
call "%~dp0native-host-windows-wsl\start-agent-manager.cmd"
if errorlevel 1 pause
