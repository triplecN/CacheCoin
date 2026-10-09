@echo off
title Verify CacheCoin download
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0tools\CacheCoin-Verify.ps1"
echo.
if not defined CCCN_NO_PAUSE pause
