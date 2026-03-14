param(
    [Parameter(Mandatory = $true)]
    [string]$BaseWeights,

    [Parameter(Mandatory = $true)]
    [string]$TrainLog,

    [string]$RepoRoot = "C:\Users\pc\Documents\GitHub\e20-4yp-onchip-offline-neuromorphic-computing",
    [int]$TrainSamples = 5000,
    [int]$TrainOffset = 0,
    [int]$HoldoutSamples = 1000,
    [int]$HoldoutOffset = 1000,
    [int]$Timesteps = 16,
    [int]$Seed = 42,
    [string]$DataRoot = "data",
    [string]$BlameMode = "rate-target",
    [int]$ScalePercent = 10,
    [int]$LRW1 = 1,
    [int]$LRW2 = 1,
    [int]$ClipHidden = 8,
    [int]$ClipDelta = 8,
    [int]$MaxSamples = 256,
    [string]$UpdateMode = "micro-batch",
    [int]$MicroBatchSize = 32,
    [switch]$TargetedW2,
    [switch]$NoCenterOutputBlame
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Get-AccFromLog([string]$LogPath) {
    $pass = (Select-String -Path $LogPath -Pattern "PASS").Count
    $fail = (Select-String -Path $LogPath -Pattern "FAIL").Count
    $total = $pass + $fail
    $acc = if ($total -gt 0) { [math]::Round((100.0 * $pass / $total), 2) } else { 0.0 }
    return [PSCustomObject]@{ Pass = $pass; Fail = $fail; Total = $total; Acc = $acc }
}

$basePath = [System.IO.Path]::GetFullPath($BaseWeights)
$trainLogPath = [System.IO.Path]::GetFullPath($TrainLog)
$trainDir = [System.IO.Path]::GetDirectoryName($trainLogPath)
$trainStem = [System.IO.Path]::GetFileNameWithoutExtension($trainLogPath)
$baseDir = [System.IO.Path]::GetDirectoryName($basePath)
$baseStem = [System.IO.Path]::GetFileNameWithoutExtension($basePath)

New-Item -ItemType Directory -Path $trainDir -Force | Out-Null

if ($trainStem.StartsWith("infer_")) {
    $suffix = $trainStem.Substring(6)
    $smemTrain = Join-Path $trainDir ("smem_" + $suffix + ".csv")
    $blameCsv = Join-Path $trainDir ("inference_blame_" + $suffix + ".csv")
    $beforeCsv = Join-Path $trainDir ("infer_" + $suffix + "_before.csv")
    $beforeLog = Join-Path $trainDir ("infer_" + $suffix + "_before.log")
    $afterCsv = Join-Path $trainDir ("infer_" + $suffix + "_after.csv")
    $afterLog = Join-Path $trainDir ("infer_" + $suffix + "_after.log")
} else {
    $smemTrain = Join-Path $trainDir ($trainStem + "_smem.csv")
    $blameCsv = Join-Path $trainDir ($trainStem + "_blame.csv")
    $beforeCsv = Join-Path $trainDir ($trainStem + "_before.csv")
    $beforeLog = Join-Path $trainDir ($trainStem + "_before.log")
    $afterCsv = Join-Path $trainDir ($trainStem + "_after.csv")
    $afterLog = Join-Path $trainDir ($trainStem + "_after.log")
}

$updatedWeights = Join-Path $baseDir ($baseStem + "_updated.txt")

Write-Host "[1/5] Train inference + SMEM"
python tools\snn_torch_infer_and_dump.py `
  --train `
  --weights $basePath `
  --output-csv $smemTrain `
  --output-log $trainLogPath `
  --num-samples $TrainSamples `
  --offset $TrainOffset `
  --timesteps $Timesteps `
  --seed $Seed `
  --data-root $DataRoot

Write-Host "[2/5] Blame calculation"
$blameArgs = @(
  "tools\\calc_blame_from_inference_log.py",
  "--log", $trainLogPath,
  "--smem", $smemTrain,
  "--output", $blameCsv,
  "--mode", $BlameMode,
  "--original-scale-percent", "$ScalePercent"
)
python @blameArgs

Write-Host "[3/5] Custom-unit training"
$learnArgs = @(
  "tools\\learn_update_weights_custom_unit.py",
  "--weights", $basePath,
  "--smem", $smemTrain,
  "--full-smem", $smemTrain,
  "--blame", $blameCsv,
  "--output", $updatedWeights,
  "--lr-w1", "$LRW1",
  "--lr-w2", "$LRW2",
  "--clip-hidden", "$ClipHidden",
  "--clip-delta", "$ClipDelta",
  "--max-samples", "$MaxSamples",
  "--update-mode", $UpdateMode,
  "--micro-batch-size", "$MicroBatchSize"
)
if ($TargetedW2.IsPresent) {
  $learnArgs += "--targeted-w2"
}
if ($NoCenterOutputBlame.IsPresent) {
  $learnArgs += "--no-center-output-blame"
}
python @learnArgs

Write-Host "[4/5] Holdout before"
python tools\snn_torch_infer_and_dump.py `
  --weights $basePath `
  --output-csv $beforeCsv `
  --output-log $beforeLog `
  --num-samples $HoldoutSamples `
  --offset $HoldoutOffset `
  --timesteps $Timesteps `
  --seed $Seed `
  --data-root $DataRoot > $null

Write-Host "[5/5] Holdout after"
python tools\snn_torch_infer_and_dump.py `
  --weights $updatedWeights `
  --output-csv $afterCsv `
  --output-log $afterLog `
  --num-samples $HoldoutSamples `
  --offset $HoldoutOffset `
  --timesteps $Timesteps `
  --seed $Seed `
  --data-root $DataRoot > $null

$before = Get-AccFromLog $beforeLog
$after = Get-AccFromLog $afterLog
$gain = [math]::Round(($after.Acc - $before.Acc), 2)

Write-Host ""
Write-Host "=== SUMMARY ==="
Write-Host "BASE_WEIGHTS=$basePath"
Write-Host "TRAIN_LOG=$trainLogPath"
Write-Host "TRAIN_SMEM=$smemTrain"
Write-Host "BLAME_CSV=$blameCsv"
Write-Host "UPDATED_WEIGHTS=$updatedWeights"
Write-Host "BEFORE_ACC=$($before.Acc)% ($($before.Pass)/$($before.Total))"
Write-Host "AFTER_ACC=$($after.Acc)% ($($after.Pass)/$($after.Total))"
Write-Host "GAIN=$gain%"
