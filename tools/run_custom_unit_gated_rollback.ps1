param(
    [Parameter(Mandatory = $true)]
    [string]$BaseWeights,

    [string]$RepoRoot = "C:\Users\pc\Documents\GitHub\e20-4yp-onchip-offline-neuromorphic-computing",
    [string]$DataRoot = "data",
    [int]$TrainSamples = 320,
    [int]$TrainOffset = 0,
    [int]$Timesteps = 16,
    [int]$Seed = 42,

    [int]$HoldoutSamples = 1000,
    [int]$HoldoutOffset = 1000,
    [int[]]$ProtectOffsets = @(1000, 2000, 3000),

    [int]$ChunkSamples = 32,
    [int]$MaxChunks = 10,
    [double]$ProtectDropTolerance = 0.0,
    [int]$MinChunkNonzero = 8,
    [bool]$AutoCalibratePolarity = $true,
    [int]$CalibrationChunkSamples = 32,

    [string]$BlameMode = "rate-target-sparse-inverted",
    [int]$ScalePercent = 1,
    [int]$MarginDivisor = 128,
    [int]$MaxBlame = 2,
    [int]$MarginUpdateThreshold = 128,
    [switch]$OnlyFail,
    [int]$RateTargetMaxBlame = 2,

    [int]$LRW1 = 1,
    [int]$LRW2 = 1,
    [int]$ClipHidden = 4,
    [int]$ClipDelta = 4,
    [string]$UpdateMode = "micro-batch",
    [int]$MicroBatchSize = 16,

    [switch]$TargetedW2,
    [switch]$NoCenterOutputBlame
)

$ErrorActionPreference = "Stop"
Set-Location $RepoRoot

function Get-AccFromLog([string]$LogPath) {
    if (!(Test-Path $LogPath)) {
        throw "Missing log file: $LogPath"
    }
    $pass = (Select-String -Path $LogPath -Pattern "PASS").Count
    $fail = (Select-String -Path $LogPath -Pattern "FAIL").Count
    $total = $pass + $fail
    $acc = if ($total -gt 0) { [math]::Round((100.0 * $pass / $total), 2) } else { 0.0 }
    return [PSCustomObject]@{ Pass = $pass; Fail = $fail; Total = $total; Acc = $acc }
}

function Invoke-PythonChecked([string[]]$PyArgs) {
  & python @PyArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Python command failed (exit=$LASTEXITCODE): python $($PyArgs -join ' ')"
  }
}

  function Evaluate-OnProtectionWindows([string]$WeightsPath, [string]$Tag, [string]$WorkDir, [string]$BaseStem) {
    $offsets = $ProtectOffsets
    if ($null -eq $offsets -or $offsets.Count -eq 0) {
      $offsets = @($HoldoutOffset)
    }

    $rows = @()
    foreach ($off in $offsets) {
      $csvPath = Join-Path $WorkDir ("infer_" + $BaseStem + "_" + $Tag + "_off" + $off + ".csv")
      $logPath = Join-Path $WorkDir ("infer_" + $BaseStem + "_" + $Tag + "_off" + $off + ".log")

      Invoke-PythonChecked @(
        "tools\\snn_torch_infer_and_dump.py",
        "--weights", $WeightsPath,
        "--output-csv", $csvPath,
        "--output-log", $logPath,
        "--num-samples", "$HoldoutSamples",
        "--offset", "$off",
        "--timesteps", "$Timesteps",
        "--seed", "$Seed",
        "--data-root", $DataRoot
      )

      $st = Get-AccFromLog $logPath
      $rows += [PSCustomObject]@{ Offset = $off; Acc = $st.Acc; Pass = $st.Pass; Total = $st.Total }
    }

    $meanAcc = [math]::Round((($rows | Measure-Object -Property Acc -Average).Average), 2)
    return [PSCustomObject]@{ MeanAcc = $meanAcc; Windows = $rows }
  }

$basePath = [System.IO.Path]::GetFullPath($BaseWeights)
$baseStem = [System.IO.Path]::GetFileNameWithoutExtension($basePath)
$baseDir = [System.IO.Path]::GetDirectoryName($basePath)

$workDir = "tools\data"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$smemTrain = Join-Path $workDir ("smem_" + $baseStem + "_gated_train.csv")
$trainLog = Join-Path $workDir ("infer_" + $baseStem + "_gated_train.log")
$blameCsv = Join-Path $workDir ("inference_blame_" + $baseStem + "_gated.csv")

$currentWeights = Join-Path $baseDir ($baseStem + "_gated_current.txt")
$finalWeights = Join-Path $baseDir ($baseStem + "_gated_final.txt")
Copy-Item -Path $basePath -Destination $currentWeights -Force

Write-Host "[0/6] Baseline holdout evaluation"
$baseEval = Evaluate-OnProtectionWindows -WeightsPath $currentWeights -Tag "gated_base_holdout" -WorkDir $workDir -BaseStem $baseStem
$currentBestAcc = $baseEval.MeanAcc
$acceptedChunks = 0

