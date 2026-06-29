@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Vivobook X1407QA - Dump de Firmware Qualcomm

REM ===========================================================================
REM  extract-firmware-windows.bat
REM  Copia o firmware Qualcomm do Windows (ASUS Vivobook 14 X1407QA / Snapdragon X)
REM  para uma pasta ao lado deste .bat. Coloque este .bat num PENDRIVE e rode
REM  por ELE: o dump cai direto no pendrive, pronto pra levar ao Fedora.
REM ===========================================================================

REM --- Auto-elevar para Administrador (DriverStore exige) ---
net session >nul 2>&1 || ( echo Solicitando privilegios de administrador... & powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b )

set "SRC=%SystemRoot%\System32\DriverStore\FileRepository"
set "REL=Windows\System32\DriverStore\FileRepository"
set "OUT=%~dp0vivobook-qcom-firmware"

echo ============================================
echo  Dump de Firmware Qualcomm
echo  ASUS Vivobook 14 X1407QA (Snapdragon X)
echo ============================================
echo.
echo  Origem : %SRC%
echo  Destino: %OUT%
echo.

if not exist "%SRC%" ( echo [x] DriverStore nao encontrado. Este e um PC Windows ARM da ASUS? & echo. & pause & exit /b 1 )

if not exist "%OUT%" mkdir "%OUT%"

set /a count=0
REM Copia cada pacote de driver Qualcomm (qc*) inteiro, preservando os .inf
REM (o qcom-firmware-extract no Linux usa os .inf para remapear os nomes).
for /d %%D in ("%SRC%\qc*") do echo  [+] %%~nxD & robocopy "%%D" "%OUT%\%REL%\%%~nxD" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul & set /a count+=1

echo.
if %count%==0 echo [!] Nenhum pacote de driver Qualcomm (qc*) encontrado neste PC.
if %count% gtr 0 echo [+] %count% pacotes de driver Qualcomm copiados.

set /a fw=0
for /r "%OUT%" %%F in (*.mbn *.bin) do set /a fw+=1
echo [+] Arquivos de firmware (.mbn/.bin) no dump: %fw%
echo.
echo ============================================
echo  PROXIMOS PASSOS
echo ============================================
echo  1) Garanta que este .bat e a pasta "vivobook-qcom-firmware"
echo     estao num PENDRIVE (FAT32/exFAT).
echo.
echo  2) Boote o Vivobook no Fedora (USB live ou ja instalado),
echo     plugue o pendrive e rode (ajuste o caminho do pendrive):
echo.
echo        sudo /opt/vivobook-fixes/extract-qcom-firmware.sh \
echo             /run/media/$USER/PENDRIVE/vivobook-qcom-firmware
echo.
echo  3) Aplique os fixes e reinicie:
echo        sudo /opt/vivobook-fixes/setup-vivobook.sh
echo        sudo reboot
echo.
pause
endlocal
