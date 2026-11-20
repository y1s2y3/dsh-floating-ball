# Preview harness for the clean-room ball + panel (resources/ball-v2.ps1).
#
# Writes fake state documents (one per status color, one expanded panel) and asks ball-v2 to
# render itself as alpha PNGs (see DSH_BALL_RENDER there). Nothing is shown on the desktop and the
# production ball is not touched.
#
# Chinese display strings live in tools/preview-panel.json (UTF-8) and are read explicitly; this
# script stays pure ASCII because PowerShell 5.1 would otherwise decode it as ANSI.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\preview-ball.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\preview-ball.ps1 -OutDir D:\shots -BallSize 160
param(
  [string]$OutDir = (Join-Path $env:TEMP 'dsh-ball-v2-preview'),
  [int]$BallSize = 160,
  [string]$FontFamily = '',
  [string]$Tag = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$ballScript = Join-Path $repoRoot 'resources\ball-v2.ps1'
$templatePath = Join-Path $PSScriptRoot 'preview-panel.json'
if (-not (Test-Path $ballScript)) { throw "missing $ballScript" }
if (-not (Test-Path $templatePath)) { throw "missing $templatePath" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$suffix = ''
if ($Tag -ne '') { $suffix = '-' + $Tag }
$results = New-Object System.Collections.ArrayList

function Add-Result([string]$name, [string]$file) {
  $exists = Test-Path -LiteralPath $file
  $bytes = 0
  if ($exists) { $bytes = (Get-Item -LiteralPath $file).Length }
  [void]$results.Add([pscustomobject]@{ name = $name; file = $file; exists = $exists; bytes = $bytes })
}

function Write-StateFile([string]$path, [object]$doc) {
  [System.IO.File]::WriteAllText($path, (ConvertTo-Json -Compress -Depth 10 -InputObject $doc), (New-Object System.Text.UTF8Encoding($false)))
}

function New-BallState([string]$key, [string]$color, [bool]$running, [int]$pending, [int]$size, [bool]$expanded) {
  $label = ''
  if ($null -ne $template.statusLabels) {
    $value = $template.statusLabels.PSObject.Properties[$key]
    if ($null -ne $value) { $label = [string]$value.Value }
  }
  $doc = [ordered]@{
    v = 9
    status = [ordered]@{ key = $key; color = $color; label = $label }
    running = $running
    pendingCount = $pending
    labels = $template.labels
    meta = $template.meta
    footer = $template.footer
    metrics = [ordered]@{ ballSize = $size; panelWidth = $template.panel.panelWidth; panelHeight = $template.panel.panelHeight }
    window = [ordered]@{ visible = $true; expanded = $expanded; opacity = 1.0; x = 200; y = 160 }
  }
  if ($expanded) {
    $doc.entries = $template.panel.entries
    $doc.metrics.panelWidth = $template.panel.panelWidth
    $doc.metrics.panelHeight = $template.panel.panelHeight
  } else {
    $doc.entries = @()
  }
  return $doc
}

function Invoke-BallRender([string]$stateFile, [string]$outFile, [string]$halo) {
  $env:DSH_BALL_PREVIEW = '1'
  $env:DSH_BALL_STATE_FILE = $stateFile
  $env:DSH_BALL_RENDER = $outFile
  $env:DSH_BALL_LOG = Join-Path $OutDir 'ball-v2.log'
  $env:DSH_BALL_FONTS = Join-Path $repoRoot 'assets\fonts'
  if ($FontFamily -ne '') { $env:DSH_BALL_FONT_FAMILY = $FontFamily } else { Remove-Item Env:DSH_BALL_FONT_FAMILY -ErrorAction SilentlyContinue }
  if ($halo) { $env:DSH_BALL_HALO = $halo } else { Remove-Item Env:DSH_BALL_HALO -ErrorAction SilentlyContinue }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ballScript 2>&1 | Out-Null
  Add-Result (Split-Path -Leaf $outFile) $outFile
}

$cases = @(
  @{ name = 'idle';    key = 'idle';    color = '#FF7C8598'; running = $false; pending = 0 },
  @{ name = 'working'; key = 'working'; color = '#FF5B8DEF'; running = $true;  pending = 0 },
  @{ name = 'asking';  key = 'asking';  color = '#FFE0A64B'; running = $true;  pending = 1 },
  @{ name = 'error';   key = 'error';   color = '#FFE0574B'; running = $false; pending = 0 }
)

foreach ($case in $cases) {
  $stateFile = Join-Path $OutDir ('state-' + $case.name + '.json')
  Write-StateFile $stateFile (New-BallState $case.key $case.color $case.running $case.pending $BallSize $false)
  Invoke-BallRender $stateFile (Join-Path $OutDir ('ball-' + $case.name + $suffix + '.png')) ''
}

foreach ($frame in @(@{ name = 'breath-low'; halo = '0.28' }, @{ name = 'breath-high'; halo = '0.82' })) {
  $stateFile = Join-Path $OutDir 'state-working.json'
  Invoke-BallRender $stateFile (Join-Path $OutDir ('ball-' + $frame.name + $suffix + '.png')) $frame.halo
}

$panelState = Join-Path $OutDir 'state-panel.json'
Write-StateFile $panelState (New-BallState 'asking' '#FFE0A64B' $true 1 48 $true)
Invoke-BallRender $panelState (Join-Path $OutDir ('ball-panel' + $suffix + '.png')) ''

# A panel that holds only the question card, so the multi-item answer UI is easy to inspect.
$questionEntry = $null
foreach ($entry in @($template.panel.entries)) {
  $cards = @($entry.cards)
  if ($cards.Count -gt 0 -and [string]$cards[0].kind -eq 'question') { $questionEntry = $entry; break }
}
if ($null -ne $questionEntry) {
  $questionState = Join-Path $OutDir 'state-question.json'
  $questionDoc = New-BallState 'asking' '#FFE0A64B' $true 1 48 $true
  $questionDoc.entries = @($questionEntry)
  Write-StateFile $questionState $questionDoc
  Invoke-BallRender $questionState (Join-Path $OutDir ('ball-question' + $suffix + '.png')) ''
}

$stateFile = Join-Path $OutDir 'state-working-48.json'
Write-StateFile $stateFile (New-BallState 'working' '#FF5B8DEF' $true 0 48 $false)
Invoke-BallRender $stateFile (Join-Path $OutDir ('ball-working-48' + $suffix + '.png')) ''

foreach ($key in @('DSH_BALL_PREVIEW', 'DSH_BALL_STATE_FILE', 'DSH_BALL_RENDER', 'DSH_BALL_LOG', 'DSH_BALL_HALO', 'DSH_BALL_FONTS', 'DSH_BALL_FONT_FAMILY')) {
  Remove-Item ("Env:" + $key) -ErrorAction SilentlyContinue
}

Write-Output ('preview written to ' + $OutDir)
$results | Format-Table -AutoSize
