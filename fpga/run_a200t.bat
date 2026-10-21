@echo off
setlocal

set VIVADO_BIN=Z:\2026.1\Vivado\bin\vivado.bat

if not exist "%VIVADO_BIN%" (
    echo [ERROR] Vivado executable not found at: %VIVADO_BIN%
    exit /b 1
)

echo ================================================================================
echo   ATHENA / INT8 CNN ACCELERATOR: A200T FULL IMPLEMENTATION (PLACE & ROUTE)
echo ================================================================================

"%VIVADO_BIN%" -mode batch -source "%~dp0scripts\run_a200t.tcl" -log "%~dp0logs\vivado_a200t.log" -jou "%~dp0logs\vivado_a200t.jou"
set EXIT_CODE=%ERRORLEVEL%

if %EXIT_CODE% EQU 0 (
    echo [SUCCESS] A200T Implementation completed successfully.
) else (
    echo [ERROR] A200T Implementation failed with exit code %EXIT_CODE%.
)

exit /b %EXIT_CODE%
