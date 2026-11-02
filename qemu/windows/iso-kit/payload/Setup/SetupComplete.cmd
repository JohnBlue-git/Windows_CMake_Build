@echo off
rem Windows Setup runs C:\Windows\Setup\Scripts\SetupComplete.cmd as SYSTEM
rem after installation, before the first logon. Build-CustomIso.ps1 places
rem this file there. It installs the embedded toolchain from C:\Setup.
if not exist C:\Setup\logs mkdir C:\Setup\logs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Setup\Install-Toolchain.ps1 >> C:\Setup\logs\SetupComplete.log 2>&1
exit /b 0
