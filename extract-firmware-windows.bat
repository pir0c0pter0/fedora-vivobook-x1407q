@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Vivobook X1407QA - Qualcomm Firmware Dump

REM ===========================================================================
REM  extract-firmware-windows.bat
REM  Copies the Qualcomm firmware from Windows (ASUS Vivobook 14 X1407QA /
REM  Snapdragon X) into a folder next to this .bat. Put this .bat on a USB drive
REM  and run it from there: the dump lands on the USB, ready to take to Fedora.
REM ===========================================================================

REM --- Self-elevate to Administrator (DriverStore requires it) ---
net session >nul 2>&1 || ( echo Requesting administrator privileges... & powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b )

set "SRC=%SystemRoot%\System32\DriverStore\FileRepository"
set "REL=Windows\System32\DriverStore\FileRepository"
set "OUT=%~dp0vivobook-qcom-firmware"

echo ============================================
echo  Qualcomm Firmware Dump
echo  ASUS Vivobook 14 X1407QA (Snapdragon X)
echo ============================================
echo.
echo  Source: %SRC%
echo  Output: %OUT%
echo.

if not exist "%SRC%" ( echo [x] DriverStore not found. Is this an ASUS Windows-on-ARM PC? & echo. & pause & exit /b 1 )

if not exist "%OUT%" mkdir "%OUT%"

set /a count=0
REM Copy each Qualcomm driver package (qc*) whole, keeping the .inf files
REM (qcom-firmware-extract on Linux uses the .inf files to remap the names).
for /d %%D in ("%SRC%\qc*") do echo  [+] %%~nxD & robocopy "%%D" "%OUT%\%REL%\%%~nxD" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul & set /a count+=1

echo.
if %count%==0 echo [!] No Qualcomm driver packages (qc*) found on this PC.
if %count% gtr 0 echo [+] %count% Qualcomm driver packages copied.

set /a fw=0
for /r "%OUT%" %%F in (*.mbn *.bin) do set /a fw+=1
echo [+] Firmware files (.mbn/.bin) in the dump: %fw%
echo.
echo ============================================
echo  NEXT STEPS
echo ============================================
echo  1) Make sure this .bat and the "vivobook-qcom-firmware" folder
echo     are on a USB drive (FAT32/exFAT).
echo.
echo  2) Boot the Vivobook into Fedora (USB live or installed),
echo     plug in the USB drive and run (adjust the USB path):
echo.
echo        sudo /opt/vivobook-fixes/extract-qcom-firmware.sh \
echo             /run/media/$USER/USB/vivobook-qcom-firmware
echo.
echo  3) Apply the fixes and reboot:
echo        sudo /opt/vivobook-fixes/setup-vivobook.sh
echo        sudo reboot
echo.
pause
endlocal
