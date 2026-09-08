@echo off
REM Lance la veille alternance finance. Usage : run.cmd  [ -Since 12 ] [ -Strict ] [ -All ]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0alternance.ps1" %*
