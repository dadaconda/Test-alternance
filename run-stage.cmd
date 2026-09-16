@echo off
REM Lance la veille STAGE finance. Usage : run-stage.cmd  [ -Since 12 ] [ -All ]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stage.ps1" %*
