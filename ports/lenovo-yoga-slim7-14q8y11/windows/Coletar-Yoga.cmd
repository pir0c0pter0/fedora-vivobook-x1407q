@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-Yoga14Q8Y11.ps1" %*
set "capture_exit=%ERRORLEVEL%"
echo.
echo Codigo de saida: %capture_exit% (0 = concluida; 2 = coleta parcial; outro = erro).
pause
exit /b %capture_exit%
