# Ends the PowerShell process that hosts the session-ball window, so the DSH host
# respawns it with the CURRENT resources/ball.ps1 (the host re-reads the script on
# every spawn and names the materialised copy by its content hash).
#
# The ball is a WPF window created inside `powershell.exe -STA`. Its window class is
# `HwndWrapper[DefaultDomain;Pipeline Execution Thread;...]`, which no other app on
# this machine uses, and the collapsed window is ballSize + 18 px (66x66 by default).
#
# Usage (from a normal terminal, NOT via "& file.ps1"):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\restart-ball.ps1
#
# Exit codes: 0 = stopped at least one ball process / 2 = no ball window found /
#             3 = window found but could not be stopped (permission).
$ErrorActionPreference = 'Stop'

if (-not ([System.Management.Automation.PSTypeName]'BallWindowFinder').Type) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class BallWindowFinder {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
}

$script:ballPids = New-Object System.Collections.Generic.List[int]
$callback = [BallWindowFinder+EnumProc]{
  param($handle, $state)
  if (-not [BallWindowFinder]::IsWindowVisible($handle)) { return $true }
  $className = New-Object System.Text.StringBuilder 512
  [void][BallWindowFinder]::GetClassName($handle, $className, 512)
  if (-not $className.ToString().StartsWith('HwndWrapper[DefaultDomain;Pipeline Execution Thread;')) { return $true }
  $rect = New-Object BallWindowFinder+RECT
  [void][BallWindowFinder]::GetWindowRect($handle, [ref]$rect)
  $width = $rect.R - $rect.L
  $height = $rect.B - $rect.T
  # Any visible window of the ball process will do: when the panel is expanded the only window
  # this process owns is the PANEL (600x280 physical here), the collapsed ball is hidden. The
  # size gate therefore only rules out the zero-sized helper windows of the same process --
  # 20..4096 in both directions covers the 66x66 ball, the 600x575 panel and the picker popup.
  if ($width -lt 20 -or $width -gt 4096 -or $height -lt 20 -or $height -gt 4096) { return $true }
  $owner = 0
  [void][BallWindowFinder]::GetWindowThreadProcessId($handle, [ref]$owner)
  if ($owner -gt 0 -and -not $script:ballPids.Contains([int]$owner)) { $script:ballPids.Add([int]$owner) }
  return $true
}
[void][BallWindowFinder]::EnumWindows($callback, [IntPtr]::Zero)

if ($script:ballPids.Count -eq 0) {
  Write-Output 'ball: no ball window found (it may already be stopped)'
  exit 2
}

foreach ($ownerPid in $script:ballPids) {
  try {
    Stop-Process -Id $ownerPid -Force -ErrorAction Stop
    Write-Output ('ball: stopped powershell.exe pid ' + $ownerPid)
  } catch {
    Write-Output ('ball: could not stop pid ' + $ownerPid + ': ' + $_.Exception.Message)
    exit 3
  }
}
exit 0