Write-Host "Starting protection mean accuracy: $currentBestAcc%"
foreach ($w in $baseEval.Windows) {
    Write-Host ("  offset=" + $w.Offset + " acc=" + $w.Acc + "% (" + $w.Pass + "/" + $w.Total + ")")
}

$selectedBlameMode = $BlameMode

if ($AutoCalibratePolarity) {
    $partnerMode = $null
    switch ($BlameMode) {
        "rate-target" { $partnerMode = "rate-target-inverted" }
        "rate-target-inverted" { $partnerMode = "rate-target" }
        "rate-target-sparse" { $partnerMode = "rate-target-sparse-inverted" }
        "rate-target-sparse-inverted" { $partnerMode = "rate-target-sparse" }
        "class-directional" { $partnerMode = "class-directional-inverted" }
        "class-directional-inverted" { $partnerMode = "class-directional" }
        default { $partnerMode = $null }
    }

    if ($null -ne $partnerMode) {
        Write-Host ""
        Write-Host "[Calibrate] Probing blame polarity on first chunk"

        Invoke-PythonChecked @(
          "tools\\snn_torch_infer_and_dump.py",
          "--train",
          "--weights", $currentWeights,
          "--output-csv", $smemTrain,
          "--output-log", $trainLog,
          "--num-samples", "$TrainSamples",
          "--offset", "$TrainOffset",
          "--timesteps", "$Timesteps",
          "--seed", "$Seed",
          "--data-root", $DataRoot
        )

        $bestMode = $BlameMode
        $bestAcc = -1.0

        foreach ($probeMode in @($BlameMode, $partnerMode)) {
            $probeBlame = Join-Path $workDir ("inference_blame_" + $baseStem + "_cal_" + $probeMode + ".csv")
            $probeCandidate = Join-Path $baseDir ($baseStem + "_cal_candidate_" + $probeMode + ".txt")

            $probeBlameArgs = @(
              "tools\\calc_blame_from_inference_log.py",
              "--log", $trainLog,
              "--smem", $smemTrain,
              "--output", $probeBlame,
              "--mode", $probeMode,
              "--original-scale-percent", "$ScalePercent"
            )
            if ($probeMode -eq "margin-directional") {
              $probeBlameArgs += @("--margin-divisor", "$MarginDivisor", "--max-blame", "$MaxBlame", "--margin-update-threshold", "$MarginUpdateThreshold")
            }
            if ($probeMode -like "rate-target*") {
              $probeBlameArgs += @("--rate-target-max-blame", "$RateTargetMaxBlame")
            }
            if ($OnlyFail.IsPresent) {
              $probeBlameArgs += "--only-fail"
            }
            Invoke-PythonChecked $probeBlameArgs

            $probeLearnArgs = @(
              "tools\\learn_update_weights_custom_unit.py",
              "--weights", $currentWeights,
              "--smem", $smemTrain,
              "--full-smem", $smemTrain,
              "--blame", $probeBlame,
              "--output", $probeCandidate,
              "--lr-w1", "$LRW1",
              "--lr-w2", "$LRW2",
              "--clip-hidden", "$ClipHidden",
              "--clip-delta", "$ClipDelta",
              "--update-mode", $UpdateMode,
              "--micro-batch-size", "$MicroBatchSize",
              "--sample-offset", "0",
              "--max-samples", "$CalibrationChunkSamples"
            )
            if ($TargetedW2.IsPresent) {
              $probeLearnArgs += "--targeted-w2"
            }
            if ($NoCenterOutputBlame.IsPresent) {
              $probeLearnArgs += "--no-center-output-blame"
            }
            Invoke-PythonChecked $probeLearnArgs

            $probeEval = Evaluate-OnProtectionWindows -WeightsPath $probeCandidate -Tag ("cal_" + $probeMode) -WorkDir $workDir -BaseStem $baseStem
            Write-Host "  probe mode=$probeMode holdout_mean_acc=$($probeEval.MeanAcc)%"
            if ($probeEval.MeanAcc -gt $bestAcc) {
              $bestAcc = $probeEval.MeanAcc
                $bestMode = $probeMode
            }
        }

        $selectedBlameMode = $bestMode
        Write-Host "[Calibrate] Selected blame mode: $selectedBlameMode"
    } else {
        Write-Host "[Calibrate] No invertible pair for mode '$BlameMode'; using as-is"
    }
}

