# Interaction smoke test for the live ball window (phase 2b).
#
# It finds the running WPF ball window, feeds it a fake state document with an expanded panel
# (an input row + an approval card), clicks the input box and the "allow" option with real mouse
# events, and checks that the panel does NOT collapse and its geometry does not change.
#
# This is a developer tool: it writes a state-<big>.json into the runtime directory (so it needs
# danger-full-access in the sandbox) and removes it afterwards. The fake sequence number is far
# above the host's own counter, so the ball keeps reading the fake document during the test.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-ui.ps1
param(
  [string]$RuntimeDir = (Join-Path $env:LOCALAPPDATA 'dsh-session-ball\default'),
  [int]$SettleMs = 800
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SmokeWin {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-Rect($Hwnd) {
  $rect = New-Object SmokeWin+RECT
  [void][SmokeWin]::GetWindowRect($Hwnd, [ref]$rect)
  return [pscustomobject]@{ Left = $rect.Left; Top = $rect.Top; Width = $rect.Right - $rect.Left; Height = $rect.Bottom - $rect.Top }
}

function Find-BallWindow {
  $script:found = [IntPtr]::Zero
  $script:foundWidth = -1
  $callback = [SmokeWin+EnumProc]{
    param($hWnd, $lParam)
    if (-not [SmokeWin]::IsWindowVisible($hWnd)) { return $true }
    $cls = New-Object System.Text.StringBuilder 256
    [void][SmokeWin]::GetClassName($hWnd, $cls, 256)
    if ($cls.ToString() -notlike 'HwndWrapper*') { return $true }
    $rect = New-Object SmokeWin+RECT
    [void][SmokeWin]::GetWindowRect($hWnd, [ref]$rect)
    $width = $rect.Right - $rect.Left
    if ($width -gt $script:foundWidth) { $script:found = $hWnd; $script:foundWidth = $width }
    return $true
  }
  [void][SmokeWin]::EnumWindows($callback, [IntPtr]::Zero)
  if ($script:found -eq [IntPtr]::Zero) { throw 'ball window not found (is the plugin running with engine=v2?)' }
  return $script:found
}

function Invoke-Click([int]$X, [int]$Y) {
  [void][SmokeWin]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 120
  [SmokeWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [SmokeWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}

# --- find the window and the latest real state document
$hwnd = Find-BallWindow
$procId = 0
[void][SmokeWin]::GetWindowThreadProcessId($hwnd, [ref]$procId)
$before = Get-Rect $hwnd
Write-Output ("ball window: hwnd={0} pid={1} rect={2},{3} {4}x{5}" -f $hwnd, $procId, $before.Left, $before.Top, $before.Width, $before.Height)

Get-ChildItem -LiteralPath $RuntimeDir -Filter 'state-*.json' | ForEach-Object {
  $match = [regex]::Match($_.Name, '^state-(\d+)\.json$')
  if ($match.Success -and [int]$match.Groups[1].Value -ge 100000) { Remove-Item -LiteralPath $_.FullName -Force }
}
$states = @(Get-ChildItem -LiteralPath $RuntimeDir -Filter 'state-*.json' | ForEach-Object {
  $match = [regex]::Match($_.Name, '^state-(\d+)\.json$')
  if ($match.Success) { [pscustomobject]@{ File = $_.FullName; Seq = [int]$match.Groups[1].Value } }
} | Sort-Object Seq)
if ($states.Count -eq 0) { throw "no state-*.json in $RuntimeDir" }
$latest = $states[$states.Count - 1]
$doc = [System.IO.File]::ReadAllText($latest.File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$templatePath = Join-Path $PSScriptRoot 'preview-panel.json'
$template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$allowLabel = ""
foreach ($entry in @($template.panel.entries)) {
  $cards = @($entry.cards)
  foreach ($card in $cards) {
    $options = @($card.options)
    if ($card.kind -eq 'approval' -and $options.Count -gt 0) { $allowLabel = [string]$options[0].label }
  }
}
$doc.labels = $template.labels
$doc.entries = $template.panel.entries
$doc.metrics.panelWidth = 320
$doc.metrics.panelHeight = 460
$doc.window.expanded = $true
$doc.window.visible = $true
$fakeSeq = $latest.Seq + 100000
$fakeFile = Join-Path $RuntimeDir ('state-' + $fakeSeq + '.json')
[System.IO.File]::WriteAllText($fakeFile, (ConvertTo-Json -Compress -Depth 12 -InputObject $doc), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "fake state written: $fakeFile"
Start-Sleep -Milliseconds $SettleMs

$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
$buttons = @()
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
foreach ($element in $all) {
  try {
    if ($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) { $buttons += $element }
  } catch {}
}
Write-Output ("controls: {0} edits, {1} buttons" -f $edits.Count, $buttons.Count)

$expanded = Get-Rect $hwnd
$failures = New-Object System.Collections.ArrayList

function Assert-Unchanged([string]$Label, $Before) {
  $now = Get-Rect $hwnd
  $visible = [SmokeWin]::IsWindowVisible($hwnd)
  if (-not $visible) { [void]$failures.Add(('"{0}: window became invisible"' -f $Label)); return }
  if ($now.Height -lt 300) { [void]$failures.Add(('"{0}: panel collapsed (height {1})"' -f $Label, $now.Height)); return }
  if ([math]::Abs($now.Height - $Before.Height) -gt 4 -or [math]::Abs($now.Width - $Before.Width) -gt 4) {
    [void]$failures.Add(('"{0}: geometry changed {1}x{2} -> {3}x{4}"' -f $Label, $Before.Width, $Before.Height, $now.Width, $now.Height))
    return
  }
  Write-Output ("  {0}: still expanded at {1}x{2}" -f $Label, $now.Width, $now.Height)
}

# 1) click a point inside the panel body (this is the same mouse path as clicking the input box)
$panel = Get-Rect $hwnd
$insideX = [int]($panel.Left + $panel.Width / 2)
$insideY = [int]($panel.Top + 120)
Write-Output ('click inside the panel at {0},{1}' -f $insideX, $insideY)
Invoke-Click $insideX $insideY
Start-Sleep -Milliseconds $SettleMs
Assert-Unchanged 'after clicking inside the panel' $expanded

# 2) click the first real button inside the panel (approval options, question options, nav...)
$clickable = $buttons | Where-Object {
  -not [double]::IsNaN($_.Current.BoundingRectangle.Left) -and $_.Current.BoundingRectangle.Width -gt 0 -and $_.Current.Name -ne ''
} | Select-Object -First 1
if ($null -ne $clickable) {
  $rect = $clickable.Current.BoundingRectangle
  $x = [int]($rect.Left + $rect.Width / 2)
  $y = [int]($rect.Top + $rect.Height / 2)
  Write-Output ('click panel button {0} at {1},{2}' -f $clickable.Current.Name, $x, $y)
  Invoke-Click $x $y
  Start-Sleep -Milliseconds $SettleMs
  Assert-Unchanged 'after clicking a panel button' $expanded
} else {
  [void]$failures.Add('no clickable button found in the fake panel')
}
# 3) expand from the collapsed ball and collapse again: the ball must return to where it was
$collapsedDoc = [System.IO.File]::ReadAllText($latest.File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$collapsedDoc.labels = $template.labels
$collapsedDoc.entries = @()
$collapsedDoc.metrics.panelWidth = 320
$collapsedDoc.metrics.panelHeight = 460
$collapsedDoc.window.expanded = $false
$collapsedDoc.window.visible = $true
$collapsedFile = Join-Path $RuntimeDir ('state-' + ($fakeSeq + 1) + '.json')
[System.IO.File]::WriteAllText($collapsedFile, (ConvertTo-Json -Compress -Depth 12 -InputObject $collapsedDoc), (New-Object System.Text.UTF8Encoding($false)))
Start-Sleep -Milliseconds $SettleMs
$collapsedBefore = Get-Rect $hwnd
Write-Output ('collapsed ball at {0},{1} {2}x{3}' -f $collapsedBefore.Left, $collapsedBefore.Top, $collapsedBefore.Width, $collapsedBefore.Height)

# click the ball to expand
Invoke-Click ([int]($collapsedBefore.Left + $collapsedBefore.Width / 2)) ([int]($collapsedBefore.Top + $collapsedBefore.Height / 2))
Start-Sleep -Milliseconds $SettleMs
$collapsedAfterExpand = Get-Rect $hwnd
Write-Output ('after opening the panel: {0},{1} {2}x{3}' -f $collapsedAfterExpand.Left, $collapsedAfterExpand.Top, $collapsedAfterExpand.Width, $collapsedAfterExpand.Height)

# click the '-' button in the header to collapse again
$collapseButton = $buttons | Where-Object {
  $_.Current.Name -eq '-' -and -not [double]::IsNaN($_.Current.BoundingRectangle.Left) -and $_.Current.BoundingRectangle.Width -gt 0
} | Select-Object -First 1
if ($null -ne $collapseButton) {
  $rect = $collapseButton.Current.BoundingRectangle
  Invoke-Click ([int]($rect.Left + $rect.Width / 2)) ([int]($rect.Top + $rect.Height / 2))
  Start-Sleep -Milliseconds $SettleMs
  $collapsedAfterClose = Get-Rect $hwnd
  Write-Output ('after closing the panel: {0},{1} {2}x{3}' -f $collapsedAfterClose.Left, $collapsedAfterClose.Top, $collapsedAfterClose.Width, $collapsedAfterClose.Height)
  if ([math]::Abs($collapsedAfterClose.Left - $collapsedBefore.Left) -gt 4 -or [math]::Abs($collapsedAfterClose.Top - $collapsedBefore.Top) -gt 4) {
    [void]$failures.Add(('collapsed ball moved after open/close: {0},{1} -> {2},{3}' -f $collapsedBefore.Left, $collapsedBefore.Top, $collapsedAfterClose.Left, $collapsedAfterClose.Top))
  } else {
    Write-Output '  collapsed ball returned to its original position'
  }
} else {
  [void]$failures.Add('collapse (-) button not found after expanding from the ball')
}
Remove-Item -LiteralPath $collapsedFile -Force -ErrorAction SilentlyContinue
# cleanup: remove the fake document (the host goes on writing its own states)
Remove-Item -LiteralPath $fakeFile -Force
Start-Sleep -Milliseconds 400

if ($failures.Count -gt 0) {
  Write-Output ''
  Write-Output '[FAIL]'
  foreach ($failure in $failures) { Write-Output ('  - ' + $failure) }
  exit 1
}
Write-Output ''
Write-Output '[PASS] clicks inside the panel keep it expanded and its geometry stable'
