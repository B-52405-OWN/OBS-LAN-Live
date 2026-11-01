@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Stream.ps1" -Action Start
@if errorlevel 1 pause
