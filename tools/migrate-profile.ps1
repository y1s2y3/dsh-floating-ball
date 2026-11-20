# Migrate the installed dsh-session-ball-plugin (desktop profile) to dsh-floating-ball.
#
# Why a separate step instead of doing it inside deploy.mjs: the package name is part of the
# Profile's plugin identity (package.json dependencies + dsh.profile.bundles + the loader row's
# `name`). Renaming it while the Host is running makes the Host load the new package name as a
# SECOND plugin instance while the old one is still alive -- two balls, two state writers. So this
# migration must be followed by a DSH Desktop restart, and should be run when that is convenient.
#
# Usage (normally in a normal terminal, outside the DSH sandbox):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\migrate-profile.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\migrate-profile.ps1 -WhatIf
param(
  [string]$ProfileDir = (Join-Path $env:USERPROFILE '.dsh\profiles\desktop'),
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$oldName = 'dsh-session-ball-plugin'
$newName = 'dsh-floating-ball'
$version = '0.11.0'
$pkgPath = Join-Path $ProfileDir 'package.json'
$patchPath = Join-Path $ProfileDir 'cordis.patch.yml'
$oldDir = Join-Path $ProfileDir "node_modules\$oldName"
$newDir = Join-Path $ProfileDir "node_modules\$newName"

if (-not (Test-Path -LiteralPath $pkgPath)) { throw "profile not found: $ProfileDir" }
if (Test-Path -LiteralPath $newDir) { throw "$newDir already exists -- already migrated? Nothing changed." }
if (-not (Test-Path -LiteralPath $oldDir)) { throw "$oldDir not found -- is the plugin installed in this profile?" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function ReadUtf8([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function WriteUtf8([string]$p, [string]$text) { [System.IO.File]::WriteAllText($p, $text, $utf8) }

$profilePkg = ReadUtf8 $pkgPath
$patch = ReadUtf8 $patchPath

if ($WhatIf) {
  Write-Output "would rename: $oldDir -> $newDir"
  Write-Output "would back up: $pkgPath.bak-$stamp and $patchPath.bak-$stamp"
  Write-Output "would rewrite dependency/bundle entry $oldName -> $newName and the loader row name"
  return
}

Copy-Item -LiteralPath $pkgPath -Destination "$pkgPath.bak-$stamp"
Copy-Item -LiteralPath $patchPath -Destination "$patchPath.bak-$stamp"
Rename-Item -LiteralPath $oldDir -NewName $newName

$json = $profilePkg | ConvertFrom-Json
if ($json.dependencies.PSObject.Properties.Name -contains $oldName) {
  $json.dependencies | Add-Member -NotePropertyName $newName -NotePropertyValue $version -Force
  $json.dependencies.PSObject.Properties.Remove($oldName)
}
$bundles = @($json.dsh.profile.bundles | ForEach-Object { if ($_ -eq $oldName) { $newName } else { $_ } })
$json.dsh.profile.bundles = $bundles
WriteUtf8 $pkgPath ($json | ConvertTo-Json -Depth 12)

$patch = $patch.Replace("name: $oldName", "name: $newName")
WriteUtf8 $patchPath $patch

Write-Output 'migrated. Backups:'
Write-Output "  $pkgPath.bak-$stamp"
Write-Output "  $patchPath.bak-$stamp"
Write-Output ''
Write-Output 'NOW RESTART DSH DESKTOP. Until the restart the running Host keeps the old plugin'
Write-Output 'instance; after it, the ball is started by dsh-floating-ball.'
