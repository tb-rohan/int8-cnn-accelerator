@echo off
setlocal enabledelayedexpansion

echo ================================================================================
echo   ATHENA STUDIO: INT8 CNN ACCELERATOR FPGA SYNTHESIS AUTOMATION
echo ================================================================================

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

rem Locate Vivado
set "VIVADO_BIN="
if exist "Z:\2026.1\Vivado\bin\vivado.bat" (
    set "VIVADO_BIN=Z:\2026.1\Vivado\bin\vivado.bat"
) else if exist "C:\Xilinx\Vivado\2026.1\bin\vivado.bat" (
    set "VIVADO_BIN=C:\Xilinx\Vivado\2026.1\bin\vivado.bat"
) else (
    where vivado.bat >nul 2>&1
    if !errorlevel! equ 0 (
        for /f "delims=" %%i in ('where vivado.bat') do set "VIVADO_BIN=%%i"
    )
)

if not defined VIVADO_BIN (
    echo [ERROR] AMD/Xilinx Vivado installation was not found.
    echo Please ensure Vivado is installed and on PATH or installed at Z:\2026.1\Vivado.
    exit /b 1
)

echo [INFO] Found Vivado at: %VIVADO_BIN%
echo [INFO] Running batch synthesis on Artix-7 (xc7a100tcsg324-1)...

if not exist logs mkdir logs
if not exist reports mkdir reports

"%VIVADO_BIN%" -mode batch -notrace -source scripts\run_synthesis.tcl -log logs\vivado_synth.log -journal logs\vivado_synth.jou
set SYNTH_ERR=%errorlevel%

if %SYNTH_ERR% neq 0 (
    echo [ERROR] Vivado synthesis failed with exit code %SYNTH_ERR%.
    echo Check logs\vivado_synth.log for details.
    exit /b %SYNTH_ERR%
)

echo [SUCCESS] Standalone INT8 CNN Synthesis completed cleanly!
echo [INFO] Reports generated in %SCRIPT_DIR%reports\
echo   - reports\synth_utilization.rpt
echo   - reports\synth_utilization_hierarchical.rpt
echo   - reports\synth_timing_summary.rpt
echo   - reports\synth_latches.rpt
exit /b 0
