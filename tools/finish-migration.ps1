# Finish the dsh-session-ball-plugin -> dsh-floating-ball migration.
#
# The migration (tools/migrate-profile.ps1) renames the package and updates the Profile. While the
# old plugin instance is still alive in the running Host it keeps loading its ball script from the
# OLD path, so a throw-away copy of the package was left under the old name to keep the ball
# working until the next DSH Desktop restart. After that restart the Host loads dsh-floating-ball,
# and this page-2 cleanup deletes the compatibility copy.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\finish-migration.ps1 -WhatIf
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\finish-migration.ps1
param(
  [string]$ProfileDir = (Join-Path $env:USERPROFILE '.dsh\profiles\desktop'),
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$newDir = Join-Path $ProfileDir 'node_modules\dsh-floating-ball'
$oldDir = Join-Path $ProfileDir 'node_modules\dsh-session-ball-plugin'

if (-not (Test-Path -LiteralPath $newDir)) { throw "missing $newDir -- run migrate-profile.ps1 first" }
if (-not (Test-Path -LiteralPath $oldDir)) { Write-Output 'nothing to clean: the old-name copy is already gone.'; return }

if ($WhatIf) {
  Write-Output "would delete the compatibility copy: $oldDir"
  return
}

Remove-Item -LiteralPath $oldDir -Recurse -Force
Write-Output "deleted $oldDir"
Write-Output 'the running Host must already have been restarted after the migration; if the ball disappears now, restart DSH Desktop once.'