for ($chunk = 0; $chunk -lt $MaxChunks; $chunk++) {
    $sampleOffset = $chunk * $ChunkSamples
    if ($sampleOffset -ge $TrainSamples) {
        break
    }

    Write-Host ""
    Write-Host "[Chunk $($chunk+1)/$MaxChunks] sample-offset=$sampleOffset"

    Write-Host "  [1] Train inference + SMEM from current weights"
    Invoke-PythonChecked @(
      "tools\\snn_torch_infer_and_dump.py",
      "--train",
      "--weights", $currentWeights,
      "--output-csv", $smemTrain,
      "--output-log", $trainLog,
      "--num-samples", "$TrainSamples",
      "--offset", "$TrainOffset",
      "--timesteps", "$Timesteps",
      "--seed", "$Seed",
      "--data-root", $DataRoot
    )

    Write-Host "  [2] Blame generation with confidence gating"
    $blameArgs = @(
      "tools\\calc_blame_from_inference_log.py",
      "--log", $trainLog,
      "--smem", $smemTrain,
      "--output", $blameCsv,
      "--mode", $selectedBlameMode,
      "--original-scale-percent", "$ScalePercent"
    )
    if ($selectedBlameMode -eq "margin-directional") {
      $blameArgs += @("--margin-divisor", "$MarginDivisor", "--max-blame", "$MaxBlame", "--margin-update-threshold", "$MarginUpdateThreshold")
    }
    if ($selectedBlameMode -like "rate-target*") {
      $blameArgs += @("--rate-target-max-blame", "$RateTargetMaxBlame")
    }
    if ($OnlyFail.IsPresent) {
      $blameArgs += "--only-fail"
    }
    Invoke-PythonChecked $blameArgs

    # Count nonzero-blame samples in this specific chunk window and skip low-signal chunks.
    $allRows = Import-Csv -Path $blameCsv
    $grouped = $allRows | Group-Object -Property sample
    $chunkGroups = $grouped | Sort-Object { [int]$_.Name } | Select-Object -Skip $sampleOffset -First $ChunkSamples
    $chunkNonzero = 0
    foreach ($g in $chunkGroups) {
      $row = $g.Group | Select-Object -First 1
      $vals = 0..9 | ForEach-Object { [int]$row.("blame_o$_") }
      if (($vals | Where-Object { $_ -ne 0 }).Count -gt 0) {
        $chunkNonzero += 1
      }
    }
    Write-Host "  Chunk nonzero-blame samples: $chunkNonzero"
    if ($chunkNonzero -lt $MinChunkNonzero) {
      Write-Host "  SKIPPED | nonzero-blame below threshold ($chunkNonzero < $MinChunkNonzero)"
      continue
    }

    $candidateWeights = Join-Path $baseDir ($baseStem + "_gated_candidate_chunk" + ($chunk + 1) + ".txt")

    Write-Host "  [3] Custom-unit learning on chunk"
    $learnArgs = @(
      "tools\\learn_update_weights_custom_unit.py",
      "--weights", $currentWeights,
      "--smem", $smemTrain,
      "--full-smem", $smemTrain,
      "--blame", $blameCsv,
      "--output", $candidateWeights,
      "--lr-w1", "$LRW1",
      "--lr-w2", "$LRW2",
      "--clip-hidden", "$ClipHidden",
      "--clip-delta", "$ClipDelta",
      "--update-mode", $UpdateMode,
      "--micro-batch-size", "$MicroBatchSize",
      "--sample-offset", "$sampleOffset",
      "--max-samples", "$ChunkSamples"
    )
    if ($TargetedW2.IsPresent) {
      $learnArgs += "--targeted-w2"
    }
    if ($NoCenterOutputBlame.IsPresent) {
      $learnArgs += "--no-center-output-blame"
    }
    Invoke-PythonChecked $learnArgs

    Write-Host "  [4] Protection holdout evaluation (multi-window mean)"
    $chunkEval = Evaluate-OnProtectionWindows -WeightsPath $candidateWeights -Tag ("gated_chunk" + ($chunk + 1)) -WorkDir $workDir -BaseStem $baseStem
    $delta = [math]::Round(($chunkEval.MeanAcc - $currentBestAcc), 2)

    if ($chunkEval.MeanAcc + $ProtectDropTolerance -ge $currentBestAcc) {
        Copy-Item -Path $candidateWeights -Destination $currentWeights -Force
      $currentBestAcc = $chunkEval.MeanAcc
        $acceptedChunks += 1
      Write-Host "  ACCEPTED | mean_acc=$($chunkEval.MeanAcc)% | delta=$delta%"
    } else {
      Write-Host "  REJECTED | mean_acc=$($chunkEval.MeanAcc)% | delta=$delta%"
    }
}

Copy-Item -Path $currentWeights -Destination $finalWeights -Force

Write-Host ""
Write-Host "=== FINAL SUMMARY ==="
Write-Host "BASE_WEIGHTS=$basePath"
Write-Host "FINAL_WEIGHTS=$finalWeights"
Write-Host "BASE_MEAN_ACC=$($baseEval.MeanAcc)%"
Write-Host "FINAL_MEAN_ACC=$currentBestAcc%"
Write-Host "ACCEPTED_CHUNKS=$acceptedChunks"
Write-Host "CHUNK_SAMPLES=$ChunkSamples"
Write-Host "MAX_CHUNKS=$MaxChunks"
Write-Host "MIN_CHUNK_NONZERO=$MinChunkNonzero"
Write-Host "PROTECT_OFFSETS=$($ProtectOffsets -join ',')"
Write-Host "BLAME_MODE_REQUESTED=$BlameMode"
Write-Host "BLAME_MODE_SELECTED=$selectedBlameMode"
Write-Host "ONLY_FAIL=$($OnlyFail.IsPresent)"
Write-Host "RATE_TARGET_MAX_BLAME=$RateTargetMaxBlame"
