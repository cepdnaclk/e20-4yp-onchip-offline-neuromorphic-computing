param(
    [string]$Source = "Test.c",
    [string]$Elf = "Test.elf",
    [string]$Hex = "Test.hex",
    [string]$ToolchainBin = "",
    [switch]$RunSim
)

$ErrorActionPreference = "Stop"

Write-Host "=== RISC-V Build Pipeline ===" -ForegroundColor Cyan
Write-Host "Source: $Source"

if ($ToolchainBin -and -not (Test-Path $ToolchainBin)) {
    throw "ToolchainBin path not found: $ToolchainBin"
}

if ($ToolchainBin) {
    $env:PATH = "$ToolchainBin;$env:PATH"
    Write-Host "ToolchainBin added to PATH for this run: $ToolchainBin"
}

# Tool checks (supports common RISC-V GNU triplets)
$toolPrefix = $null
$supportedPrefixes = @(
    "riscv64-unknown-elf",
    "riscv-none-elf"
)

foreach ($prefix in $supportedPrefixes) {
    $gccCandidate = Get-Command ("{0}-gcc" -f $prefix) -ErrorAction SilentlyContinue
    $objdumpCandidate = Get-Command ("{0}-objdump" -f $prefix) -ErrorAction SilentlyContinue
    $objcopyCandidate = Get-Command ("{0}-objcopy" -f $prefix) -ErrorAction SilentlyContinue

    if ($gccCandidate -and $objdumpCandidate -and $objcopyCandidate) {
        $toolPrefix = $prefix
        break
    }
}

if (-not $toolPrefix) {
    Write-Host "Missing toolchain: riscv64-unknown-elf-* or riscv-none-elf-*" -ForegroundColor Red
    Write-Host "Install a RISC-V GNU Embedded toolchain, then rerun with one of:" -ForegroundColor Yellow
    Write-Host "  1) Add toolchain bin to PATH permanently"
    Write-Host "  2) Pass -ToolchainBin \"C:\path\to\toolchain\bin\""
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Cyan
    Write-Host "  .\build_and_simulate.ps1 -ToolchainBin \"C:\xpack-riscv-none-elf-gcc\bin\""
    throw "Missing toolchain."
}

$gccCmd = "{0}-gcc" -f $toolPrefix
$objdumpCmd = "{0}-objdump" -f $toolPrefix
$objcopyCmd = "{0}-objcopy" -f $toolPrefix
Write-Host "Using toolchain prefix: $toolPrefix" -ForegroundColor Green

if (-not (Test-Path $Source)) {
    throw "Source file not found: $Source"
}
if (-not (Test-Path "link.ld")) {
    throw "link.ld not found in current folder. Run this script from RISC_V/c_program."
}
if (-not (Test-Path "crt0.s")) {
    throw "crt0.s not found in current folder. Run this script from RISC_V/c_program."
}

# 1) Compile ELF for RV32 target using riscv64 cross compiler
Write-Host "[1/4] Compiling ELF..." -ForegroundColor Yellow
& $gccCmd -march=rv32i -mabi=ilp32 -O1 -nostdlib -T link.ld crt0.s $Source -o $Elf
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed."
}

# 2) Disassembly
Write-Host "[2/4] Generating disassembly..." -ForegroundColor Yellow
& $objdumpCmd -d $Elf > "$([System.IO.Path]::GetFileNameWithoutExtension($Elf)).dump"
if ($LASTEXITCODE -ne 0) {
    throw "Objdump failed."
}

# 3) Verilog HEX
Write-Host "[3/4] Generating Verilog HEX..." -ForegroundColor Yellow
& $objcopyCmd -O verilog --verilog-data-width=4 $Elf $Hex
if ($LASTEXITCODE -ne 0) {
    throw "Objcopy failed."
}

# 4) Copy HEX to instruction-memory load path used by instructionmem.v
$targetHex = "..\snn_tests\block4_lif.hex"
Copy-Item -Force $Hex $targetHex
Write-Host "[4/4] Copied $Hex -> $targetHex" -ForegroundColor Yellow

Write-Host "Build complete." -ForegroundColor Green
Write-Host "Artifacts: $Elf, $([System.IO.Path]::GetFileNameWithoutExtension($Elf)).dump, $Hex"

if ($RunSim) {
    Write-Host "=== Running Verilog Simulation ===" -ForegroundColor Cyan

    Push-Location "..\CPU"
    try {
        if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
            throw "iverilog not found in PATH."
        }
        if (-not (Get-Command vvp -ErrorAction SilentlyContinue)) {
            throw "vvp not found in PATH."
        }

        # Use your existing mem-loader testbench by default
        iverilog -I../extention -o cpu_mem_loader_sim CPU_tb_mem_loader.v
        vvp cpu_mem_loader_sim

        Write-Host "Simulation complete. VCD expected: cpu_mem_loader.vcd" -ForegroundColor Green
        Write-Host "Open waveform with: gtkwave cpu_mem_loader.vcd"
    }
    finally {
        Pop-Location
    }
}
