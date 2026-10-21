$ErrorActionPreference = "Stop"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  ATHENA STUDIO: INT8 CNN ACCELERATOR FPGA SYNTHESIS AUTOMATION (PowerShell)" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$vivadoCandidates = @(
    "Z:\2026.1\Vivado\bin\vivado.bat",
    "C:\Xilinx\Vivado\2026.1\bin\vivado.bat"
)

$vivadoBin = $null
foreach ($cand in $vivadoCandidates) {
    if (Test-Path $cand) {
        $vivadoBin = $cand
        break
    }
}

if (-not $vivadoBin) {
    $cmd = Get-Command "vivado.bat" -ErrorAction SilentlyContinue
    if ($cmd) {
        $vivadoBin = $cmd.Source
    }
}

if (-not $vivadoBin) {
    Write-Error "AMD/Xilinx Vivado installation was not found. Please install Vivado or add it to PATH."
    exit 1
}

Write-Host "[INFO] Found Vivado: $vivadoBin" -ForegroundColor Green
Write-Host "[INFO] Starting batch synthesis for xc7a100tcsg324-1..." -ForegroundColor Yellow

New-Item -ItemType Directory -Path "$scriptDir\logs", "$scriptDir\reports" -Force | Out-Null

$proc = Start-Process -FilePath $vivadoBin -ArgumentList "-mode batch -notrace -source scripts/run_synthesis.tcl -log logs/vivado_synth.log -journal logs/vivado_synth.jou" -NoNewWindow -PassThru -Wait

if ($proc.ExitCode -ne 0) {
    Write-Error "Vivado synthesis failed with exit code $($proc.ExitCode). See logs/vivado_synth.log for details."
    exit $proc.ExitCode
}

Write-Host "[SUCCESS] Standalone INT8 CNN Synthesis completed cleanly!" -ForegroundColor Green
Write-Host "[INFO] Reports available in $scriptDir\reports\" -ForegroundColor Cyan
exit 0
