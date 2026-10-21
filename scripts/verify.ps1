param(
  [string]$PythonExe = "python",
  [switch]$UseExistingVectors
)

$ErrorActionPreference = "Stop"
$simulationDirectory = Join-Path $env:TEMP "cnn_accel_verify"
New-Item -ItemType Directory -Force -Path $simulationDirectory | Out-Null
$vectorDirectory = "vectors\smoke"
$vectorBackup = $null

if ($UseExistingVectors) {
  if (!(Test-Path "vectors\smoke\instructions.hex")) { throw "vectors\smoke does not contain exported vectors" }
} else {
  if (Test-Path $vectorDirectory) {
    $vectorBackup = Join-Path $env:TEMP ("cnn_accel_vectors_" + [guid]::NewGuid().ToString("N"))
    Copy-Item -LiteralPath $vectorDirectory -Destination $vectorBackup -Recurse
  }
}

try {
  if (!$UseExistingVectors) {
  & $PythonExe python\generate_full_smoke.py
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  $commonRtl = @(
  "rtl\cnn_pkg.sv",
  "rtl\pe.sv",
  "rtl\pe_array.sv",
  "rtl\post_proc.sv",
  "rtl\mem_ctrl.sv",
  "rtl\ctrl_unit.sv",
  "rtl\accel_top.sv"
)

  $testbenches = @(
  @{ Name = "tb_pe"; Sources = @("rtl\pe.sv", "tb\tb_pe.sv") },
  @{ Name = "tb_pe_array"; Sources = @("rtl\cnn_pkg.sv", "rtl\pe.sv", "rtl\pe_array.sv", "tb\tb_pe_array.sv") },
  @{ Name = "tb_post_proc"; Sources = @("rtl\cnn_pkg.sv", "rtl\post_proc.sv", "tb\tb_post_proc.sv") },
  @{ Name = "tb_directed_arith"; Sources = @("rtl\cnn_pkg.sv", "rtl\pe.sv", "rtl\post_proc.sv", "tb\tb_directed_arith.sv") },
  @{ Name = "tb_mem_ctrl_random"; Sources = @("rtl\cnn_pkg.sv", "rtl\mem_ctrl.sv", "tb\tb_mem_ctrl_random.sv") },
  @{ Name = "tb_mem_ctrl_zero_scan"; Sources = @("rtl\cnn_pkg.sv", "rtl\mem_ctrl.sv", "tb\tb_mem_ctrl_zero_scan.sv") },
  @{ Name = "tb_ctrl_unit"; Sources = @("rtl\cnn_pkg.sv", "rtl\ctrl_unit.sv", "tb\tb_ctrl_unit.sv") },
  @{ Name = "tb_top"; Sources = $commonRtl + @("tb\tb_top.sv") },
  @{ Name = "tb_full_cnn"; Sources = $commonRtl + @("tb\tb_full_cnn.sv") },
  @{ Name = "tb_repeated_inference"; Sources = $commonRtl + @("tb\tb_repeated_inference.sv") }
)

  foreach ($test in $testbenches) {
    $outputFile = Join-Path $simulationDirectory ($test.Name + ".vvp")
    $compileArguments = @("-g2012", "-s", $test.Name, "-o", $outputFile) + $test.Sources
    & iverilog @compileArguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & vvp $outputFile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
} finally {
  if ($vectorBackup) {
    Remove-Item -LiteralPath $vectorDirectory -Recurse -Force
    Copy-Item -LiteralPath $vectorBackup -Destination $vectorDirectory -Recurse
    Remove-Item -LiteralPath $vectorBackup -Recurse -Force
  }
}
