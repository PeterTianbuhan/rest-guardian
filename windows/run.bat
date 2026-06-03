@echo off
set "SCRIPT_DIR=%~dp0"
set "RG_SCRIPT=%SCRIPT_DIR%RestGuardian.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$script = Get-Content -Raw -Encoding UTF8 -Path $env:RG_SCRIPT; & ([ScriptBlock]::Create($script)) %*"
