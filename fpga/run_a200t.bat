@echo off
setlocal enabledelayedexpansion

echo ================================================================================
echo   ATHENA / INT8 CNN ACCELERATOR: A200T FULL IMPLEMENTATION [PLACE AND ROUTE]
echo ================================================================================

rem Check if user provided an explicit VIVADO_BIN environment variable
if defined VIVADO_BIN (
    if exist "%VIVADO_BIN%" (
        goto :run_vivado
    ) else (
        echo [WARNING] Specified VIVADO_BIN does not exist: %VIVADO_BIN%
        echo Searching for alternative Vivado installation...
        set "VIVADO_BIN="
    )
)

rem Check system PATH for vivado.bat or vivado
where vivado.bat >nul 2>&1
if !errorlevel! equ 0 (
    for /f "delims=" %%i in ('where vivado.bat') do set "VIVADO_BIN=%%i"
    goto :run_vivado
)

where vivado >nul 2>&1
if !errorlevel! equ 0 (
    for /f "delims=" %%i in ('where vivado') do set "VIVADO_BIN=%%i"
    goto :run_vivado
)

rem Check common default installation locations
if exist "Z:\2026.1\Vivado\bin\vivado.bat" (
    set "VIVADO_BIN=Z:\2026.1\Vivado\bin\vivado.bat"
    goto :run_vivado
)

if exist "C:\Xilinx\Vivado\2026.1\bin\vivado.bat" (
    set "VIVADO_BIN=C:\Xilinx\Vivado\2026.1\bin\vivado.bat"
    goto :run_vivado
)

if exist "C:\Xilinx\Vivado\2024.1\bin\vivado.bat" (
    set "VIVADO_BIN=C:\Xilinx\Vivado\2024.1\bin\vivado.bat"
    goto :run_vivado
)

if exist "C:\Xilinx\Vivado\2023.2\bin\vivado.bat" (
    set "VIVADO_BIN=C:\Xilinx\Vivado\2023.2\bin\vivado.bat"
    goto :run_vivado
)

echo [ERROR] Vivado executable could not be found.
echo Please ensure Vivado is added to your system PATH or set the VIVADO_BIN environment variable.
echo Example:
echo   set VIVADO_BIN=C:\Xilinx\Vivado\2024.1\bin\vivado.bat
echo   run_a200t.bat
exit /b 1

:run_vivado
echo [INFO] Using Vivado executable: %VIVADO_BIN%

"%VIVADO_BIN%" -mode batch -source "%~dp0scripts\run_a200t.tcl" -log "%~dp0logs\vivado_a200t.log" -jou "%~dp0logs\vivado_a200t.jou"
set EXIT_CODE=%ERRORLEVEL%

if %EXIT_CODE% EQU 0 (
    echo [SUCCESS] A200T Implementation completed successfully.
) else (
    echo [ERROR] A200T Implementation failed with exit code %EXIT_CODE%.
)

exit /b %EXIT_CODE%
