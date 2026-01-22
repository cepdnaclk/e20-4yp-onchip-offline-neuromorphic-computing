# PowerShell simulation script for backpropagation neuron
# Compiles and runs the testbench using Icarus Verilog on Windows

Write-Host "========================================"
Write-Host "Backpropagation Neuron Simulation"
Write-Host "========================================"
Write-Host ""

# Clean previous build artifacts
Write-Host "Cleaning previous build files..."
Remove-Item -Path "backprop_neuron_tb.vvp" -ErrorAction SilentlyContinue
Remove-Item -Path "backprop_neuron_tb.vcd" -ErrorAction SilentlyContinue

# Compile the design and testbench
Write-Host "Compiling Verilog files..."
& iverilog -o backprop_neuron_tb.vvp backprop_neuron.v backprop_neuron_tb.v

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Compilation failed!" -ForegroundColor Red
    exit 1
}

Write-Host "Compilation successful!" -ForegroundColor Green
Write-Host ""

# Run the simulation
Write-Host "Running simulation..."
Write-Host "========================================"
& vvp backprop_neuron_tb.vvp

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Simulation failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================"
Write-Host "Simulation completed successfully!" -ForegroundColor Green
Write-Host ""

# Check if VCD file was generated
if (Test-Path "backprop_neuron_tb.vcd") {
    Write-Host "Waveform file generated: backprop_neuron_tb.vcd" -ForegroundColor Cyan
    Write-Host "To view waveforms, run: gtkwave backprop_neuron_tb.vcd" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: No waveform file generated" -ForegroundColor Yellow
}

Write-Host "========================================"
