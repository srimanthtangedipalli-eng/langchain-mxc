@echo off
rem Double-click this file, or run it from a terminal, to test langchain-mxc on Windows.
rem It needs no admin rights. Details: WINDOWS_SETUP.md
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\run-windows-tests.ps1" %*
echo.
pause
