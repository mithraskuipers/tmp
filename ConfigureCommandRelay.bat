@echo off
powershell -NoProfile -NoLogo -Command "Unblock-File -Path '%~dp0ConfigGUI.ps1'" >nul 2>&1
powershell -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -Scope Process -File "%~dp0ConfigGUI.ps1"
