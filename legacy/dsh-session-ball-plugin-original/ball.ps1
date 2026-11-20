# dsh-session-ball - native always-on-top overlay for the DeepSeek Harness.
#
# THIS FILE IS PURE ASCII ON PURPOSE: PowerShell 5.1 decodes a .ps1 as ANSI unless it
# carries a UTF-8 BOM, so every display string arrives at runtime inside the state JSON
# (read explicitly as UTF-8). Do not add non-ASCII characters.
#
# One process, one window, two shapes: the collapsed ball (drag to move, click to expand,
# badge = pending count) and the expanded panel. The panel is filled by ONE ENTRY PER
# SESSION: a session that is outputting, that is waiting for you (a question or an approval),
# or that has just errored gets an entry, and an entry carries that session's own text box,
# that session's own cards, the row's own "got it" and "x" buttons. There is no target
# dropdown and no panel-wide compose row any more: the box and its target ARE the same
# entry, so a sentence can never go to the wrong session. The panel's header keeps the
# aggregate status colour, the aggregate meta line and the footer notices, plus the "+"
# button that adds an empty entry (a session to be created inside a workspace).
#
# The panel's height follows its content up to the host's panelHeight, and it is always
# settled BEFORE the window is resized. Both shapes drag from any spot that is not a
# control; the host remembers ONE position - the one the collapsed ball would sit at
# (first run: bottom-right). The panel shows no thinking, no text and no tool content,
# only what you can act on.
#
# ONE BALL FOR ALL SESSIONS: the status colour is AGGREGATE. It says whether something is
# waiting for you (a question or an approval), whether some session errored, or whether
# anything is STILL OUTPUTTING (the host's blue 'working' colour), and nothing else. It does
# NOT follow one session's thinking / writing / tool step. Which session an entry is comes
# from the host (the entry's headline and detail line), and the meta line carries the
# aggregate counts.
#
# AN ENTRY STAYS UNTIL YOU REMOVE IT: it does not go away when its session goes idle - it
# just goes grey (so you can still talk to that session). The host only adds an entry for
# "something is happening here", and it does not add the same one back until that session
# has news again (the host's own activity counter), which is what makes "x" stick even for
# a session that is running right now.
#
# THE RED ONE IS THE ONLY COLOUR A HUMAN CLEARS: an error paints the ball red and keeps it
# red until somebody presses "got it" on that row (the host stops counting that error then;
# the entry stays, reading "acked" until you press "x"), OR until you press that row's "x" -
# the host treats "x" as "got it" plus "remove the row", because the "got it" button lives ON
# the row: once the row is gone there would be no way left to clear that red. A session that
# starts outputting again, or errors again, brings the colour back - so red needs no other
# hint.
#
# THE TURN SIGNAL: 'working' is the one status that ends BY ITSELF -- the last session to stop
# outputting makes the ring fall back to the idle grey, so "is that task done yet?" is answered
# by the colour without reading a word. Two things carry it, and both are read straight off the
# state document (no clock of the ball's own, no host round trip):
#   * the ring and the status dot wear the host's colour (blue while anything is outputting);
#   * the white halo -- which ALREADY meant 'a session is running' -- BREATHES instead of
#     sitting lit, so the ball reads as alive from the corner of your eye and goes completely
#     quiet when the last session stops. The breath is attached and taken off only when that
#     boolean changes (a fresh animation per state document would restart it ~8 times a second
#     while a model streams, which reads as a stuck ball, not a breathing one) and it is paused
#     while the panel is open, where the collapsed ball is hidden anyway.
# A non-'working' status is deliberately NOT breathing: an amber 'someone is waiting for you'
# or a red 'something errored' must sit still and be looked at, not shimmer. A host OLDER than
# state document v7 has no colour for this state at all (it says the count in the label and
# paints the idle grey); the ball then paints that state in its own accent blue, so the signal
# does not depend on the harness having been restarted -- see the version test in Apply-State.
#
# File protocol, all inside $env:DSH_BALL_BASE:
#   state-<n>.json        host -> ball  the whole view state, published as a NEW numbered
#                                       file per update; the ball reads the highest number,
#                                       so no handle conflict can stall the view.
#   act-<pid>-<seq>.json  ball -> host  one queued user action per file, consumed and
#                                       deleted by the host (no click lost to a race).
#   ball.log              ball -> disk  diagnostics, appended (UTF-8).
#
# Window: WS_EX_NOACTIVATE + ShowActivated=false, so the ball never takes the keyboard (the
# one exception is a text box the user clicked, see KEYBOARD); WS_EX_TOOLWINDOW keeps it out
# of Alt+Tab; Topmost keeps it readable. It NEVER gets out of the way: shape, opacity and
# clickability stay put while the model drives the mouse, so a click aimed at the pixel
# under the ball lands on it, and the ball shows up in desktop screenshots.
#
# KEYBOARD: only a text box the user clicked may hold the keyboard. A WS_EX_NOACTIVATE
# window receives no keys, so the click makes it drop that style, take the foreground and
# focus the box, remembering what had the foreground. Enter sends and keeps the keyboard,
# Escape gives it back, and a lock, Escape, losing activation or collapsing all end the mode
# at once. While the user types, injected keys from a desktop-driving tool land in that box
# and Enter is read as send.
#
# SENDING: every entry that can be talked to carries its own one-line box and its own Send
# button, and the box knows its target (the host puts it on the entry) - so there is no
# dropdown to get wrong and no "sent to whom?" question. The "+" button in the header opens
# a one-row-per-workspace picker and adds a LOCAL empty entry for the chosen workspace (its
# title says which one): text typed there creates a session inside that workspace, which is
# the only way a new session ends up registered in that sidebar group (create({ workspaceId });
# a bare cwd leaves it in the ungrouped list). A local entry is handed over to the real
# session as soon as the host's receipt names it.
#
# The row is LOCKED while its own target is outputting and for a few seconds after a send -
# that grey box is the answer to 'did my sentence go out?'. An entry that is not outputting
# is never locked. The receipt for a send also writes the outcome into that same row's own
# notice line, right under the box the user just typed in.
#
# ANSWERING: a question card keeps ONE selection store per card; an incomplete answer is
# refused and said in the card. Cards are rendered INSIDE the entry of the session they
# belong to, so nobody has to read "which session asked this". The script exits when its
# parent host process disappears.


$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace DshBall -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(System.IntPtr hWnd, int nIndex, int dwNewLong);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SetFocus(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, System.IntPtr processId);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint GetCurrentThreadId();
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct NativePoint { public int X; public int Y; }
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetCursorPos(out NativePoint point);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint uCmd);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
private static extern uint QueryWindowProcessId(System.IntPtr hWnd, out uint processId);
// The pid behind a window handle. The z-order walk has to tell OUR OWN windows
// apart from somebody else's: the target dropdown is a window of this very process
// and it is allowed to sit above the ball while it is open.
public static uint WindowProcessId(System.IntPtr hWnd) {
  uint processId = 0;
  QueryWindowProcessId(hWnd, out processId);
  return processId;
}
// HWND_TOPMOST is the pseudo-handle -1, and a topmost window is put back into the
// topmost BAND only by SetWindowPos (see Assert-BallTopmost). The cast lives here
// because a PowerShell 5.1 script has no clean way to write that literal.
public static bool PutOnTopmostBand(System.IntPtr hWnd) {
  return SetWindowPos(hWnd, new System.IntPtr(-1), 0, 0, 0, 0, 0x0002u | 0x0001u | 0x0010u);
}
'@

$BaseDir = $env:DSH_BALL_BASE
if ([string]::IsNullOrEmpty($BaseDir)) { throw 'DSH_BALL_BASE is not set' }
$LogPath = Join-Path $BaseDir 'ball.log'

# A `debug.flag` file in the runtime directory turns on interaction tracing for
# the next ball start. It exists because the host sets the ball's environment
# and a running harness cannot be asked to change it: dropping a file is the
# only way to switch this on without restarting the harness.
if (Test-Path -LiteralPath (Join-Path $BaseDir 'debug.flag')) { $env:DSH_BALL_DEBUG = '1' }

$ParentPid = 0
[void][int]::TryParse($env:DSH_BALL_PARENT_PID, [ref]$ParentPid)

$GWL_EXSTYLE = -20
$WS_EX_NOACTIVATE = 0x08000000
$WS_EX_TOOLWINDOW = 0x00000080
$WS_EX_TOPMOST = 0x00000008
# GW_HWNDPREV = the window ABOVE ours in the z-order (measured on this desktop, not
# read off the doc: it walks one step towards the top of the chain). Used by
# Test-BallCovered.
$GW_HWNDPREV = 3

function Write-BallLog {
  param([string]$Message)
  try {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = '{0} [ball {1}] {2}{3}' -f $stamp, $PID, $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($LogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# Set DSH_BALL_DEBUG=1 in the ball's environment to trace interaction paths
# (clicks, state application) into ball.log.
function Write-BallDebug {
  param([string]$Message)
  if ($env:DSH_BALL_DEBUG -ne '1') { return }
  Write-BallLog ('debug: ' + $Message)
}

function Get-ChildValue {
  param($Object, [string]$Name, $Fallback = $null)
  if ($null -eq $Object) { return $Fallback }
  # Two shapes have to answer alike: a JSON object (what the host sends, a PSCustomObject --
  # read through PSObject.Properties) and a hashtable / ordered dictionary (what this script
  # builds for its own "+ new session" rows -- read through the keys). PSObject.Properties on a
  # dictionary yields the dictionary's OWN members (Count, Keys, ...), not the keys, so asking
  # it for 'title' would answer "no such field" and the row would come out empty.
  if ($Object -is [System.Collections.IDictionary]) {
    if (-not $Object.Contains($Name)) { return $Fallback }
    $entry = $Object[$Name]
    if ($null -eq $entry) { return $Fallback }
    return $entry
  }
  $value = $Object.PSObject.Properties[$Name]
  if ($null -eq $value) { return $Fallback }
  if ($null -eq $value.Value) { return $Fallback }
  return $value.Value
}

# Every display string is authored by the host (this file is ASCII-only), so the
# ball asks the current state document for it by name.
function Get-Label {
  param([string]$Name, [string]$Fallback = '')
  $labels = Get-ChildValue $script:State 'labels' @{}
  $text = [string](Get-ChildValue $labels $Name '')
  if ([string]::IsNullOrWhiteSpace($text)) { return $Fallback }
  return $text
}

# PowerShell 5.1 has no ternary and an `if` statement is not accepted on the
# right-hand side of a property assignment, so every show/hide goes through
# this helper.
function Get-Visibility {
  param([bool]$Condition)
  if ($Condition) { return 'Visible' }
  return 'Collapsed'
}

function ConvertTo-ColorBrush {
  param([string]$Hex, [string]$Fallback = '#FF5B8DEF')
  $text = $Hex
  if ([string]::IsNullOrWhiteSpace($text)) { $text = $Fallback }
  # Theme translation lives here and nowhere else: every runtime brush (including the host's
  # status colours) passes through this function, so one map covers the whole panel. See the
  # DSH theme block below the window shell for the literal -> token table.
  $text = Get-ThemeColor $text
  try {
    $converted = [System.Windows.Media.ColorConverter]::ConvertFromString($text)
    return (New-Object System.Windows.Media.SolidColorBrush($converted))
  } catch {
    $converted = [System.Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeColor $Fallback))
    return (New-Object System.Windows.Media.SolidColorBrush($converted))
  }
}

function Get-NowMs {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

# A state colour used as a HINT rather than a stripe: the entry cards keep a hairline border,
# and a 1px line of the full accent reads like a warning frame. Same colour, half the weight.
function Get-SoftBrush {
  param([string]$Hex, [double]$Opacity = 0.5)
  $brush = ConvertTo-ColorBrush $Hex
  $brush.Opacity = $Opacity
  return $brush
}

$script:Seq = 0

function Send-Action {
  param($Payload)
  try {
    $script:Seq++
    # The caller always hands over an [ordered] dictionary, so the sequence
    # number goes in as a key: Add-Member would attach a note property that
    # ConvertTo-Json silently drops when serializing a dictionary.
    $Payload['seq'] = $script:Seq
    $name = Join-Path $BaseDir ('act-{0}-{1}.json' -f $PID, $script:Seq)
    $temp = $name + '.tmp'
    $json = ConvertTo-Json -InputObject $Payload -Depth 10 -Compress
    [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $name -Force
    Write-BallLog ('action sent: ' + $json)
  } catch {
    Write-BallLog ('action failed: ' + $_.Exception.Message)
  }
}

function Get-NewestStatePath {
  # The host publishes state as a NEW file per update (state-<n>.json) instead of
  # overwriting one file, so nothing here ever collides with its writer; picking the highest
  # number is the whole protocol.
  #
  # The plain `state.json` fallback keeps a ball started by an older host build working: the
  # script is re-read from disk on every ball start, the host module only on a restart.

  $best = $null
  $bestSeq = -1
  try {
    foreach ($file in [System.IO.Directory]::GetFiles($BaseDir, 'state-*.json')) {
      $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
      $seq = 0
      if (-not [int]::TryParse($name.Substring(6), [ref]$seq)) { continue }
      if ($seq -gt $bestSeq) {
        $bestSeq = $seq
        $best = $file
      }
    }
  } catch { }
  if ($null -ne $best) { return $best }

  $legacy = Join-Path $BaseDir 'state.json'
  if (Test-Path -LiteralPath $legacy) { return $legacy }
  return $null
}

function Read-StateText {
  param([string]$Path)
  # Share everything: the host retires old generations while this read may still
  # be in flight. A reader that keeps an exclusive-ish handle would make its
  # delete fail (and vice versa), which is exactly the class of Windows sharing
  # bug this whole file-based protocol exists to avoid.
  try {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
      try {
        return $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    } finally {
      $stream.Dispose()
    }
  } catch {
    return ''
  }
}

# ---------------------------------------------------------------------------
# Window shell
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# DSH theme: the panel wears the DSH design tokens instead of a palette of its own
# ---------------------------------------------------------------------------
#
# Every colour in this file is still WRITTEN as the literal it used to be (the XAML's #FFxxxxxx
# and every ConvertTo-ColorBrush argument); two passes then translate those literals into the
# current DSH palette:
#
#   * the XAML string is rewritten before it is parsed, so the shared templates (IconButton,
#     the slim scrollbar) are theme-aware too;
#   * ConvertTo-ColorBrush translates every runtime brush -- and that is also the one place
#     where the host's own status colours (#FF5B8DEF working, #FF7C8598 idle, #FFE0A64B asking,
#     #FFE0574B error) become DSH's state tokens.
#
# Values are the alias tokens of the DSH design system (dsh-client-ui-theme): the
# body[data-ds-dark-theme] palette for dark, the default body palette for light. A theme
# switch is picked up on the ball's own clock (see the clock timer at the bottom): the process
# closes and the host starts a fresh one, because a WPF template's colours cannot be swapped
# under a live window.

function Get-DshThemeKey {
  # 1) A theme.json in the ball's own runtime directory wins: {"theme":"light"} or
  #    {"theme":"dark"}. This is the manual override for when the automatic answer below
  #    cannot know what the DSH window is really showing.
  # 2) The Profile's ui-theme preference wins when it names a theme ("system" means follow
  #    Windows, which is exactly what DSH does itself).
  # 3) Otherwise the Windows apps theme decides.
  try {
    $overridePath = Join-Path $BaseDir 'theme.json'
    if (Test-Path -LiteralPath $overridePath) {
      $overrideText = [System.IO.File]::ReadAllText($overridePath, [System.Text.Encoding]::UTF8)
      $overrideMatch = [regex]::Match($overrideText, '"theme"\s*:\s*"(light|dark)"')
      if ($overrideMatch.Success) { return $overrideMatch.Groups[1].Value }
    }
  } catch { }
  try {
    $profiles = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh\profiles'
    if (Test-Path -LiteralPath $profiles) {
      foreach ($dir in (Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $dir.FullName 'cordis.patch.yml'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        $match = [regex]::Match($text, '(?s)- id: ui-theme.*?preference:\s*(system|light|dark)')
        if (-not $match.Success) { continue }
        $preference = $match.Groups[1].Value
        if ($preference -eq 'light' -or $preference -eq 'dark') { return $preference }
        break
      }
    }
  } catch { }
  try {
    $personalize = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
    if ([int]$personalize.AppsUseLightTheme -eq 0) { return 'dark' }
    return 'light'
  } catch { }
  return 'dark'
}

# old literal -> DSH token. Keys and values are #AARRGGBB.
$script:ThemeMapDark = @{
  '#F7151922' = '#EE1B1B1D'    # panel gradient top    -> glass, 93% opaque (window stays 1.0)
  '#F70A0C11' = '#EE151517'    # panel gradient bottom -> glass, 93% opaque
  '#2BFFFFFF' = '#1FFFFFFF'    # panel stroke          -> border-l2
  '#F5171A21' = '#FF2C2C2E'    # workspace picker bg   -> bg-layer-2
  '#3C4B63'   = '#29FFFFFF'    # workspace picker edge -> border-l3
  '#14FFFFFF' = '#FF2C2C2E'    # subtle button fill    -> bg-layer-2
  '#1FFFFFFF' = '#14FFFFFF'    # icon button hover     -> interactive-bg-hover
  '#33FFFFFF' = '#24FFFFFF'    # icon button pressed   -> interactive-bg-active
  '#5CFFFFFF' = '#FF545557'    # scrollbar hover       -> neutral-600
  '#2EFFFFFF' = '#1FFFFFFF'    # button/input stroke   -> border-l2
  '#26FFFFFF' = '#1FFFFFFF'    # entry stroke          -> border-l2
  '#FF1D2330' = '#FF232324'    # entry bg              -> bg-layer-1
  '#FF252C3B' = '#FF2C2C2E'    # entry hover           -> bg-layer-2
  '#FF1A1F29' = '#FF2C2C2E'    # card bg               -> bg-layer-2
  '#FF0E1117' = '#FF151517'    # input bg              -> bg-base
  '#FF0E1116' = '#FF151517'    # input bg (second box) -> bg-base
  '#FF12151B' = '#FF151517'    # custom answer bg      -> bg-base
  '#FF1F2A36' = '#1FFFFFFF'    # input/send stroke     -> border-l2
  '#FF10141A' = '#FF353638'    # sending fill          -> bg-layer-3
  '#1AFFFFFF' = '#FF353638'    # send fill             -> bg-layer-3
  '#FFF1F4F9' = '#FFF9FAFB'    # title text            -> label-primary
  '#FFE9EEF7' = '#FFF9FAFB'    # box text              -> label-primary
  '#FFD7DEEA' = '#FFCFD3D6'    # button text           -> label-secondary
  '#FFC7CFDD' = '#FFADB2B8'    # icon button text      -> label-tertiary
  '#FFB9C2D2' = '#FFADB2B8'    # icon button text      -> label-tertiary
  '#FFB4BCCB' = '#FFADB2B8'    # card text             -> label-tertiary
  '#FFA9B2C2' = '#FFADB2B8'    # card text             -> label-tertiary
  '#FF9AA3B4' = '#FFADB2B8'    # entry detail          -> label-tertiary
  '#FF8A93A6' = '#FF979DA6'    # meta line             -> neutral-bluish-500
  '#FF98A2B3' = '#FF81858C'    # countdown             -> label-caption
  '#FF6E7787' = '#FF61666B'    # placeholder/waiting   -> neutral-bluish-700
  '#FF10141B' = '#FF0F1115'    # text on accent        -> neutral-bluish-1000
  '#FF5B8DEF' = '#FF7AAAFF'    # working accent        -> deepseek-400
  '#FF7C8598' = '#FF81858C'    # idle                  -> label-caption
  '#FFE0A64B' = '#FFF59E0B'    # asking / approval     -> amber-500
  '#FFE0574B' = '#FFF25A5A'    # error                 -> red-400
  '#FFE9A79F' = '#FFF25A5A'    # error text            -> red-400
  '#FF55E0574B' = '#55F25A5A'  # ack stroke            -> red-400 at 33%
  '#FFD9A54B' = '#FFF59E0B'    # notice line           -> amber-500
  '#B86E8BFF' = '#B87AAAFF'    # ball body top         -> deepseek-400 at 72%
  '#993550D8' = '#995686FE'    # ball body bottom      -> deepseek-450 at 60%
  '#F2FFFFFF' = '#F2F9FAFB'    # whale mark            -> label-primary
  '#3DFFFFFF' = '#3DF9FAFB'    # halo                  -> label-primary at 24%
  '#0FFFFFFF' = '#0FFFFFFF'    # divider               -> border-l1
}

$script:ThemeMapLight = @{
  '#F7151922' = '#EEFFFFFF'    # glass, 93% opaque: the session rows below stay solid
  '#F70A0C11' = '#EEF9FAFB'
  '#2BFFFFFF' = '#1A000000'
  '#F5171A21' = '#FFFFFFFF'
  '#3C4B63'   = '#1F000000'
  '#14FFFFFF' = '#FFF1F3F5'
  '#1FFFFFFF' = '#0F263148'
  '#33FFFFFF' = '#1A263148'
  '#5CFFFFFF' = '#FFD4D4D4'
  '#2EFFFFFF' = '#1F000000'
  '#26FFFFFF' = '#1F000000'
  '#FF1D2330' = '#FFF7F8FA'
  '#FF252C3B' = '#FFF1F3F5'
  '#FF1A1F29' = '#FFF7F8FA'
  '#FF0E1117' = '#FFFFFFFF'
  '#FF0E1116' = '#FFFFFFFF'
  '#FF12151B' = '#FFFFFFFF'
  '#FF1F2A36' = '#1F000000'
  '#FF10141A' = '#FFE9ECF2'
  '#1AFFFFFF' = '#FFE9ECF2'
  '#FFF1F4F9' = '#FF0F1115'
  '#FFE9EEF7' = '#FF0F1115'
  '#FFD7DEEA' = '#FF61666B'
  '#FFC7CFDD' = '#FF61666B'
  '#FFB9C2D2' = '#FF61666B'
  '#FFB4BCCB' = '#FF61666B'
  '#FFA9B2C2' = '#FF61666B'
  '#FF9AA3B4' = '#FF61666B'
  '#FF8A93A6' = '#FF81858C'
  '#FF98A2B3' = '#FF81858C'
  '#FF6E7787' = '#FFADB2B8'
  '#FF10141B' = '#FFFFFFFF'
  '#FF5B8DEF' = '#FF4176E6'
  '#FF7C8598' = '#FFADB2B8'
  '#FFE0A64B' = '#FFD98629'
  '#FFE0574B' = '#FFEC1313'
  '#FFE9A79F' = '#FFEC1313'
  '#FF55E0574B' = '#55EC1313'
  '#FFD9A54B' = '#FFD98629'
  '#B86E8BFF' = '#C67AAAFF'
  '#993550D8' = '#C64176E6'
  '#F2FFFFFF' = '#F2FFFFFF'
  '#3DFFFFFF' = '#3D4176E6'
  '#0FFFFFFF' = '#0A000000'
}

$script:ThemeKey = Get-DshThemeKey
if ($script:ThemeKey -eq 'light') {
  $script:ThemeMap = $script:ThemeMapLight
  $script:ThemeDivider = '#0A000000'
  $script:ThemeThumb = '#FFE5E5E5'
} else {
  $script:ThemeMap = $script:ThemeMapDark
  $script:ThemeDivider = '#0FFFFFFF'
  $script:ThemeThumb = '#FF3C3C3D'
}
# When the ball's clock may look at the Profile / Windows theme again (0 = on the next tick).
$script:NextThemeCheck = 0
# False until the first state document has been applied: the window stays invisible until then
# (see the startup block at the bottom) so it is never painted at the fallback size.
$script:HasState = $false
# Wall-clock start of this process; the clock timer uses it for the "host stayed silent" fallback.
$script:BootMs = 0

# How the whale mark sits on the ball: the fraction of ballSize it takes, a horizontal flip
# (-1 mirrors it, so the head faces the other way) and a rotation in degrees. Kept here so a
# size/orientation tweak is one number, not a hunt through the XAML.
$script:BallMarkScaleFactor = 0.68
$script:BallMarkFlip = 1
$script:BallMarkAngle = 0
$script:BallMarkShadow = 1
$script:BallMarkBubbles = 1

function Get-ThemeColor {
  param([string]$Hex)
  if ([string]::IsNullOrWhiteSpace($Hex)) { return $Hex }
  $key = $Hex.ToUpperInvariant()
  if ($script:ThemeMap.ContainsKey($key)) { return $script:ThemeMap[$key] }
  return $Hex
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        ShowActivated="False" SizeToContent="Manual"
        WindowStartupLocation="Manual" Width="64" Height="64" Left="0" Top="0"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI">
  <Window.Resources>
    <!-- Rounded flat icon buttons: the stock WPF chrome (hard rectangle + 1px grey border)
         is what made the header read like a debug tool. -->
    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFC7CFDD" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="FontSize" Value="12" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="10" Background="{TemplateBinding Background}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#1FFFFFFF" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#33FFFFFF" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- The one-line send box: a rounded, borderless-inside field. The stock TextBox chrome is
         a hard rectangle, which breaks the soft card look; the template below keeps every
         property the code already sets (Background / BorderBrush / Padding) and just wraps it
         in a rounded Border. -->
    <Style x:Key="SlimBox" TargetType="TextBox">
      <Setter Property="SnapsToDevicePixels" Value="True" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center" Focusable="False"
                            HorizontalScrollBarVisibility="Hidden"
                            VerticalScrollBarVisibility="Hidden" />
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Slim, quiet scrollbar: the stock one is a wide light-grey trough. -->
    <Style x:Key="SlimThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Tb" CornerRadius="3" Background="#33FFFFFF" />
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Tb" Property="Background" Value="#5CFFFFFF" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Margin="1,2,1,2">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource SlimThumb}" />
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Name="Root">
    <Grid Name="BallView" Width="64" Height="64" Background="Transparent"
          HorizontalAlignment="Center" VerticalAlignment="Center">
      <!-- The halo: 'a session is running' (the host's window.pulse). It is BRIGHTER than the
           old flat #26FFFFFF because it now breathes (its Opacity animates between 0.35 and
           1.0, see the turn signal at the top), and a breath on a 15%-white ring would not
           have been visible enough to read as motion. -->
      <Ellipse Name="BallGlow" Fill="#3DFFFFFF" Margin="-7">
        <!-- A blur turns the halo from a hard ring into light: the breath then reads as the
             ball glowing, not as a second outline around it. Cheap here: it is a 66px ellipse. -->
        <Ellipse.Effect>
          <BlurEffect Radius="7" RenderingBias="Quality" />
        </Ellipse.Effect>
      </Ellipse>
      <Ellipse Name="BallBody">
        <Ellipse.Fill>
          <RadialGradientBrush GradientOrigin="0.34,0.28" Center="0.34,0.28" RadiusX="0.9" RadiusY="0.9">
            <GradientStop Color="#B86E8BFF" Offset="0.0" />
            <GradientStop Color="#993550D8" Offset="1.0" />
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <!-- A soft highlight in the upper-left corner: the body reads as a glass sphere instead
           of a flat disc. Deliberately not animated: it is material, not state. -->
      <Ellipse Name="BallSheen" Margin="5" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush GradientOrigin="0.3,0.24" Center="0.3,0.24" RadiusX="0.85" RadiusY="0.85">
            <GradientStop Color="#38FFFFFF" Offset="0.0" />
            <GradientStop Color="#00FFFFFF" Offset="1.0" />
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <!-- The -1 Margin is load-bearing, not decoration. Apply-Shape sizes the ring to ballSize+2,
           i.e. 1px larger than this grid on every side, and WPF clips an element to its layout SLOT
           (not to the element's own size) while anchoring any overflow at the slot's top-left,
           which came out as a FLAT right and bottom edge on the ring. The negative margin inflates
           the slot to ballSize+2 so the element is exactly as big as its slot and nothing is cut. -->
      <Ellipse Name="BallRing" StrokeThickness="2.5" Stroke="#FF5B8DEF" Margin="-1" />
      <!-- The whale on the ball is the SAME original drawing as the app icon (assets/icon.svg),
           so the desktop ball and the icon read as one product: body / pectoral fin / dorsal fin
           as three filled paths, plus the blue eye and the mouth and belly strokes. A Viewbox
           wraps it so Apply-Shape can size the whole mark with one Width/Height pair. -->
      <Viewbox Name="BallMark" Stretch="Uniform" Width="36" Height="36"
               HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"
               RenderTransformOrigin="0.5,0.5">
        <Viewbox.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="MarkFlip" ScaleX="1" ScaleY="1" />
            <RotateTransform x:Name="MarkRotate" Angle="0" />
          </TransformGroup>
        </Viewbox.RenderTransform>
        <Canvas Width="110" Height="100">
          <!-- A soft shadow under the whale: it sits IN the ball instead of being a flat white
               sticker pasted on it. -->
          <Canvas Name="MarkShadow" IsHitTestVisible="False">
            <Canvas.RenderTransform>
              <TranslateTransform X="1.4" Y="1.9" />
            </Canvas.RenderTransform>
            <Path Data="M 4 50 C 4 33 16 21 34 19 C 47 17 57 21 63 28 C 69 34 73 38 77 36 C 85 27 94 17 101 10 C 97 26 89 38 81 45 C 90 47 99 51 105 57 C 97 62 86 60 79 55 C 73 65 61 70 48 70 C 32 70 16 64 8 58 C 5 55 4 52 4 50 Z">
              <Path.Fill>
                <SolidColorBrush Color="#57274296" />
              </Path.Fill>
              <Path.Effect>
                <BlurEffect Radius="3" RenderingBias="Quality" />
              </Path.Effect>
            </Path>
            <Path Data="M 36 63 C 32 75 38 85 50 89 C 48 81 46 73 44 67 Z">
              <Path.Fill>
                <SolidColorBrush Color="#57274296" />
              </Path.Fill>
              <Path.Effect>
                <BlurEffect Radius="3" RenderingBias="Quality" />
              </Path.Effect>
            </Path>
            <Path Data="M 58 23 C 56 12 63 6 71 8 C 67 14 65 20 63 27 Z">
              <Path.Fill>
                <SolidColorBrush Color="#57274296" />
              </Path.Fill>
              <Path.Effect>
                <BlurEffect Radius="3" RenderingBias="Quality" />
              </Path.Effect>
            </Path>
          </Canvas>
          <Path Fill="#F4FFFFFF" Data="M 4 50 C 4 33 16 21 34 19 C 47 17 57 21 63 28 C 69 34 73 38 77 36 C 85 27 94 17 101 10 C 97 26 89 38 81 45 C 90 47 99 51 105 57 C 97 62 86 60 79 55 C 73 65 61 70 48 70 C 32 70 16 64 8 58 C 5 55 4 52 4 50 Z" />
          <Path Fill="#F2FFFFFF" Data="M 36 63 C 32 75 38 85 50 89 C 48 81 46 73 44 67 Z" />
          <Path Fill="#F2FFFFFF" Data="M 58 23 C 56 12 63 6 71 8 C 67 14 65 20 63 27 Z" />
          <Ellipse Canvas.Left="19.6" Canvas.Top="41.6" Width="4.8" Height="4.8" Fill="#FF2F55B8" />
          <!-- No mouth on the ball: the smile read as a sudden dark cut across the clean white body. The eye + the soft belly line are enough to read as a whale. -->

          <Canvas Name="MarkBubbles" IsHitTestVisible="False">
            <Ellipse Canvas.Left="82" Canvas.Top="9" Width="6.6" Height="6.6" Fill="#D9FFFFFF" />
            <Ellipse Canvas.Left="92" Canvas.Top="2" Width="4.2" Height="4.2" Fill="#99FFFFFF" />
            <Ellipse Canvas.Left="99" Canvas.Top="-3" Width="2.6" Height="2.6" Fill="#66FFFFFF" />
          </Canvas>
        </Canvas>
      </Viewbox>
      <Border Name="BallBadge" Visibility="Collapsed" HorizontalAlignment="Right"
              VerticalAlignment="Top" CornerRadius="10" MinWidth="18" Height="18"
              Background="#FFE0A64B" Margin="0,-3,-3,0">
        <TextBlock Name="BallBadgeText" Text="1" FontSize="11" FontWeight="Bold"
                   Foreground="White" HorizontalAlignment="Center"
                   VerticalAlignment="Center" Margin="5,0,5,0" />
      </Border>
    </Grid>

    <Border Name="PanelView" Visibility="Collapsed" CornerRadius="20"
            BorderBrush="#2BFFFFFF" BorderThickness="1">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
          <GradientStop Color="#F7151922" Offset="0.0" />
          <GradientStop Color="#F70A0C11" Offset="1.0" />
        </LinearGradientBrush>
      </Border.Background>
      <Grid Margin="18,16,18,16">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
          <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto" />
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0" Width="16" Height="16" VerticalAlignment="Top"
                Margin="0,3,8,0">
            <Ellipse Name="StatusDotGlow" Fill="#FF5B8DEF" Opacity="0.3" />
            <Ellipse Name="StatusDot" Width="9" Height="9" Fill="#FF5B8DEF" />
          </Grid>
          <StackPanel Grid.Column="1">
            <TextBlock Name="StatusLabel" FontSize="14.5" FontWeight="SemiBold"
                       Foreground="#FFF1F4F9" TextTrimming="CharacterEllipsis" />
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
            <!-- "+": add an empty entry (a session to be created inside a workspace). It
                 opens the workspace picker below the button; with no workspace registered
                 the button is simply dead (see Update-CreateButton). -->
            <Button Name="CreateButton" Content="+" Height="24" MinWidth="26"
                    Style="{StaticResource IconButton}" Margin="0,0,3,0" />
            <Button Name="CollapseButton" Content="-" Width="26" Height="24"
                    Style="{StaticResource IconButton}" />
          </StackPanel>
        </Grid>

        <!-- The aggregate line ("output 12.3k tokens, 1 subagent running") is hidden on
             purpose: the panel is a list of things that need you, not a dashboard
             (asked 2026-11-20). The label still receives the host's text, it just never shows. -->
        <StackPanel Grid.Row="1" Margin="0,12,0,0" Visibility="Collapsed">
          <Border Height="1" Background="#14FFFFFF" Margin="0,0,0,10" />
          <TextBlock Name="MetaLabel" FontSize="11" Foreground="#FF8A93A6"
                     TextWrapping="Wrap" />
        </StackPanel>

        <ScrollViewer Name="BodyScroll" Grid.Row="2" Margin="0,12,0,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel>
            <!-- Shown only while the panel holds no entry at all (the host sends the line). -->
            <TextBlock Name="EmptyHint" FontSize="11" Foreground="#FF7C8598"
                       TextWrapping="Wrap" Margin="2,4,2,6" Visibility="Collapsed" />
            <!-- One child per session entry, built in New-EntryView. -->
            <StackPanel Name="BodyStack" />
          </StackPanel>
        </ScrollViewer>

        <TextBlock Name="FooterText" Grid.Row="3" FontSize="10.5" Foreground="#FF7C8598"
                   TextWrapping="Wrap" Margin="0,10,0,0" />
      </Grid>
    </Border>

    <Popup Name="CreatePopup" AllowsTransparency="True" StaysOpen="False" Placement="Bottom">
      <Border CornerRadius="12" Background="#F5171A21" BorderBrush="#3C4B63"
              BorderThickness="1" Padding="6" MinWidth="240" MaxWidth="400">
        <ScrollViewer MaxHeight="300" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled">
          <StackPanel Name="CreateList" />
        </ScrollViewer>
      </Border>
    </Popup>
  </Grid>
</Window>
'@

# Translate the XAML literals into the current palette (see the DSH theme block above). The
# divider and the scrollbar thumb share their literal with ordinary buttons (#14FFFFFF /
# #33FFFFFF) but want their own token, so they are pulled out before the general pass.
#
# ONE regex pass, not a chain of String.Replace: some replaced values ARE keys of the map
# (e.g. #2BFFFFFF -> #1FFFFFFF, and #1FFFFFFF is itself a key), and a chain would translate
# them a second time in whatever order the dictionary happens to enumerate.
$xaml = $xaml.Replace('Background="#14FFFFFF" Margin="0,0,0,8"', 'Background="__DSH_DIVIDER__" Margin="0,0,0,8"')
$xaml = $xaml.Replace('x:Name="Tb" CornerRadius="3" Background="#33FFFFFF"', 'x:Name="Tb" CornerRadius="3" Background="__DSH_THUMB__"')
$colorPattern = (@($script:ThemeMap.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
$xaml = [regex]::Replace($xaml, $colorPattern, { param($colorMatch) $script:ThemeMap[$colorMatch.Value] })
$xaml = $xaml.Replace('__DSH_DIVIDER__', $script:ThemeDivider)
$xaml = $xaml.Replace('__DSH_THUMB__', $script:ThemeThumb)
Write-BallLog ('theme: ' + $script:ThemeKey)

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$ballView = $window.FindName('BallView')
$ballBody = $window.FindName('BallBody')
$ballMark = $window.FindName('BallMark')
$ballRing = $window.FindName('BallRing')
$ballGlow = $window.FindName('BallGlow')
$ballBadge = $window.FindName('BallBadge')
$ballBadgeText = $window.FindName('BallBadgeText')
$panelView = $window.FindName('PanelView')
$statusDot = $window.FindName('StatusDot')
$statusDotGlow = $window.FindName('StatusDotGlow')
$statusLabel = $window.FindName('StatusLabel')
$createButton = $window.FindName('CreateButton')
$collapseButton = $window.FindName('CollapseButton')
$metaLabel = $window.FindName('MetaLabel')
$bodyScroll = $window.FindName('BodyScroll')
$bodyStack = $window.FindName('BodyStack')
$emptyHint = $window.FindName('EmptyHint')
$createPopup = $window.FindName('CreatePopup')
$createList = $window.FindName('CreateList')
$footerText = $window.FindName('FooterText')

# --- the panel's elevated look ---------------------------------------------------------------
# The rim belongs to the window (see $script:PanelPad), the panel sits inside it, and the shadow
# is created here (not in XAML) because its opacity is theme-dependent: a light surface needs a
# much softer shadow than a dark one to read as elevated at all.
$panelView.Margin = New-Object System.Windows.Thickness $script:PanelPad
$panelShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$panelShadow.BlurRadius = 32
$panelShadow.ShadowDepth = 6
$panelShadow.Direction = 270
$panelShadow.Color = [System.Windows.Media.Colors]::Black
if ($script:ThemeKey -eq 'light') { $panelShadow.Opacity = 0.18 } else { $panelShadow.Opacity = 0.5 }
$panelView.Effect = $panelShadow

$script:Hwnd = [System.IntPtr]::Zero
$script:Dragging = $false
$script:DragMoved = $false
$script:DragStart = $null
$script:UserMoved = $false
$script:Expanded = $false
$script:State = $null
$script:RawState = ''
$script:LastPingSeq = -1
# The receipt for a message this ball process sent (see Apply-SendResult). A
# receipt left over from before the ball restarted is ignored: only a send that
# is still waiting for its answer counts.
$script:LastSendSeq = -1
$script:AwaitingSend = $false
# Which entry sent the sentence that is still waiting for its receipt (see Apply-SendResult).
$script:PendingSendKey = ''
$script:CustomBoxes = @{}
$script:CustomHints = @{}
$script:Selections = @{}
$script:AnswerItems = @{}
# Set the first time the content measurement fails, so the reason is in ball.log
# exactly once instead of on every state (see Get-PanelHeight).
$script:PanelMeasureFailed = $false
# When the topmost watchdog may look at the z-order again (see Assert-BallTopmost).
# 0 = "at the next tick": the first check happens right after the ball is up.
$script:NextTopmostCheck = 0

# THE TURN SIGNAL (see the top of this file): what the last state document asked for, and what
# is actually attached to the two elements right now. The animations themselves are created
# ONCE, here: the host publishes a fresh document every 120ms while a model streams, and
# re-beginning an animation that often would restart it before it ever moved.

# This script's own accent blue: it is what every colour fallback in this file already uses
# (the XAML's initial ring and the ConvertTo-ColorBrush default), and it is the colour the host
# paints 'a session is still outputting' with (STATUS_STYLES.working in mirror.ts), which is why
# the older-host branch in Apply-State can use it without inventing a second palette entry.
$AccentBlue = '#FF5B8DEF'

$script:Working = $false
$script:Pulse = $false
$script:PulseOn = @{ ring = $false; glow = $false }

# One breath: From -> 1.0 -> back, forever, with a sine ease on each leg so the turn-around
# does not read as a hard switch. Opacity is the ONLY animated property -- colour, geometry and
# layout stay exactly where they are, so a breath can never move or resize the ball (the
# window's own size is measured from the ball, and an animated size would fight that).
function New-BreathAnimation {
  param([double]$From)
  $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
  $animation.From = $From
  $animation.To = 1.0
  $animation.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(1100))
  $animation.AutoReverse = $true
  $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $animation.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  return $animation
}

# The ring is a 3px coloured arc on the rim, so it can be dimmed further than the halo without
# disappearing: 0.55 .. 1.0 is a clearly visible heartbeat in the status colour itself.
$script:RingBreath = New-BreathAnimation 0.55
$script:GlowBreath = New-BreathAnimation 0.35

# Keyboard mode: which TextBox currently holds the keyboard (see KEYBOARD at the
# top of this file), and how to report a refusal back into that box.
$script:KeyboardActive = $false
$script:FocusBox = $null
$script:FocusHints = @{}
$script:ComposeReassertUntil = 0
$script:ComposeRetries = 0
$script:PrevForeground = [System.IntPtr]::Zero

# ---------------------------------------------------------------------------
# Entries (the whole body of the panel)
# ---------------------------------------------------------------------------
#
# One entry per session the host reports in `entries` - plus the LOCAL ones this ball
# invented with the "+" button (a session to be created inside a workspace; the host knows
# nothing about them until a sentence is sent). Everything a row needs to be painted lives
# in $script:EntryViews[key]; the ORDER rows are in is $script:EntryOrder (newest first, and
# it never moves an existing row - a new row is inserted above the others, so a state
# document that arrives while the user types can never shuffle the box being typed in).
#
# The host's own per-entry state rides in $script:EntryData[key] (the last document's entry),
# because the clock timer re-decides a row's lock on its own and would otherwise have to keep
# the whole document around.

$script:EntryViews = @{}
$script:EntryData = @{}
$script:EntryOrder = New-Object System.Collections.ArrayList
# Local create entries: key -> @{ key; target; title; detail } (see Add-LocalEntry).
$script:LocalEntries = @{}
$script:LocalSeq = 0
# A row's own LOCK, on top of the host's `lock` flag: kept for a few seconds after a send so
# the box goes grey the moment Send is pressed (the host's list takes over from there, and a
# failed receipt drops the hold at once). Keyed by entry key.
$script:EntryHold = @{}
# Text typed into a row's box, remembered across a rebuild of that row (a row is only rebuilt
# when its card set changes, but a draft must survive even that).
$script:EntryDrafts = @{}
# The draft of one card's own "say it in your own words" box, keyed '<cardId>|<questionId>'.
$script:CardDrafts = @{}
# What each row's cards looked like when they were last built (rebuild only on a real change).
$script:EntryCardSig = @{}
# The card ids built into a row (so removing the row can drop their registries).
$script:EntryCardIds = @{}
# The notice line under a row's box: @{ text; until } - the host's send receipt writes it.
$script:EntryNotices = @{}
# Which control owns the keyboard: 'entry:<key>' or 'card:<cardId>|<questionId>'. It is how a
# rebuild knows whether the box it is about to throw away is the one being typed in.
$script:BoxOwner = @{}

# --- panel filter / ordering / "completed but unread" --------------------------------------
# The panel shows only what needs a human eye: waiting for you (approval or question), an
# unacknowledged error, a session that finished a turn and whose result nobody has looked at
# yet, and one that is still running. A row that has simply gone idle -- or whose error was
# already acknowledged -- is hidden. The order is fixed: waiting > error > unread-done >
# running (and the "+ new session" rows this ball invented sit on top).
#
# The host's state document has no "unread" field, so the ball keeps that itself: a session
# that was active (running / waiting / error) in the previous document and is idle in this one
# is marked unread; any engagement (send / got-it / close) clears it again. The set is written
# to unread.json next to the state files so a ball restart does not lose a completion.
$script:EntryPrevState = @{}
$script:UnreadDone = @{}
$script:UnreadFile = Join-Path $BaseDir 'unread.json'
$script:UnreadDirty = $false

# Where the COLLAPSED ball sits, remembered across one expansion: expanding may have to
# shove the panel up, and collapsing must return the ball to its own corner instead of
# inheriting that shove. $null = 'not expanded right now'.

$script:CollapsedAnchor = $null

# ---------------------------------------------------------------------------
# The topmost BAND: why the ball can end up behind other windows
# ---------------------------------------------------------------------------

# A window that carries WS_EX_TOPMOST in its extended style is NOT necessarily in the
# topmost BAND: only SetWindowPos with HWND_TOPMOST sets the band (and the bit), and a
# window can sit behind a maximised non-topmost one with the bit still set -- invisible and
# unclickable while IsWindowVisible says otherwise. The bit is not a lever this script has
# (SetWindowLong cannot write it back; the system strips it), which is why the fix below is
# a WATCHDOG: it asks the z-order whether anything sits above the ball and repairs it.

function Set-BallTopmost {
  if ($script:Hwnd -eq [System.IntPtr]::Zero) { return }
  [void][DshBall.Native]::PutOnTopmostBand($script:Hwnd)
}

# Is a VISIBLE non-topmost window above ours? Every topmost window precedes every
# non-topmost one, so walking UP to the first visible window answers exactly that, and in
# the healthy case the walk stops after a step or two.
#
# Invisible windows (the IME and TSF helpers of this very process, the WPF parking window)
# and our own VISIBLE windows (the target dropdown is above the ball on purpose) are
# skipped: taking one of them for a cover would re-assert on every tick.

function Test-BallCovered {
  if ($script:Hwnd -eq [System.IntPtr]::Zero) { return $false }
  $handle = [DshBall.Native]::GetWindow($script:Hwnd, $GW_HWNDPREV)
  $steps = 0
  while ($handle -ne [System.IntPtr]::Zero -and $steps -lt 512) {
    $steps++
    if ([DshBall.Native]::IsWindowVisible($handle)) {
      if ([DshBall.Native]::WindowProcessId($handle) -ne $PID) {
        $style = [DshBall.Native]::GetWindowLong($handle, $GWL_EXSTYLE)
        if (($style -band $WS_EX_TOPMOST) -eq 0) { return $true }
      }
    }
    $handle = [DshBall.Native]::GetWindow($handle, $GW_HWNDPREV)
  }
  return $false
}

# The watchdog body, called from the clock timer and after every ex-style write: the moment
# something has left the ball out of the topmost band, put it back. Deliberately conditional
# -- an unconditional re-assert on a timer would also drag the ball above OTHER topmost
# windows on every tick, which is not this plugin's call to make.

function Assert-BallTopmost {
  if ($script:Hwnd -eq [System.IntPtr]::Zero) { return }
  if (-not (Test-BallCovered)) { return }
  Set-BallTopmost
  Write-BallLog 'topmost band lost (a visible window was above the ball); re-asserted'
}

function Update-WindowStyles {
  if ($script:Hwnd -eq [System.IntPtr]::Zero) { return }
  $style = [DshBall.Native]::GetWindowLong($script:Hwnd, $GWL_EXSTYLE)
  $style = $style -bor $WS_EX_TOOLWINDOW
  # The one exception to "never takes keyboard focus": while the user is typing
  # into one of our boxes, the window must be activatable or the keys would go
  # nowhere.
  if ($script:KeyboardActive) {
    $style = $style -band (-bnot $WS_EX_NOACTIVATE)
  } else {
    $style = $style -bor $WS_EX_NOACTIVATE
  }
  [void][DshBall.Native]::SetWindowLong($script:Hwnd, $GWL_EXSTYLE, $style)
  # ...and the band right after it: bit and band are both SetWindowPos's business, and these
  # style writes are the only ones this script makes, so this is the one unconditional place
  # that has to leave the ball above everything (the timer's Assert-BallTopmost asks first).

  Set-BallTopmost
}

# ---------------------------------------------------------------------------
# Keyboard mode: the only place where this window may hold the keyboard
# ---------------------------------------------------------------------------

# A refusal or a "not yet" is written into the box's own hint line, right under
# it: the reason has to be where the user is looking, and the footer belongs to
# the host's own notices.
function Set-FocusHint {
  param($Box, [string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $hint = $script:FocusHints[$Box]
  if ($null -eq $hint) { return }
  $hint.Text = $Text
  $hint.Visibility = 'Visible'
}

function Clear-FocusHint {
  param($Box)
  $hint = $script:FocusHints[$Box]
  if ($null -eq $hint) { return }
  $hint.Text = ''
  $hint.Visibility = 'Collapsed'
}

# The one-line note under one question of one pending card ('answer every question first'):
# the same idea as Set-FocusHint, but keyed by (card id, question id) because a card can hold
# several questions. Both the text and the decision to show it come from the host.

function Set-CardHint {
  param([string]$PendingId, [string]$ItemId, [string]$Text)
  $hint = $script:CustomHints[$PendingId + '|' + $ItemId]
  if ($null -eq $hint) { return }
  if ([string]::IsNullOrWhiteSpace($Text)) {
    $hint.Text = ''
    $hint.Visibility = 'Collapsed'
    return
  }
  $hint.Text = $Text
  $hint.Visibility = 'Visible'
}

function Test-FocusedBox {
  param($Box)
  if (-not $script:KeyboardActive) { return $false }
  return [object]::ReferenceEquals($script:FocusBox, $Box)
}

# ONE place decides whether ONE row's box is locked, and why. Called from every state
# application (the host's own flag on that entry, which already folds in
# `lockComposeWhileBusy`) and from the clock (the local hold after a send, which runs out on
# its own).
#
# The lock is the visible answer to 'did my sentence go out?': the box of the row you just
# sent from goes grey where your eyes already are, and the host's own flag keeps it grey
# while that session is still outputting.
#
# A row's lock has NOTHING to do with any other row: the box, the button and the watermark
# all belong to one entry (see Update-EntryCompose).

function Update-EntryCompose {
  param([string]$Key, $Entry)

  $view = $script:EntryViews[$Key]
  if ($null -eq $view) { return }
  if (-not $view.Input) { return }
  if ($null -eq $Entry) { return }

  $busy = [bool](Get-ChildValue $Entry 'lock' $false)
  $holdUntil = 0
  if ($script:EntryHold.ContainsKey($Key)) { $holdUntil = [double]$script:EntryHold[$Key] }
  $holding = ($holdUntil -gt 0) -and ((Get-NowMs) -lt $holdUntil)
  $locked = $busy -or $holding
  $reason = ''
  if ($busy) { $reason = 'busy' } elseif ($holding) { $reason = 'sending' }

  $view.LockReason = $reason
  $wasLocked = [bool]$view.Locked
  $view.Locked = $locked
  if ($locked -and -not $wasLocked) {
    Write-BallDebug ('entry locked (' + $reason + ') key=' + $Key)
  }
  # A disabled box cannot hold the keyboard, so the lock hands it back -- only when THIS
  # row's box is the one holding it (a card's own answer box is none of this row's business).
  if ($locked -and (Test-FocusedBox $view.Box)) { Exit-KeyboardMode }

  $sendLabel = Get-Label 'sendMessage' ''
  $hint = Get-Label 'composeHint' ''
  $empty = ($view.Box.Text.Length -eq 0)

  if ($locked) {
    # Locked: box and button go visibly dead. The colours are set HERE because WPF's disabled
    # trigger only greys the TEXT, which on a near-black box is too subtle to read as 'you
    # cannot type here'. A disabled TextBox keeps what was typed into it.
    $view.Box.IsEnabled = $false
    $view.Send.IsEnabled = $false
    $view.Box.Background = ConvertTo-ColorBrush '#FF0E1116'
    $view.Box.Foreground = ConvertTo-ColorBrush '#FF7C8598'
    $view.Box.BorderBrush = ConvertTo-ColorBrush '#FF1F2A36'
    $view.Send.Background = ConvertTo-ColorBrush '#FF10141A'
    $view.Send.Foreground = ConvertTo-ColorBrush '#FF6E7787'
    $view.Send.BorderBrush = ConvertTo-ColorBrush '#FF1F2A36'
    # ...and dim it on top of that: WPF's own disabled trigger paints the button with the
    # system's light 'off' brush, whose template beats the local colours above. Opacity is the
    # one property no trigger touches.
    $view.Send.Opacity = 0.45
    $waitLabel = Get-Label 'sendWaiting' ''
    if (-not [string]::IsNullOrWhiteSpace($waitLabel)) { $sendLabel = $waitLabel }

    # The watermark doubles as the reason. It is only ever shown on an empty box (a watermark
    # painted over a draft is unreadable) -- which is exactly the state the box is in right
    # after a send, the moment this feedback is for.
    $lockHint = ''
    if ($reason -eq 'busy') {
      $lockHint = Get-Label 'composeOutputting' ''
    } elseif ($reason -eq 'sending') {
      $lockHint = Get-Label 'composeSending' ''
    }
    $view.Watermark.Text = $lockHint
    $view.Watermark.Foreground = ConvertTo-ColorBrush '#FFD9A54B'
    $view.Watermark.Visibility = Get-Visibility ($empty -and -not [string]::IsNullOrWhiteSpace($lockHint))
  } else {
    $view.Box.IsEnabled = $true
    $view.Send.IsEnabled = $true
    $view.Box.Background = ConvertTo-ColorBrush '#FF12151B'
    $view.Box.Foreground = ConvertTo-ColorBrush '#FFE9EEF7'
    $view.Box.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
    $view.Send.Background = ConvertTo-ColorBrush '#1AFFFFFF'
    $view.Send.Foreground = ConvertTo-ColorBrush '#FFD7DEEA'
    $view.Send.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
    $view.Send.Opacity = 1
    $view.Watermark.Text = $hint
    $view.Watermark.Foreground = ConvertTo-ColorBrush '#FF6E7787'
    # The watermark sits ON TOP of the box (that is how it acts as one), so it must step
    # aside as soon as there is a draft or a caret in there.
    $view.Watermark.Visibility = Get-Visibility ($empty -and -not (Test-FocusedBox $view.Box))
    # A row with no target at all (a card-only entry never gets a box; a local "new session"
    # row always has its workspace): the box stays typeable and only Send goes dead -- hitting
    # Enter anyway gets the host's refusal, which lands in this row's own notice line.
    if ([string]::IsNullOrWhiteSpace([string]$view.Target)) {
      $view.Send.IsEnabled = $false
      $view.Send.Opacity = 0.45
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($sendLabel)) { $view.Send.Content = $sendLabel }
}

# Every row's box, on the clock: the local hold after a send runs out on its own, and a
# notice line expires on its own. Both are things no state document will announce.
function Update-AllEntryCompose {
  foreach ($key in @($script:EntryOrder)) {
    $entry = $null
    if ($script:EntryData.ContainsKey($key)) { $entry = $script:EntryData[$key] }
    Update-EntryCompose $key $entry
  }
}

# The notice line under a row's box: the outcome of a send from THAT row. The host's receipt
# carries the text, and it is written where the user is looking (right under the box they
# just typed in) instead of only in the panel-wide footer.
#
# A notice remembers when it goes stale, because nothing will tell this script that the user
# has read it.
function Set-EntryNotice {
  param([string]$Key, [string]$Text)
  if ([string]::IsNullOrWhiteSpace($Key)) { return }
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $script:EntryNotices[$Key] = @{ text = $Text; until = (Get-NowMs) + 15000 }
  Apply-EntryNotice $Key
}

function Apply-EntryNotice {
  param([string]$Key)
  $view = $script:EntryViews[$Key]
  if ($null -eq $view -or $null -eq $view.Notice) { return }
  $notice = $script:EntryNotices[$Key]
  if ($null -eq $notice) { return }
  if ((Get-NowMs) -ge [double]$notice['until']) {
    $script:EntryNotices.Remove($Key)
    if ($view.Notice.Text -eq [string]$notice['text']) {
      $view.Notice.Text = ''
      $view.Notice.Visibility = 'Collapsed'
    }
    return
  }
  $view.Notice.Text = [string]$notice['text']
  $view.Notice.Visibility = 'Visible'
}

# Bringing this window to the foreground is the one thing Windows fights: a process that is
# not already in front may not raise itself, and a click on a WS_EX_NOACTIVATE window does
# not make it the foreground window. Try the plain call, check whether it worked, and only
# then fall back to the classic workaround (share the foreground thread's input queue).

function Invoke-TakeForeground {
  param([System.IntPtr]$Target)

  [void]$window.Activate()
  [void][DshBall.Native]::SetForegroundWindow($Target)
  if ([DshBall.Native]::GetForegroundWindow() -eq $Target) { return $true }

  $foreground = [DshBall.Native]::GetForegroundWindow()
  if ($foreground -eq [System.IntPtr]::Zero -or $foreground -eq $Target) { return $false }
  $current = [DshBall.Native]::GetCurrentThreadId()
  $other = [DshBall.Native]::GetWindowThreadProcessId($foreground, [System.IntPtr]::Zero)
  if ($other -eq 0 -or $other -eq $current) { return $false }

  $attached = $false
  try {
    $attached = [DshBall.Native]::AttachThreadInput($current, $other, $true)
    Write-BallDebug ('focus attachThreadInput=' + [string]$attached)
    [void][DshBall.Native]::SetForegroundWindow($Target)
    [void][DshBall.Native]::SetFocus($Target)
  } finally {
    if ($attached) { [void][DshBall.Native]::AttachThreadInput($current, $other, $false) }
  }
  return ([DshBall.Native]::GetForegroundWindow() -eq $Target)
}

function Invoke-FocusBox {
  param($Box)
  if ($null -eq $Box) { return }
  [void]$Box.Focus()
  [System.Windows.Input.Keyboard]::Focus($Box)
  $Box.CaretIndex = $Box.Text.Length
}

function Enter-KeyboardMode {
  param($Box)
  if ($null -eq $Box) { return }
  if (Test-FocusedBox $Box) { return }
  if ($script:Hwnd -eq [System.IntPtr]::Zero) { return }
  try {
    if (-not $script:KeyboardActive) {
      $foreground = [DshBall.Native]::GetForegroundWindow()
      $script:PrevForeground = [System.IntPtr]::Zero
      if ($foreground -ne [System.IntPtr]::Zero -and $foreground -ne $script:Hwnd) {
        $script:PrevForeground = $foreground
      }
    }
    $script:KeyboardActive = $true
    $script:FocusBox = $Box
    Update-WindowStyles
    $took = Invoke-TakeForeground $script:Hwnd
    Write-BallDebug ('focus foreground=' + [string]([DshBall.Native]::GetForegroundWindow()) +
      ' ball=' + [string]$script:Hwnd + ' took=' + [string]$took)
    if (-not $took) {
      # Never pretend to accept typing we cannot receive.
      Set-FocusHint $Box (Get-Label 'composeNoFocus' '')
      Exit-KeyboardMode
      return
    }
    Clear-FocusHint $Box
    Invoke-FocusBox $Box
    # Windows is allowed to hand the foreground back to the window the click came from, just
    # after the click, so a deactivation is only taken as the user having moved on for real
    # after a short grace window.

    $script:ComposeReassertUntil = (Get-NowMs) + 500
    $script:ComposeRetries = 0
    Update-AllEntryCompose
    Write-BallDebug 'keyboard mode on'
  } catch {
    Write-BallLog ('focus failed: ' + $_.Exception.Message)
    $script:KeyboardActive = $false
    $script:FocusBox = $null
    Update-WindowStyles
  }
}

function Exit-KeyboardMode {
  param([bool]$RestoreForeground = $true)
  if (-not $script:KeyboardActive) { return }
  $script:KeyboardActive = $false
  $script:FocusBox = $null
  # Back to "never takes keyboard focus" immediately, before anything else.
  Update-WindowStyles
  Update-AllEntryCompose
  $previous = $script:PrevForeground
  $script:PrevForeground = [System.IntPtr]::Zero
  if ($RestoreForeground -and $previous -ne [System.IntPtr]::Zero) {
    # Hand the keyboard back to whoever had it. When this is the model's turn to
    # type, this is what makes its keystrokes land where it aimed them.
    try { [void][DshBall.Native]::SetForegroundWindow($previous) } catch { }
  }
  Write-BallDebug 'keyboard mode off'
}

# Take the foreground back after our own picker closed: the popup is a window
# of its own, and activating it can cost the ball the foreground it needs to keep
# receiving keys into the box the user was typing in.
function Invoke-ReassertFocus {
  if (-not $script:KeyboardActive) { return }
  $box = $script:FocusBox
  if ($null -eq $box) { return }
  if (Invoke-TakeForeground $script:Hwnd) {
    Invoke-FocusBox $box
    Write-BallDebug 'focus re-taken after the picker closed'
  }
}

# Keyboard mode is meant to survive a foreground Windows takes back (it can decide the
# foreground for a click just after the click is delivered). Called from the timer: re-take
# the foreground within the grace window, otherwise give up honestly.

function Assert-KeyboardFocus {
  if (-not $script:KeyboardActive) { return }
  # The workspace picker is ours: while it is open, the popup may hold the foreground and
  # that is not the user moving on.
  if ($createPopup.IsOpen) { return }
  if ([DshBall.Native]::GetForegroundWindow() -eq $script:Hwnd) { return }

  $now = Get-NowMs
  if ($now -ge $script:ComposeReassertUntil) {
    # Past the grace window and no longer in front: the user moved on by
    # themselves (and gave the keyboard away on purpose), not Windows undoing our
    # activation. Just leave keyboard mode, silently.
    Exit-KeyboardMode -RestoreForeground $false
    return
  }

  if ($script:ComposeRetries -ge 2) {
    # We did try to take it back and could not: never pretend to accept typing.
    Set-FocusHint $script:FocusBox (Get-Label 'composeNoFocus' '')
    Exit-KeyboardMode
    return
  }

  $script:ComposeRetries++
  if (Invoke-TakeForeground $script:Hwnd) {
    Write-BallDebug 'focus re-taken'
    Invoke-FocusBox $script:FocusBox
    return
  }
  Write-BallDebug 'foreground not available yet; will try again'
}

# Send what is typed in ONE row's box to that row's own target. Which row is the whole
# point: the box and its target are the same entry, so there is no way to pick the wrong
# session and nothing to remember between sentences.

function Send-EntryText {
  param([string]$Key)
  try {
    $view = $script:EntryViews[$Key]
    if ($null -eq $view) { return }
    if (-not $view.Input) { return }
    Clear-EntryUnread $Key
    if ($view.Locked) {
      # A disabled box and a disabled button cannot produce this, so reaching it means a stale
      # path -- and a silent send into a row the user was just told is waiting is the one thing
      # this lock must never do.
      Write-BallDebug ('entry send ignored: the row is locked (key=' + $Key + ')')
      return
    }
    $text = [string]$view.Box.Text
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    # The target rides on the row itself: a session id, or 'new:<workspaceId>' for a row the
    # "+" button added (a session to be created inside that workspace). An empty target is the
    # host's business to refuse (with a failed receipt, which unlocks this row again) rather
    # than for the ball to guess a session.
    $target = [string]$view.Target
    if ([string]::IsNullOrWhiteSpace($target)) {
      Set-EntryNotice $Key (Get-Label 'composeNoTarget' '')
      return
    }
    # The host submits this through the very entry the web composer uses, so the message is an
    # ordinary user message of the session it goes to. `key` is what the host echoes back in the
    # receipt: for a local "new session" row it is the only name this row has.
    Send-Action ([ordered]@{ kind = 'prompt'; text = $text; target = $target; key = $Key })

    # Wait for this message's receipt (see Apply-SendResult). Nothing else happens on a send --
    # the panel stays open, so the next sentence can be typed without reopening anything.
    $script:AwaitingSend = $true
    $script:PendingSendKey = $Key
    # ...and LOCK THE ROW NOW: the box going grey with the 'sent, waiting for the session to
    # take over' watermark is the receipt the user actually sees, and it must not wait for a
    # round trip. From here the host's own per-entry flag takes over.
    $script:EntryHold[$Key] = (Get-NowMs) + 5000
    $view.Box.Clear()
    $script:EntryDrafts.Remove($Key)
    Update-EntryCompose $Key $script:EntryData[$Key]
    Write-BallDebug ('entry sent key=' + $Key + ' target=' + $target)
  } catch {
    Write-BallLog ('entry send failed: ' + $_.Exception.Message)
  }
}

# ---------------------------------------------------------------------------
# The "+" button: pick a workspace, get an empty entry (a session to be created)
# ---------------------------------------------------------------------------
#
# The rows come from the host's `create` section: ONE ROW PER WORKSPACE and nothing else.
# That is not a formality -- `sessionController.create()` only registers a new session in a
# workspace when it is given a `workspaceId`, and a bare `cwd` leaves it in the sidebar's
# ungrouped list. So the workspace really is the thing being chosen here.
#
# The entry this adds is LOCAL (the host is not told until a sentence is sent): it is just an
# empty box with a title. The moment a send from it succeeds, the host's receipt names the
# real session, and this row hands over to it (its own entry appears from the host).

function Add-LocalEntry {
  param([string]$Target, [string]$Title, [string]$Detail)

  if ([string]::IsNullOrWhiteSpace($Target)) { return }
  if ([string]::IsNullOrWhiteSpace($Title)) { $Title = [string](Get-Label 'entryNew' 'new') }
  $script:LocalSeq++
  $key = 'local-new-' + [string]$script:LocalSeq
  $script:LocalEntries[$key] = @{ key = $key; target = $Target; title = $Title; detail = $Detail }
  # Newest first, and inserting at the top moves nothing else: a document arriving while the
  # user types can never rebuild the row being typed in.
  [void]$script:EntryOrder.Insert(0, $key)
  Write-BallDebug ('local entry added ' + $key + ' target=' + $Target)
  Sync-Entries $script:State
  # An empty box that just appeared is meant to be typed in: take the keyboard right away.
  $view = $script:EntryViews[$key]
  if ($null -ne $view) { Enter-KeyboardMode $view.Box }
}

# Drop a local entry (it handed over to a real session, or the user removed it).
function Remove-LocalEntry {
  param([string]$Key)
  if (-not $script:LocalEntries.ContainsKey($Key)) { return $false }
  $script:LocalEntries.Remove($Key)
  return $true
}

function Get-CreateItems {
  $items = New-Object System.Collections.ArrayList
  foreach ($entry in @(Get-ChildValue $script:State 'create' @())) {
    if ($null -eq $entry) { continue }
    $id = [string](Get-ChildValue $entry 'id' '')
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    [void]$items.Add(@{
      id = $id
      label = [string](Get-ChildValue $entry 'label' $id)
      detail = [string](Get-ChildValue $entry 'detail' '')
      title = [string](Get-ChildValue $entry 'entry' '')
    })
  }
  return @($items.ToArray())
}

# One picker row: the host's label (already reads "+ new session: <workspace>") and the
# directory under it. WPF Buttons do NOT trim string content, so the headline is a TextBlock
# with CharacterEllipsis.
#
# The host also sends the TITLE the empty entry will carry ('entry': a ready-made line such as
# "new session / work"): every display string on this ball is authored by the host, and this
# file is ASCII-only.

function New-CreateItemButton {
  param([string]$Id, [string]$Label, [string]$Detail, [string]$Title)

  $button = New-Object System.Windows.Controls.Button
  $button.FontSize = 11.5
  $button.Padding = New-Object System.Windows.Thickness 7, 4, 7, 4
  $button.Margin = New-Object System.Windows.Thickness 0, 1, 0, 1
  $button.BorderThickness = New-Object System.Windows.Thickness 0
  $button.HorizontalContentAlignment = 'Left'
  $button.Cursor = 'Hand'
  $button.Style = $window.FindResource('IconButton')
  $button.Background = ConvertTo-ColorBrush '#00000000'
  $button.Foreground = ConvertTo-ColorBrush '#FFC7CFDD'
  $button.Tag = @{ id = $Id; detail = $Detail; title = $Title }

  $stack = New-Object System.Windows.Controls.StackPanel
  $head = New-Object System.Windows.Controls.TextBlock
  $head.Text = $Label
  $head.TextTrimming = 'CharacterEllipsis'
  [void]$stack.Children.Add($head)
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = '     ' + $Detail
    $sub.FontSize = 9.5
    $sub.TextTrimming = 'CharacterEllipsis'
    $sub.Foreground = ConvertTo-ColorBrush '#FF8A93A6'
    [void]$stack.Children.Add($sub)
  }
  $button.Content = $stack

  # Per-button data rides on Tag, NOT on a closure (see the note in New-OptionButton for why).
  $button.Add_Click({
    param($sender, $e)
    try {
      $info = $sender.Tag
      Add-LocalEntry ([string]$info['id']) ([string]$info['title']) ([string]$info['detail'])
      Close-CreatePopup
    } catch {
      Write-BallLog ('create row failed: ' + $_.Exception.Message)
    }
  })
  return $button
}

function Close-CreatePopup {
  if (-not $createPopup.IsOpen) { return }
  $createPopup.IsOpen = $false
  Write-BallDebug 'workspace picker closed'
}

function Toggle-CreatePopup {
  if ($createPopup.IsOpen) {
    Close-CreatePopup
    return
  }
  if (-not $createButton.IsEnabled) { return }
  $createList.Children.Clear()
  foreach ($item in (Get-CreateItems)) {
    [void]$createList.Children.Add((New-CreateItemButton ([string]$item['id']) ([string]$item['label']) ([string]$item['detail']) ([string]$item['title'])))
  }
  if ($createList.Children.Count -eq 0) {
    # An EMPTY list is a real answer, not a hole to fill: with no workspace registered there
    # is nowhere a new session could be registered, so the button must not open an empty menu.
    Write-BallDebug 'workspace picker empty; not opening'
    return
  }
  $createPopup.PlacementTarget = $createButton
  $createPopup.IsOpen = $true
  Write-BallDebug ('workspace picker opened (' + [string]$createList.Children.Count + ' rows)')
}

# The "+" button is dead (and visibly so) while the host lists no workspace.
function Update-CreateButton {
  $label = [string](Get-Label 'createOpen' '+')
  $createButton.Content = $label
  $rows = (Get-CreateItems).Count
  $createButton.IsEnabled = ($rows -gt 0)
  $createButton.Opacity = 1
  if ($rows -le 0) { $createButton.Opacity = 0.45 }
}

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

function Get-BallSize {
  $value = Get-ChildValue (Get-ChildValue $script:State 'metrics' @{}) 'ballSize' 64
  $size = [double]$value
  if ($size -lt 16) { $size = 16 }
  if ($size -gt 160) { $size = 160 }
  return $size
}

# The window of the COLLAPSED ball: the ball plus the room its halo needs on every side.
# The halo sticks out 7px, and the window keeps 2px of slack on top of that -- at exactly
# 14 the halo's circle touched the window rim and the outermost pixel was shaved off the
# right and the bottom, which made the ball look cut off along those edges.
#
# Used BOTH for the collapsed window's size and for 'where would the collapsed ball be'
# while the panel is expanded; the two have to agree or the ball jumps on the next collapse.

function Get-BallWindowSize {
  return (Get-BallSize) + 18 + (2 * $script:PanelPad)
}

# The transparent rim the window keeps on every side, so the panel's soft drop shadow has
# something to fall on (a WPF effect is clipped to the window, so without this rim the shadow
# would simply not exist). The ball gets the same rim for symmetry and so one number decides
# every window size; those pixels are fully transparent (alpha 0) and therefore click-through.
$script:PanelPad = 16

# The shortest a panel may ever be. The header, the meta line, the body and the footer are
# always there, so anything below this would clip the first row's own box.
$PanelMinHeight = 120

function Get-PanelMetrics {
  # The panel's WIDTH is exactly what the host asks for; its HEIGHT is a CEILING, not a size
  # (see Get-PanelHeight). Fallbacks and floors follow the host's own defaults and clamps, so
  # a script older than the host never disagrees with it about what a panel is.

  $metrics = Get-ChildValue $script:State 'metrics' @{}
  $width = [double](Get-ChildValue $metrics 'panelWidth' 360)
  $ceiling = [double](Get-ChildValue $metrics 'panelHeight' 320)
  $maxWidth = [System.Windows.SystemParameters]::VirtualScreenWidth - 24
  $maxHeight = [System.Windows.SystemParameters]::VirtualScreenHeight - 24
  if ($width -gt $maxWidth) { $width = $maxWidth }
  if ($ceiling -gt $maxHeight) { $ceiling = $maxHeight }
  if ($width -lt 280) { $width = 280 }
  if ($ceiling -lt $PanelMinHeight) { $ceiling = $PanelMinHeight }
  return @{ Width = $width; MaxHeight = $ceiling }
}

# Marks a whole subtree as needing a fresh measurement: WPF answers a Measure whose
# constraint it has already seen from a per-element cache, and invalidating an element
# walks UP to its ancestors, never down to the descendants that changed.
#
# The `-is [UIElement]` test is required, not decoration: the visual tree holds elements
# that are not UIElements at all (a rendered TextBox carries TextBoxLineDrawingVisual for
# the caret and the selection), and those have no InvalidateMeasure.

function Reset-Measure {
  param($Element)
  if ($Element -is [System.Windows.UIElement]) {
    $Element.InvalidateMeasure()
  }
  $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
  for ($index = 0; $index -lt $count; $index++) {
    Reset-Measure ([System.Windows.Media.VisualTreeHelper]::GetChild($Element, $index))
  }
}

# The panel is exactly as tall as what it holds, up to the host's panelHeight.
#
# Measured, not fixed: the panel is measured with an UNCONSTRAINED height and the answer
# is clamped between the floor and the host's ceiling, so a long card list still scrolls.
# Two WPF facts make that non-obvious: a star row under an unconstrained height is not
# asked for its height at all (it contributes 0, so the body row is Auto while measuring
# and is put back right afterwards), and a Measure whose constraint WPF has already seen is
# answered from its cache (hence Reset-Measure).
#
# Called whenever the content can change size: expanding, a new or answered card, a new
# state document, the countdown. A failure here falls back to the host's ceiling and is
# reported once, and the body row goes back in a finally.
#
# It MEASURES only: Apply-PanelHeight (an already open panel) or Apply-Shape (the panel is
# opening right now) puts the number on the window.

function Get-PanelHeight {
  param($Panel)

  $height = $Panel.MaxHeight

  try {
    $grid = $panelView.Child
    $bodyRow = $grid.RowDefinitions[[int]$bodyScroll.GetValue([System.Windows.Controls.Grid]::RowProperty)]
    $bodyRowHeight = $bodyRow.Height
    $bodyRow.Height = [System.Windows.GridLength]::Auto
    $keepAuto = $false
    try {
      Reset-Measure $panelView
      $limit = [double]::PositiveInfinity
      $panelView.Measure((New-Object System.Windows.Size $Panel.Width, $limit))
      $height = [math]::Ceiling([double]$panelView.DesiredSize.Height)
      # THE BODY ROW STAYS AUTO WHEN THE CONTENT FITS. The row is normally Star (it must scroll
      # once the entries are taller than the ceiling), but a Star row also swallows whatever
      # height the window has left over, which shows up as an empty band under the last entry.
      # Keeping Auto makes the panel exactly as tall as its content; past the ceiling the row
      # goes back to Star and the ScrollViewer scrolls.
      if ($height -lt $Panel.MaxHeight) { $keepAuto = $true }

    } finally {
      if ($keepAuto) {
        $bodyRow.Height = [System.Windows.GridLength]::Auto
      } else {
        $bodyRow.Height = $bodyRowHeight
      }
    }
  } catch {
    if (-not $script:PanelMeasureFailed) {
      $script:PanelMeasureFailed = $true
      Write-BallLog ('panel measurement failed, keeping the full-height panel: ' + $_.Exception.Message)
    }
  }

  if ($height -lt $PanelMinHeight) { $height = $PanelMinHeight }
  if ($height -gt $Panel.MaxHeight) { $height = $Panel.MaxHeight }
  return $height
}

# Put the measured height on the window -- the one and only place that resizes an
# ALREADY-OPEN panel. The window is either at the old height or at the new one, never at an
# intermediate size.
#
# The width goes on the panel (not on the window) because the measurement has to be taken
# for the width the panel really has.

function Apply-PanelHeight {
  if (-not $script:Expanded) { return }

  $panel = Get-PanelMetrics
  $panelView.Width = $panel.Width
  # THE WIDTH IS NOT FIXED WHILE THE PANEL IS OPEN. The width of the window is only ever put
  # on by Apply-Shape, i.e. at the instant the panel opens -- but the document can carry a
  # DIFFERENT panelWidth later (measured: after a host/plugin remount the first documents can
  # still carry the plugin defaults 360 while the Profile's 480 arrives moments later; the
  # same happens if somebody edits panelWidth in the Profile and reloads). The panel view is
  # then 480 wide inside a 360 window: every right-hand control (the header's +/-, an entry's
  # "got it"/"x", the send button) sits outside the window and is simply not there.
  # Re-shaping is the only way to widen a window that is already open: it re-measures and
  # re-anchors exactly like the moment the panel opened (the right edge stays put).
  if ([math]::Round($window.Width) -ne [math]::Round($panel.Width + (2 * $script:PanelPad))) {
    Write-BallLog ('panel width under the open panel: ' + [math]::Round($window.Width) + ' -> ' +
      [math]::Round($panel.Width) + ', re-shaping')
    Apply-Shape $true
    return
  }
  $height = Get-PanelHeight $panel
  $height = $height + (2 * $script:PanelPad)
  if ($height -eq $window.Height) { return }

  $window.Height = $height
  Write-BallDebug ('panel height -> ' + [math]::Round($height) + ' (window now ' +
    [math]::Round($window.Width) + 'x' + [math]::Round($window.Height) + ')')
  # A panel that just grew downwards must not hang off the bottom of the screen.
  Move-IntoVirtualScreen
}

# The collapsed ball has the same "the window was sized from metrics that later changed"
# problem, one level smaller: after a remount the plugin defaults (ballSize 64) can be
# published before the Profile's own 48 arrives, and a ball shaped at 64 would stay 64 until
# it is expanded and collapsed again (the ball's own size is only put on by Apply-Shape).
# This puts the CURRENT size back on it -- once, because the window then matches.
function Sync-BallSize {
  if ($script:Expanded) { return }
  $want = [math]::Round((Get-BallWindowSize))
  $haveWidth = [math]::Round($window.Width)
  $haveHeight = [math]::Round($window.Height)
  if ($haveWidth -eq $want -and $haveHeight -eq $want) { return }
  Write-BallLog ('ball size under the collapsed ball: ' + $haveWidth + 'x' + $haveHeight +
    ' -> ' + $want + ', re-shaping')
  Apply-Shape $false
}

function Move-IntoVirtualScreen {
  $left = [System.Windows.SystemParameters]::VirtualScreenLeft
  $top = [System.Windows.SystemParameters]::VirtualScreenTop
  $width = [System.Windows.SystemParameters]::VirtualScreenWidth
  $height = [System.Windows.SystemParameters]::VirtualScreenHeight

  # Keep the whole window inside the virtual desktop (the union of every
  # monitor). If the window is larger than the screen -- possible when the
  # panel height was clamped by the system -- pin it to the top-left corner so
  # its header stays reachable.
  $minX = $left
  $minY = $top
  $maxX = $left + $width - $window.Width
  $maxY = $top + $height - $window.Height
  if ($maxX -lt $minX) { $maxX = $minX }
  if ($maxY -lt $minY) { $maxY = $minY }

  $x = $window.Left
  $y = $window.Top
  if ($x -lt $minX) { $x = $minX }
  if ($y -lt $minY) { $y = $minY }
  if ($x -gt $maxX) { $x = $maxX }
  if ($y -gt $maxY) { $y = $maxY }
  $window.Left = $x
  $window.Top = $y
}

function Apply-Shape {
  param([bool]$Expanded)

  $ballSize = Get-BallSize
  $script:Expanded = $Expanded

  # The turn signal follows the shape: the collapsed ball is the only place a breath can be
  # seen, so opening the panel takes both of them off (and closing it puts them back, from the
  # two booleans the last state document set -- see Update-BallPulse).
  Update-BallPulse

  $oldWidth = $window.Width

  if ($Expanded) {
    # Remember the ball's own corner BEFORE the panel grows, so collapsing can put the ball
    # back on that corner instead of inheriting the shove an expand may have needed.

    if ($null -eq $script:CollapsedAnchor) {
      $script:CollapsedAnchor = @{ Left = $window.Left; Top = $window.Top }
    }
    $ballView.Visibility = 'Collapsed'
    $panelView.Visibility = 'Visible'
    $panel = Get-PanelMetrics
    # MEASURE FIRST, SIZE ONCE: the panel is given its final width and its content's own
    # height, and the window never wears the ceiling on the way there -- two sizes inside one
    # call is a frame the compositor may show as 'it opens big and then shrinks'.
    #
    # The width goes on the PANEL before the measurement (so the height is measured for the
    # width it is going to have) and on the window right after it, with nothing in between
    # that could take an instant. Get-PanelHeight still answers with the ceiling if the
    # measurement itself fails, so the fallback is intact.

    $panelView.Width = $panel.Width
    $height = Get-PanelHeight $panel
    # ...and the two writes that actually resize the window happen with NOTHING visible
    # inside it: the ball is hidden by now and the panel is hidden for exactly these two
    # statements, so however the compositor schedules a frame around them there is no wrong
    # size for that frame to show.

    $panelView.Visibility = 'Collapsed'
    $window.Width = $panel.Width + (2 * $script:PanelPad)
    $window.Height = $height + (2 * $script:PanelPad)
    $panelView.Visibility = 'Visible'
    Write-BallDebug ('expanded at ' + [math]::Round($window.Width) + 'x' + [math]::Round($window.Height) +
      ' (ceiling ' + [math]::Round($panel.MaxHeight) + ')')
  } else {
    # Collapsing hides every box, so the keyboard must not stay here.
    Exit-KeyboardMode
    if ($createPopup.IsOpen) { $createPopup.IsOpen = $false }
    $ballView.Width = $ballSize
    $ballView.Height = $ballSize
    $ballBody.Width = $ballSize
    $ballBody.Height = $ballSize
    # The ring is 2px WIDER than the body, so its outer edge reaches 1px past the body's rim
    # on every side.
    #
    # That 1px of overflow is the reason the ring carries Margin="-1" in the XAML and nothing
    # here can drop it: WPF clips an element to its layout SLOT rather than to the element's own
    # size, and it anchors an oversized Stretch child at the slot's TOP-LEFT. Sized to ballSize+2
    # inside a ballSize slot the ring therefore lost its last 2px on the right and the bottom
    # only -- a flat chord along two edges, which is exactly how the ball looked 'cut off'. The
    # negative margin inflates the slot to ballSize+2, the element fits its slot exactly again,
    # and the two numbers below stay the single source of truth for the ring's size.

    $ballRing.Width = $ballSize + 2
    $ballRing.Height = $ballSize + 2
    # [local patch 2026-11-05] the DeepSeek whale mark keeps its proportions at any
    # configured ballSize (default 64), instead of the old fixed 16pt "DS" glyph.
    $ballMark.Width = [math]::Round($ballSize * $script:BallMarkScaleFactor)
    $ballMark.Height = $ballMark.Width
    $markFlip = $window.FindName('MarkFlip')
    if ($null -ne $markFlip) { $markFlip.ScaleX = $script:BallMarkFlip }
    $markRotate = $window.FindName('MarkRotate')
    if ($null -ne $markRotate) { $markRotate.Angle = $script:BallMarkAngle }
    $markShadow = $window.FindName('MarkShadow')
    if ($null -ne $markShadow) { $markShadow.Visibility = Get-Visibility ([bool]$script:BallMarkShadow) }
    $markBubbles = $window.FindName('MarkBubbles')
    if ($null -ne $markBubbles) { $markBubbles.Visibility = Get-Visibility ([bool]$script:BallMarkBubbles) }
    $panelView.Visibility = 'Collapsed'
    $ballView.Visibility = 'Visible'
    $window.Width = Get-BallWindowSize
    $window.Height = Get-BallWindowSize

    $anchor = $script:CollapsedAnchor
    $script:CollapsedAnchor = $null
    if ($null -ne $anchor) {
      # Back to exactly where the ball was (see above), no corner arithmetic.
      $window.Left = [double]$anchor['Left']
      $window.Top = [double]$anchor['Top']
      Move-IntoVirtualScreen
      return
    }
  }

  # Anchor the top-right corner: a ball parked against the right edge expands leftwards and
  # snaps back when it collapses. Only the WIDTH takes part in this -- the height has already
  # been settled above, which is also what makes the clamp below use the panel's real size.

  if ($oldWidth -gt 0) {
    $window.Left = $window.Left + ($oldWidth - $window.Width)
  }

  Move-IntoVirtualScreen

  # No height call is left for the end of this function: the expand path above has already
  # put the window at its FINAL size, so the clamp here works on the size the panel really
  # has, and a re-measure could only answer the same number again.

}

function Set-DefaultPosition {
  # First run only (the host then remembers whatever position the user leaves): bottom-right
  # of the WORK AREA, not the top-right -- the top-right corner is where browser tabs,
  # document headers and the page's own top bar live.
  #
  # Called AFTER the first Apply-Shape, so the window already carries the collapsed ball's
  # real size and the corner lands exactly.

  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - $window.Width - 8
  $window.Top = $work.Bottom - $window.Height - 8
  Move-IntoVirtualScreen
}

# Collapse the panel and tell the host, so the shape survives a restart. Called
# from the panel's own '-' button.
function Collapse-Panel {
  if (-not $script:Expanded) { return }
  Apply-Shape $false
  Send-Action ([ordered]@{ kind = 'expanded'; expanded = $false })
}

# ---------------------------------------------------------------------------
# Pending cards (questions and approvals)
# ---------------------------------------------------------------------------

function New-Card {
  param([string]$Accent)

  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius 14
  $border.BorderThickness = New-Object System.Windows.Thickness 1
  $border.BorderBrush = Get-SoftBrush $Accent 0.55
  $border.Background = ConvertTo-ColorBrush '#FF1A1F29'
  $border.Padding = New-Object System.Windows.Thickness 14, 12, 14, 13
  $border.Margin = New-Object System.Windows.Thickness 0, 0, 0, 12

  $stack = New-Object System.Windows.Controls.StackPanel
  $border.Child = $stack
  return @{ Border = $border; Stack = $stack }
}

function Add-CardText {
  param($Stack, [string]$Text, [double]$Size, [string]$Color, [double]$TopGap = 0, [string]$Weight = 'Normal')

  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  $block = New-Object System.Windows.Controls.TextBlock
  $block.Text = $Text
  $block.TextWrapping = 'Wrap'
  $block.FontSize = $Size
  $block.Foreground = ConvertTo-ColorBrush $Color
  $block.Margin = New-Object System.Windows.Thickness 0, $TopGap, 0, 0
  if ($Weight -eq 'Bold') { $block.FontWeight = 'SemiBold' }
  [void]$Stack.Children.Add($block)
}

# One rule, one look: an option is either ON (the card's own accent colour, a filled mark,
# dark bold text) or OFF (dim, hollow mark, plain text). Nothing depends on the current
# status colour or on a control template's own idea of 'checked'.

function Set-OptionVisual {
  param($Button, [bool]$Selected, [string]$Accent)

  $info = $Button.Tag
  $label = [string]$info['label']
  $on = Get-Label 'optionOn' '*'
  $off = Get-Label 'optionOff' '-'
  if ($Selected) {
    $Button.Background = ConvertTo-ColorBrush $Accent
    $Button.Foreground = ConvertTo-ColorBrush '#FF10141B'
    $Button.BorderBrush = ConvertTo-ColorBrush $Accent
    $Button.FontWeight = 'SemiBold'
    $Button.Content = $on + ' ' + $label
  } else {
    $Button.Background = ConvertTo-ColorBrush '#14FFFFFF'
    $Button.Foreground = ConvertTo-ColorBrush '#FFD7DEEA'
    $Button.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
    $Button.FontWeight = 'Normal'
    $Button.Content = $off + ' ' + $label
  }
}

function New-OptionButton {
  param([string]$PendingId, [string]$ItemId, [string]$Label, [string]$Description, [bool]$Multi, [string]$Accent)

  $button = New-Object System.Windows.Controls.Button
  $button.FontSize = 12
  $button.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
  $button.Margin = New-Object System.Windows.Thickness 0, 5, 6, 0
  $button.BorderThickness = New-Object System.Windows.Thickness 1
  $button.HorizontalContentAlignment = 'Left'
  $button.Cursor = 'Hand'
  $button.Style = $window.FindResource('IconButton')
  $button.Tag = @{ pendingId = $PendingId; itemId = $ItemId; label = $Label; multi = $Multi; accent = $Accent }
  Set-OptionVisual $button $false $Accent
  if (-not [string]::IsNullOrWhiteSpace($Description)) { $button.ToolTip = $Description }

  # Per-button data rides on Tag, NOT on a closure (see the note in
  # New-TargetItemButton for why).
  $button.Add_Click({
    param($sender, $e)
    try {
      $info = $sender.Tag
      $pendingId = [string]$info['pendingId']
      $itemId = [string]$info['itemId']
      $label = [string]$info['label']
      $multi = [bool]$info['multi']
      Write-BallDebug ('option click pending=' + $pendingId + ' item=' + $itemId + ' label=' + $label)
      $store = $script:Selections[$pendingId]
      if ($null -eq $store) {
        Write-BallDebug 'option click: selection store missing'
        return
      }
      $selected = $store[$itemId]
      if ($null -eq $selected) {
        $selected = New-Object System.Collections.ArrayList
        $store[$itemId] = $selected
      }
      # Clicking an option always toggles THAT option: on -> off, off -> on.
      # For a single-choice question picking another option clears this one
      # first, so the two controls can never disagree about what is selected.
      if ($selected.Contains($label)) {
        [void]$selected.Remove($label)
      } else {
        if (-not $multi) { $selected.Clear() }
        [void]$selected.Add($label)
      }
      # Repaint every button of this question from what is actually selected now:
      # the visual always follows the stored answer, never the other way round.
      foreach ($other in @($store[$itemId + '|buttons'])) {
        $otherInfo = $other.Tag
        $otherLabel = [string]$otherInfo['label']
        Set-OptionVisual $other ($selected.Contains($otherLabel)) ([string]$otherInfo['accent'])
      }
      Write-BallDebug ('option state: ' + [string]$selected.Count + ' selected')
    } catch {
      Write-BallLog ('option click failed: ' + $_.Exception.Message)
    }
  })

  return $button
}

# ---------------------------------------------------------------------------
# Session entries: the whole body of the panel
# ---------------------------------------------------------------------------
#
# An entry IS a session's panel: its headline, its own notice line, its own cards, and its
# own text box with the Send button. Everything below builds, updates and removes those
# rows.
#
# Two facts shape the code:
#
#   * A row is REBUILT only when it must be (it first appears, its card set really changed):
#     typing must survive a state document, and the host publishes one every 120ms while a
#     model streams. Everything that merely changes (colours, the state word, the time, the
#     lock) is written IN PLACE on the controls that already exist.
#   * The ORDER of the rows never moves an existing row: a new row is inserted ABOVE the
#     others (see Sync-Entries), so a row appearing mid-sentence cannot shuffle the box the
#     user is typing in.

# One entry, built from nothing but its key and whether it carries a box.
#
# The second parameter must NOT be called `$Input`: that name is one of PowerShell's AUTOMATIC
# variables (`$input`, the pipeline enumerator), and a parameter with that name reads as a
# truthy enumerator no matter what the caller passes -- measured: every row got a box, and the
# card-only entries (which have nowhere to send to) grew a dead one.
function New-EntryView {
  param([string]$Key, [bool]$WithBox)

  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius 14
  $border.BorderThickness = New-Object System.Windows.Thickness 1
  $border.BorderBrush = ConvertTo-ColorBrush '#26FFFFFF'
  $border.Background = ConvertTo-ColorBrush '#FF1D2330'
  $border.Padding = New-Object System.Windows.Thickness 14, 12, 14, 13
  $border.Margin = New-Object System.Windows.Thickness 0, 0, 0, 12
  $border.Add_MouseEnter({ param($s, $e) try { $s.Background = ConvertTo-ColorBrush '#FF252C3B' } catch { } })
  $border.Add_MouseLeave({ param($s, $e) try { $s.Background = ConvertTo-ColorBrush '#FF1D2330' } catch { } })

  $stack = New-Object System.Windows.Controls.StackPanel
  $border.Child = $stack

  # --- headline: status dot | session name | [got it] [x] ---
  $head = New-Object System.Windows.Controls.Grid
  $colDot = New-Object System.Windows.Controls.ColumnDefinition
  $colDot.Width = [System.Windows.GridLength]::Auto
  $colTitle = New-Object System.Windows.Controls.ColumnDefinition
  $colTitle.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
  $colButtons = New-Object System.Windows.Controls.ColumnDefinition
  $colButtons.Width = [System.Windows.GridLength]::Auto
  [void]$head.ColumnDefinitions.Add($colDot)
  [void]$head.ColumnDefinitions.Add($colTitle)
  [void]$head.ColumnDefinitions.Add($colButtons)

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8
  $dot.Height = 8
  $dot.Fill = ConvertTo-ColorBrush '#FF7C8598'
  $dot.VerticalAlignment = 'Top'
  $dot.Margin = New-Object System.Windows.Thickness 0, 5, 8, 0
  [System.Windows.Controls.Grid]::SetColumn($dot, 0)
  [void]$head.Children.Add($dot)

  $title = New-Object System.Windows.Controls.TextBlock
  $title.FontSize = 13
  $title.FontWeight = 'SemiBold'
  $title.Foreground = ConvertTo-ColorBrush '#FFF1F4F9'
  $title.TextTrimming = 'CharacterEllipsis'
  $title.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($title, 1)
  [void]$head.Children.Add($title)

  $buttons = New-Object System.Windows.Controls.StackPanel
  $buttons.Orientation = 'Horizontal'
  $buttons.VerticalAlignment = 'Top'
  [System.Windows.Controls.Grid]::SetColumn($buttons, 2)

  # "got it": clears this row's error off the ball and KEEPS the row (see the top of this
# file). It is shown only while this row carries an unacknowledged error. "x" below does the
# same thing AND removes the row, so a red is never left without a way out.
  $ack = New-Object System.Windows.Controls.Button
  $ack.Content = Get-Label 'entryAck' 'ok'
  $ack.FontSize = 11
  $ack.Padding = New-Object System.Windows.Thickness 9, 1, 9, 1
  $ack.Cursor = 'Hand'
  $ack.Style = $window.FindResource('IconButton')
  $ack.Background = ConvertTo-ColorBrush '#14FFFFFF'
  $ack.Foreground = ConvertTo-ColorBrush '#FFE9A79F'
  $ack.BorderBrush = ConvertTo-ColorBrush '#55E0574B'
  $ack.BorderThickness = New-Object System.Windows.Thickness 1
  $ack.Visibility = 'Collapsed'
  $ack.Tag = @{ key = $Key }
  $ack.Add_Click({
    param($sender, $e)
    try {
      Clear-EntryUnread ([string]$sender.Tag['key'])
      Send-Action ([ordered]@{ kind = 'ack'; id = $sender.Tag['key'] })
    } catch {
      Write-BallLog ('ack click failed: ' + $_.Exception.Message)
    }
  })
  [void]$buttons.Children.Add($ack)

  # "x": remove THIS row from the panel. The session is untouched (the host hides the cards
  # this row was showing, but the request itself stays alive and the web UI can still answer).
  # It ALSO means "got it": if this row is showing an error, the host acknowledges that error
  # while removing the row - otherwise the red would stay on the ball with nothing left to
  # press (the "got it" button lives on this very row).
  $close = New-Object System.Windows.Controls.Button
  $close.Content = Get-Label 'entryClose' 'x'
  $close.FontSize = 11.5
  $close.Padding = New-Object System.Windows.Thickness 7, 1, 7, 1
  $close.Margin = New-Object System.Windows.Thickness 5, 0, 0, 0
  $close.Cursor = 'Hand'
  $close.Style = $window.FindResource('IconButton')
  $close.Background = ConvertTo-ColorBrush '#14FFFFFF'
  $close.Foreground = ConvertTo-ColorBrush '#FFB9C2D2'
  $close.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
  $close.BorderThickness = New-Object System.Windows.Thickness 1
  $close.Tag = @{ key = $Key; local = $script:LocalEntries.ContainsKey($Key) }
  $close.Add_Click({
    param($sender, $e)
    try {
      $info = $sender.Tag
      $closeKey = [string]$info['key']
      Clear-EntryUnread $closeKey
      # A row this ball invented ("+ new session") is not the host's to remove: drop it here
      # and say nothing to the host (it never knew about it).
      if ([bool]$info['local']) {
        Sync-RemoveLocal $closeKey
        return
      }
      Send-Action ([ordered]@{ kind = 'close'; id = $closeKey })
    } catch {
      Write-BallLog ('close click failed: ' + $_.Exception.Message)
    }
  })
  [void]$buttons.Children.Add($close)
  [void]$head.Children.Add($buttons)
  [void]$stack.Children.Add($head)

  # --- second line: state word | when | directory | session id tail ---
  $detail = New-Object System.Windows.Controls.TextBlock
  $detail.FontSize = 11
  $detail.Foreground = ConvertTo-ColorBrush '#FF9AA3B4'
  $detail.TextWrapping = 'Wrap'
  $detail.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
  [void]$stack.Children.Add($detail)

  # --- this row's own notice line (the send receipt / a refusal) ---
  $notice = New-Object System.Windows.Controls.TextBlock
  $notice.FontSize = 11
  $notice.Foreground = ConvertTo-ColorBrush '#FFD9A54B'
  $notice.TextWrapping = 'Wrap'
  $notice.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
  $notice.Visibility = 'Collapsed'
  [void]$stack.Children.Add($notice)

  # --- the error's own line (the reason, kept after "got it" until the row is removed) ---
  $error = New-Object System.Windows.Controls.TextBlock
  $error.FontSize = 11
  $error.Foreground = ConvertTo-ColorBrush '#FFE9A79F'
  $error.TextWrapping = 'Wrap'
  $error.Margin = New-Object System.Windows.Thickness 0, 5, 0, 0
  $error.Visibility = 'Collapsed'
  [void]$stack.Children.Add($error)

  # --- this row's cards (a question or an approval belonging to this session) ---
  $cards = New-Object System.Windows.Controls.StackPanel
  $cards.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
  [void]$stack.Children.Add($cards)

  # --- this row's own box + Send ---
  $box = $null
  $watermark = $null
  $send = $null
  if ($WithBox) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
    $colBox = New-Object System.Windows.Controls.ColumnDefinition
    $colBox.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $colSend = New-Object System.Windows.Controls.ColumnDefinition
    $colSend.Width = [System.Windows.GridLength]::Auto
    [void]$row.ColumnDefinitions.Add($colBox)
    [void]$row.ColumnDefinitions.Add($colSend)

    $boxGrid = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetColumn($boxGrid, 0)

    $box = New-Object System.Windows.Controls.TextBox
    $box.Style = $window.FindResource('SlimBox')
    $box.FontSize = 12
    $box.Padding = New-Object System.Windows.Thickness 8, 4, 8, 4
    $box.Background = ConvertTo-ColorBrush '#FF0E1117'
    $box.Foreground = ConvertTo-ColorBrush '#FFE9EEF7'
    $box.BorderBrush = ConvertTo-ColorBrush '#33FFFFFF'
    $box.BorderThickness = New-Object System.Windows.Thickness 1
    $box.CaretBrush = ConvertTo-ColorBrush '#FFE9EEF7'
    $box.AcceptsReturn = $false
    $box.Tag = @{ key = $Key }
    [void]$boxGrid.Children.Add($box)

    $watermark = New-Object System.Windows.Controls.TextBlock
    $watermark.FontSize = 11.5
    $watermark.Foreground = ConvertTo-ColorBrush '#FF6E7787'
    $watermark.Margin = New-Object System.Windows.Thickness 9, 0, 8, 0
    $watermark.VerticalAlignment = 'Center'
    $watermark.IsHitTestVisible = $false
    $watermark.TextTrimming = 'CharacterEllipsis'
    [void]$boxGrid.Children.Add($watermark)
    [void]$row.Children.Add($boxGrid)

    $send = New-Object System.Windows.Controls.Button
    $send.Content = Get-Label 'sendMessage' 'Send'
    $send.FontSize = 11.5
    $send.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
    $send.Margin = New-Object System.Windows.Thickness 6, 0, 0, 0
    $send.Cursor = 'Hand'
    $send.Style = $window.FindResource('IconButton')
    $send.Background = ConvertTo-ColorBrush '#1AFFFFFF'
    $send.Foreground = ConvertTo-ColorBrush '#FFD7DEEA'
    $send.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
    $send.BorderThickness = New-Object System.Windows.Thickness 1
    $send.Tag = @{ key = $Key }
    [System.Windows.Controls.Grid]::SetColumn($send, 1)
    [void]$row.Children.Add($send)
    [void]$stack.Children.Add($row)

    # A TextBox marks MouseLeftButtonDown handled while it places the caret, so the bubbling
    # event never reaches a plain handler on it: the TUNNELING preview is what a control like
    # this must listen to. Same keyboard machinery as every other box on this ball.
    $box.Add_PreviewMouseLeftButtonDown({
      param($sender, $e)
      try {
        Enter-KeyboardMode $sender
        Write-BallDebug 'entry box focus requested'
      } catch {
        Write-BallLog ('entry box click failed: ' + $_.Exception.Message)
      }
    })
    $box.Add_TextChanged({
      try {
        $info = $sender.Tag
        $changedKey = [string]$info['key']
        Update-EntryCompose $changedKey $script:EntryData[$changedKey]
      } catch { }
    })
    $box.Add_PreviewKeyDown({
      param($sender, $e)
      try {
        # An IME-processed Enter never reports Key=Return, so committing Chinese candidates
        # does not send a half-finished sentence.
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
          $e.Handled = $true
          Send-EntryText ([string]$sender.Tag['key'])
          return
        }
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
          $e.Handled = $true
          Exit-KeyboardMode
        }
      } catch {
        Write-BallLog ('entry key failed: ' + $_.Exception.Message)
      }
    })
    $send.Add_Click({
      param($sender, $e)
      try {
        Send-EntryText ([string]$sender.Tag['key'])
        # Enter/Send keeps the keyboard: the next sentence goes into the same row.
        if ($script:KeyboardActive) { Invoke-FocusBox $script:FocusBox }
      } catch {
        Write-BallLog ('entry send click failed: ' + $_.Exception.Message)
      }
    })

    $script:FocusHints[$box] = $watermark
    $script:BoxOwner[$box] = 'entry:' + $Key
  }

  return @{
    Key = $Key
    Target = ''
    Panel = $border
    Dot = $dot
    Title = $title
    Detail = $detail
    Notice = $notice
    Error = $error
    Ack = $ack
    Close = $close
    Cards = $cards
    Box = $box
    Watermark = $watermark
    Send = $send
    Input = $WithBox
    Locked = $false
    LockReason = ''
  }
}

# What one row looks like right now, from the host's entry data (or from this ball's own data
# for a local "+ new session" row). Everything here is written IN PLACE: no control is
# recreated, so a state document cannot interrupt typing.
function Update-EntryView {
  param([string]$Key, $Entry)

  $view = $script:EntryViews[$Key]
  if ($null -eq $view) { return }

  $color = [string](Get-ChildValue $Entry 'color' '#FF7C8598')
  if ([string](Get-ChildValue $Entry 'state' '') -eq 'approval') { $color = '#FFE0A64B' }
  $view.Target = [string](Get-ChildValue $Entry 'target' '')
  $view.Dot.Fill = ConvertTo-ColorBrush $color
  $view.Panel.BorderBrush = Get-SoftBrush $color 0.5
  $view.Title.Text = [string](Get-ChildValue $Entry 'title' '')
  $view.Detail.Text = [string](Get-ChildValue $Entry 'detail' '')

  # "got it" exists only while this row carries an error nobody has acknowledged yet. After
  # that the row keeps the error's own line (so it is still visible what happened) but the
  # colour is gone -- and so is the button (see the top of this file).
  $canAck = [bool](Get-ChildValue $Entry 'canAck' $false)
  $view.Ack.Visibility = Get-Visibility $canAck
  $errorNote = [string](Get-ChildValue $Entry 'errorNote' '')
  $view.Error.Text = $errorNote
  $view.Error.Visibility = Get-Visibility (-not [string]::IsNullOrWhiteSpace($errorNote))

  # The box's own "x" is replaced when this key becomes a LOCAL row (the click handler asks
  # whether the host owns it), so keep the Tag in step with what this key is right now.
  $view.Close.Tag = @{ key = $Key; local = $script:LocalEntries.ContainsKey($Key) }

  Rebuild-EntryCards $Key $Entry
  Update-EntryCompose $Key $Entry
  Apply-EntryNotice $Key
}

# Bring the panel in line with one state document: which rows exist, in what order, and what
# each of them says. Rows are only ever added or removed here; their contents are refreshed
# by Update-EntryView.
# --- panel filter / ordering / unread bookkeeping ------------------------------------------
function Read-UnreadDone {
  try {
    if (-not (Test-Path -LiteralPath $script:UnreadFile)) { return }
    $text = [System.IO.File]::ReadAllText($script:UnreadFile, [System.Text.Encoding]::UTF8)
    $document = ConvertFrom-Json -InputObject $text
    foreach ($key in @($document.keys)) {
      $name = [string]$key
      if ($name -ne '') { $script:UnreadDone[$name] = $true }
    }
    Write-BallDebug ('unread set restored: ' + [string]$script:UnreadDone.Count + ' session(s)')
  } catch {
    Write-BallLog ('could not read unread.json: ' + $_.Exception.Message)
  }
}

function Save-UnreadDone {
  if (-not $script:UnreadDirty) { return }
  $script:UnreadDirty = $false
  try {
    $keys = @()
    foreach ($key in @($script:UnreadDone.Keys)) { $keys += [string]$key }
    $payload = ConvertTo-Json -Compress -Depth 3 -InputObject ([pscustomobject]@{ keys = $keys })
    [System.IO.File]::WriteAllText($script:UnreadFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Write-BallLog ('could not write unread.json: ' + $_.Exception.Message)
  }
}

# Any engagement with a row means its completed turn has been read.
function Clear-EntryUnread {
  param([string]$Key)
  if ($script:UnreadDone.ContainsKey($Key)) {
    $script:UnreadDone.Remove($Key)
    $script:UnreadDirty = $true
  }
}

# -1 = a local "+ new session" row, 0 = waiting for you, 1 = error, 2 = completed but unread,
# 3 = still running; $null means "this row does not belong on the panel".
function Get-EntryRank {
  param([string]$State, [bool]$Unread, [bool]$Local)
  if ($Local) { return -1 }
  switch ($State) {
    'approval' { return 0 }
    'question' { return 0 }
    'error' { return 1 }
    'running' { return 3 }
  }
  if ($Unread) { return 2 }
  return $null
}

function Sync-Entries {
  param($Document)

  $wanted = @(Get-ChildValue $Document 'entries' @())

  $script:EntryData = @{}
  foreach ($entry in $wanted) {
    $key = [string](Get-ChildValue $entry 'key' '')
    if ($key -eq '') { continue }
    $script:EntryData[$key] = $entry
    if (-not $script:EntryOrder.Contains($key)) { [void]$script:EntryOrder.Insert(0, $key) }
  }

  # Rows this ball invented with the "+" button. They have no host data yet, so their view is
  # synthesized here from what the workspace picker knew (title / directory / target).
  foreach ($key in @($script:LocalEntries.Keys)) {
    if (-not $script:EntryOrder.Contains($key)) { [void]$script:EntryOrder.Insert(0, $key) }
    if ($script:EntryData.ContainsKey($key)) { continue }
    $local = $script:LocalEntries[$key]
    # Shaped exactly like the host's own entry data (Get-ChildValue reads both shapes, but this
    # one stands in for host data, so it should look like it).
    $script:EntryData[$key] = [pscustomobject]@{
      key = $key
      target = [string]$local['target']
      input = $true
      title = [string]$local['title']
      detail = [string]$local['detail']
      state = 'idle'
      color = '#FF5B8DEF'
      busy = $false
      lock = $false
      errorNote = ''
      canAck = $false
      cards = @()
    }
  }

  # --- completed-but-unread bookkeeping ---------------------------------------------------
  # A row that was active in the previous document and is idle now has just finished a turn:
  # nobody has looked at that result, so it becomes "unread" and stays on the panel (rank 2)
  # until the user engages with it. A row that starts running / waiting / erroring again is
  # active again, and its unread flag is dropped (the next completion will set it again).
  foreach ($key in @($script:EntryData.Keys)) {
    if ($script:LocalEntries.ContainsKey($key)) { continue }
    $state = [string](Get-ChildValue $script:EntryData[$key] 'state' '')
    $previous = $script:EntryPrevState[$key]
    if ($null -ne $previous -and $previous -ne $state) {
      if ($state -eq 'idle' -and ($previous -eq 'running' -or $previous -eq 'approval' -or $previous -eq 'question' -or $previous -eq 'error')) {
        if (-not $script:UnreadDone.ContainsKey($key)) {
          $script:UnreadDone[$key] = $true
          $script:UnreadDirty = $true
        }
      } elseif ($state -ne 'idle' -and $script:UnreadDone.ContainsKey($key)) {
        $script:UnreadDone.Remove($key)
        $script:UnreadDirty = $true
      }
    }
    $script:EntryPrevState[$key] = $state
  }
  # A session that left the directory cannot stay "unread" (or "previous") forever.
  foreach ($key in @($script:UnreadDone.Keys)) {
    if (-not $script:EntryData.ContainsKey($key)) { $script:UnreadDone.Remove($key); $script:UnreadDirty = $true }
  }
  foreach ($key in @($script:EntryPrevState.Keys)) {
    if (-not $script:EntryData.ContainsKey($key)) { $script:EntryPrevState.Remove($key) }
  }

  # --- which rows are on the panel, and in what order -------------------------------------
  # Fixed buckets: -1 local "+ new session" rows, 0 waiting for you (approval/question),
  # 1 error, 2 completed but unread, 3 running. Within a bucket the host's own order (newest
  # first) is preserved; a row with no rank is simply not on the panel.
  $buckets = @{
    '-1' = New-Object System.Collections.ArrayList
    '0' = New-Object System.Collections.ArrayList
    '1' = New-Object System.Collections.ArrayList
    '2' = New-Object System.Collections.ArrayList
    '3' = New-Object System.Collections.ArrayList
  }
  foreach ($key in @($script:EntryOrder)) {
    if (-not $script:EntryData.ContainsKey($key)) { continue }
    $state = [string](Get-ChildValue $script:EntryData[$key] 'state' '')
    $rank = Get-EntryRank $state ($script:UnreadDone.ContainsKey($key)) ($script:LocalEntries.ContainsKey($key))
    if ($null -eq $rank) { continue }
    [void]$buckets[[string]$rank].Add($key)
  }
  $script:EntryOrder = New-Object System.Collections.ArrayList
  foreach ($rank in @(-1, 0, 1, 2, 3)) {
    foreach ($key in @($buckets[[string]$rank])) { [void]$script:EntryOrder.Add($key) }
  }

  # Rows that are no longer on the panel (idle without unread, acknowledged error, ...) are
  # taken down. Their data is re-read from the next document, and the unread/prev-state maps
  # live outside EntryData, so nothing about them is lost.
  foreach ($key in @($script:EntryViews.Keys)) {
    if (-not $script:EntryOrder.Contains($key)) { Remove-EntryView $key }
  }

  for ($index = 0; $index -lt $script:EntryOrder.Count; $index++) {
    $key = [string]$script:EntryOrder[$index]
    $entry = $script:EntryData[$key]
    if (-not $script:EntryViews.ContainsKey($key)) {
      $withBox = [bool](Get-ChildValue $entry 'input' $true)
      $view = New-EntryView $key $withBox
      $script:EntryViews[$key] = $view
      # A row appears ABOVE the ones already there (newest first): inserting here moves the
      # others down but never recreates them, so nothing the user is typing is disturbed.
      if ($index -lt $bodyStack.Children.Count) {
        $bodyStack.Children.Insert($index, $view.Panel)
      } else {
        [void]$bodyStack.Children.Add($view.Panel)
      }
      # A draft that survived an earlier removal of this same row comes back with it.
      if ($withBox -and $script:EntryDrafts.ContainsKey($key)) {
        $view.Box.Text = [string]$script:EntryDrafts[$key]
      }
      Write-BallDebug ('entry view created key=' + $key + ' input=' + [string]$withBox)
    }
    Update-EntryView $key $entry
  }

  # Belt and braces for the order: only a removal can leave a gap, and rows keep their
  # relative order, so this loop finds nothing to do in practice.
  for ($index = 0; $index -lt $script:EntryOrder.Count; $index++) {
    $key = [string]$script:EntryOrder[$index]
    if (-not $script:EntryViews.ContainsKey($key)) { continue }
    $panel = $script:EntryViews[$key].Panel
    if ($index -ge $bodyStack.Children.Count) { continue }
    if ([object]::ReferenceEquals($bodyStack.Children[$index], $panel)) { continue }
    [void]$bodyStack.Children.Remove($panel)
    $bodyStack.Children.Insert($index, $panel)
  }

  $emptyHint.Text = Get-Label 'entryEmpty' ''
  $emptyHint.Visibility = Get-Visibility ($script:EntryOrder.Count -eq 0)
  if ($script:UnreadDirty) { Save-UnreadDone }
}

# Remove a local row on the spot (the "+ new session" row the user closed). Used by the "x"
# handler for rows the host does not own.
function Sync-RemoveLocal {
  param([string]$Key)
  if (-not $script:LocalEntries.ContainsKey($Key)) { return }
  $script:EntryData.Remove($Key)
  Remove-EntryView $Key
  $emptyHint.Visibility = Get-Visibility ($script:EntryOrder.Count -eq 0)
}

# Tear one row down: its registries, the boxes it owned, and the panel itself.
function Remove-EntryView {
  param([string]$Key)

  $view = $script:EntryViews[$Key]
  $script:EntryViews.Remove($Key)
  $script:EntryData.Remove($Key)
  $script:EntryCardSig.Remove($Key)
  $script:EntryNotices.Remove($Key)
  $script:EntryHold.Remove($Key)
  [void]$script:EntryOrder.Remove($Key)
  if ($script:LocalEntries.ContainsKey($Key)) { $script:LocalEntries.Remove($Key) }

  $cards = @($script:EntryCardIds[$Key])

  # Is the keyboard in a box this row owns? Ask BEFORE the registries are cleared: the check
  # itself reads those registries, so afterwards it could only ever answer "no" -- and a ball
  # left in keyboard mode over a box that no longer exists would keep taking the foreground
  # with nothing to type into.
  if ($null -ne $script:FocusBox -and $script:BoxOwner.ContainsKey($script:FocusBox)) {
    if (Test-BoxOwnerInEntry ([string]$script:BoxOwner[$script:FocusBox]) $Key) { Exit-KeyboardMode }
  }

  foreach ($cardId in $cards) { Clear-CardRegistry $cardId }
  $script:EntryCardIds.Remove($Key)

  if ($null -eq $view) { return }

  # A draft typed into this row is remembered: the same session may come back later (it has
  # news again), and throwing away what the user typed would be rude.
  if ($view.Input -and -not [string]::IsNullOrWhiteSpace($view.Box.Text)) {
    $script:EntryDrafts[$Key] = [string]$view.Box.Text
  }
  else { $script:EntryDrafts.Remove($Key) }

  foreach ($box in @($script:BoxOwner.Keys)) {
    if (Test-BoxOwnerInEntry ([string]$script:BoxOwner[$box]) $Key) {
      $script:BoxOwner.Remove($box)
      $script:FocusHints.Remove($box)
    }
  }

  [void]$bodyStack.Children.Remove($view.Panel)
}

# Does this keyboard owner belong to that entry? 'entry:<key>' is the row's own box;
# 'card:<cardId>|<questionId>' is one of the boxes a card of that row carried.
function Test-BoxOwnerInEntry {
  param([string]$Owner, [string]$Key)
  if ([string]::IsNullOrWhiteSpace($Owner)) { return $false }
  if ($Owner -eq ('entry:' + $Key)) { return $true }
  if (-not $Owner.StartsWith('card:')) { return $false }
  $cardId = $Owner.Substring(5).Split('|')[0]
  return (@($script:EntryCardIds[$Key]) -contains $cardId)
}

# Drop the registries one card owns (its boxes, its hint lines, its selection store and its
# data). Called when the card is rebuilt or its whole row goes away.
function Clear-CardRegistry {
  param([string]$CardId)
  if ([string]::IsNullOrWhiteSpace($CardId)) { return }
  $prefix = $CardId + '|'
  foreach ($map in @($script:CustomBoxes, $script:CustomHints)) {
    foreach ($key in @($map.Keys)) {
      if (-not ([string]$key).StartsWith($prefix)) { continue }
      $box = $map[$key]
      if ($null -ne $box) {
        $script:BoxOwner.Remove($box)
        $script:FocusHints.Remove($box)
      }
      $map.Remove($key)
    }
  }
  $script:Selections.Remove($CardId)
  $script:AnswerItems.Remove($CardId)
}

# This row's cards. Rebuilt only when the card set really changed (a card arrived, one went
# away, an answer changed what the card holds) -- the boxes a card carries would otherwise be
# recreated several times a second while a model streams.
function Rebuild-EntryCards {
  param([string]$Key, $Entry)

  $view = $script:EntryViews[$Key]
  if ($null -eq $view) { return }

  $cards = @(Get-ChildValue $Entry 'cards' @())
  $signature = ($cards | ForEach-Object {
    $id = [string](Get-ChildValue $_ 'id' '')
    $kind = [string](Get-ChildValue $_ 'kind' '')
    $note = [string](Get-ChildValue $_ 'note' '')
    $deadline = [string](Get-ChildValue $_ 'deadlineAt' 0)
    $options = (@(Get-ChildValue $_ 'options' @()) | ForEach-Object { [string](Get-ChildValue $_ 'label' '') }) -join ','
    $items = (@(Get-ChildValue $_ 'items' @()) | ForEach-Object {
      $oid = [string](Get-ChildValue $_ 'id' '')
      $olabels = (@(Get-ChildValue $_ 'options' @()) | ForEach-Object { [string](Get-ChildValue $_ 'label' '') }) -join ','
      $oid + ':' + $olabels
    }) -join ';'
    $id + '/' + $kind + '/' + $note + '/' + $deadline + '/' + $options + '/' + $items
  }) -join '|'

  if ($script:EntryCardSig.ContainsKey($Key) -and ([string]$script:EntryCardSig[$Key]) -eq $signature) { return }
  $script:EntryCardSig[$Key] = $signature
  Write-BallDebug ('rebuild entry cards key=' + $Key + ' sig=' + $signature)

  # The boxes these cards carried are about to go: if one of them holds the keyboard, let it
  # go first (never keep a keyboard in a control that is leaving the tree).
  if ($null -ne $script:FocusBox -and $script:BoxOwner.ContainsKey($script:FocusBox)) {
    if (Test-BoxOwnerInEntry ([string]$script:BoxOwner[$script:FocusBox]) $Key) { Exit-KeyboardMode }
  }

  # Remember the drafts of those boxes before they are dropped, so a rebuild (which happens
  # when a SECOND card of the same session arrives, for instance) does not eat what was typed.
  foreach ($cardId in @($script:EntryCardIds[$Key])) {
    foreach ($key in @($script:CustomBoxes.Keys)) {
      if (-not ([string]$key).StartsWith($cardId + '|')) { continue }
      $box = $script:CustomBoxes[$key]
      if ($null -eq $box) { continue }
      if ([string]::IsNullOrWhiteSpace($box.Text)) { continue }
      $script:CardDrafts[[string]$key] = [string]$box.Text
    }
    Clear-CardRegistry $cardId
  }

  $view.Cards.Children.Clear()
  $ids = New-Object System.Collections.ArrayList
  foreach ($item in $cards) {
    $pendingId = [string](Get-ChildValue $item 'id' '')
    if ($pendingId -ne '') { [void]$ids.Add($pendingId) }
    Build-OneCard $view $item
  }
  $script:EntryCardIds[$Key] = @($ids.ToArray())
  Update-Countdowns
}

# ONE card, rendered inside its own session's entry: the approvals' allow/reject row, or the
# questions with their options and their own free-text box. There is no "dismiss" button here
# any more: removing a card from the ball is the row's own "x" (see New-EntryView).
function Build-OneCard {
  param($View, $item)

  $labels = Get-ChildValue $script:State 'labels' @{}
  $pendingId = [string](Get-ChildValue $item 'id' '')
  $kind = [string](Get-ChildValue $item 'kind' 'question')
  $accent = [string](Get-ChildValue $item 'color' '#FFE0A64B')
  if ($kind -eq 'approval') { $accent = '#FFE0A64B' }
  $card = New-Card $accent
  $script:AnswerItems[$pendingId] = $item

  $title = [string](Get-ChildValue $item 'title' '')
  Add-CardText $card.Stack $title 12.5 $accent 0 'Bold'

  $note = [string](Get-ChildValue $item 'note' '')
  Add-CardText $card.Stack $note 10.5 '#FF9AA3B4' 4

    if ($kind -eq 'approval') {
      $toolName = [string](Get-ChildValue $item 'toolName' '')
      if (-not [string]::IsNullOrWhiteSpace($toolName)) {
        Add-CardText $card.Stack ($toolName) 12 '#FFE9EEF7' 7
      }
      $reason = [string](Get-ChildValue $item 'reason' '')
      Add-CardText $card.Stack $reason 11 '#FFB4BCCB' 3

      $row = New-Object System.Windows.Controls.WrapPanel
      $row.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
      foreach ($option in @(Get-ChildValue $item 'options' @())) {
        $label = [string](Get-ChildValue $option 'label' '')
        $value = [string](Get-ChildValue $option 'value' '')
        $button = New-Object System.Windows.Controls.Button
        $button.Content = $label
        $button.FontSize = 12
        $button.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
        $button.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $button.Cursor = 'Hand'
        $button.Style = $window.FindResource('IconButton')
        $button.Background = ConvertTo-ColorBrush '#14FFFFFF'
        $button.Foreground = ConvertTo-ColorBrush '#FFD7DEEA'
        $button.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
        $button.BorderThickness = New-Object System.Windows.Thickness 1
        $button.Tag = @{ id = $pendingId; outcome = $value }
        $button.Add_Click({
          param($sender, $e)
          try {
            $info = $sender.Tag
            Send-Action ([ordered]@{ kind = 'approval'; id = $info['id']; outcome = $info['outcome'] })
          } catch {
            Write-BallLog ('approval click failed: ' + $_.Exception.Message)
          }
        })
        [void]$row.Children.Add($button)
      }
      [void]$card.Stack.Children.Add($row)
    } else {
      # ONE selection store per CARD, created before the question loop: a card with several
      # questions needs every one of them to repaint from what is selected now -- a store per
      # question would leave the earlier ones unable to paint as selected.

      $store = @{}
      $script:Selections[$pendingId] = $store

      foreach ($question in @(Get-ChildValue $item 'items' @())) {
        $questionId = [string](Get-ChildValue $question 'id' '')
        $header = [string](Get-ChildValue $question 'header' '')
        $text = [string](Get-ChildValue $question 'question' '')
        $detail = [string](Get-ChildValue $question 'detail' '')
        $multi = [bool](Get-ChildValue $question 'multiSelect' $false)

        $headline = $text
        if (-not [string]::IsNullOrWhiteSpace($header)) { $headline = '[' + $header + '] ' + $text }
        Add-CardText $card.Stack $headline 12 '#FFF1F4F9' 7 'Bold'
        Add-CardText $card.Stack $detail 11 '#FFA9B2C2' 3

        $buttons = New-Object System.Collections.ArrayList
        $store[$questionId] = New-Object System.Collections.ArrayList
        $store[$questionId + '|buttons'] = $buttons

        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($option in @(Get-ChildValue $question 'options' @())) {
          $label = [string](Get-ChildValue $option 'label' '')
          $description = [string](Get-ChildValue $option 'description' '')
          $button = New-OptionButton $pendingId $questionId $label $description $multi $accent
          [void]$buttons.Add($button)
          [void]$wrap.Children.Add($button)
        }
        if ($wrap.Children.Count -gt 0) { [void]$card.Stack.Children.Add($wrap) }

                # The per-question box needs the same keyboard machinery as the compose box --
        # in a WS_EX_NOACTIVATE window a TextBox can be clicked and typed into and
        # receive nothing at all.
        $customRow = New-Object System.Windows.Controls.DockPanel
        $customRow.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        $custom = New-Object System.Windows.Controls.TextBox
        $custom.Style = $window.FindResource('SlimBox')
        $custom.FontSize = 11.5
        $custom.Padding = New-Object System.Windows.Thickness 9, 5, 9, 5
        $custom.Background = ConvertTo-ColorBrush '#FF12151B'
        $custom.Foreground = ConvertTo-ColorBrush '#FFE9EEF7'
        $custom.BorderBrush = ConvertTo-ColorBrush '#2EFFFFFF'
        $custom.BorderThickness = New-Object System.Windows.Thickness 1
        $custom.CaretBrush = ConvertTo-ColorBrush '#FFE9EEF7'
        $custom.AcceptsReturn = $false
        [System.Windows.Controls.DockPanel]::SetDock($custom, 'Bottom')
        $hintText = [string](Get-ChildValue $labels 'customHint' '')
        if (-not [string]::IsNullOrWhiteSpace($hintText)) { $custom.ToolTip = $hintText }
        $custom.Tag = @{ cardId = $pendingId; itemId = $questionId }
        [void]$customRow.Children.Add($custom)
        # A draft typed into this box survives a rebuild of this row's cards (see
        # Rebuild-EntryCards: it stashes them before the boxes go away).
        $draftKey = $pendingId + '|' + $questionId
        if ($script:CardDrafts.ContainsKey($draftKey)) { $custom.Text = [string]$script:CardDrafts[$draftKey] }

        # A TextBox marks MouseLeftButtonDown handled while it places the caret,
        # so the bubbling event never reaches a plain handler on it: the
        # TUNNELING preview is what a control like this must listen to.
        $custom.Add_PreviewMouseLeftButtonDown({
          param($sender, $e)
          try {
            Enter-KeyboardMode $sender
            Write-BallDebug 'card box focus requested'
          } catch {
            Write-BallLog ('card box click failed: ' + $_.Exception.Message)
          }
        })

        $cardHint = New-Object System.Windows.Controls.TextBlock
        $cardHint.FontSize = 10.5
        $cardHint.Foreground = ConvertTo-ColorBrush '#FFE0A64B'
        $cardHint.TextWrapping = 'Wrap'
        $cardHint.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
        $cardHint.Visibility = 'Collapsed'

        $boxStack = New-Object System.Windows.Controls.StackPanel
        [void]$boxStack.Children.Add($customRow)
        [void]$boxStack.Children.Add($cardHint)
        [void]$card.Stack.Children.Add($boxStack)

        $script:CustomBoxes[$pendingId + '|' + $questionId] = $custom
        $script:CustomHints[$pendingId + '|' + $questionId] = $cardHint
        $script:FocusHints[$custom] = $cardHint
        $script:BoxOwner[$custom] = 'card:' + $pendingId + '|' + $questionId
      }

      $actionRow = New-Object System.Windows.Controls.WrapPanel
      $actionRow.Margin = New-Object System.Windows.Thickness 0, 9, 0, 0

      $sendLabel = [string](Get-ChildValue $labels 'send' 'Send')
      $send = New-Object System.Windows.Controls.Button
      $send.Content = $sendLabel
      $send.FontSize = 12
      $send.FontWeight = 'SemiBold'
      $send.Padding = New-Object System.Windows.Thickness 14, 5, 14, 5
      $send.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
      $send.Cursor = 'Hand'
      $send.Style = $window.FindResource('IconButton')
      $send.Background = ConvertTo-ColorBrush $accent
      $send.Foreground = ConvertTo-ColorBrush '#FF10141B'
      $send.BorderThickness = New-Object System.Windows.Thickness 0
      $send.Tag = @{ id = $pendingId }
      $send.Add_Click({
        param($sender, $e)
        try {
          $sendId = [string]$sender.Tag['id']
          $entry = $script:AnswerItems[$sendId]
          Write-BallDebug ('send click id=' + $sendId + ' entry=' + [bool]($null -ne $entry) + ' store=' + [bool]($null -ne $script:Selections[$sendId]))
          if ($null -eq $entry) { return }
          $store = $script:Selections[$sendId]
          $answers = New-Object System.Collections.ArrayList
          $unanswered = ''
          foreach ($question in @(Get-ChildValue $entry 'items' @())) {
            $questionId = [string](Get-ChildValue $question 'id' '')
            $selected = $store[$questionId]
            $box = $script:CustomBoxes[$sendId + '|' + $questionId]
            $customText = ''
            if ($null -ne $box) { $customText = [string]$box.Text }
            $answered = ($null -ne $selected -and $selected.Count -gt 0) -or -not [string]::IsNullOrWhiteSpace($customText)
            if (-not $answered) {
                            # Do NOT just return: a click that does nothing at all is the worst thing
              # this card can do. Remember the FIRST question still missing an answer and
              # say so in the card itself.
              if ($unanswered -eq '') { $unanswered = $questionId }
              Set-CardHint $sendId $questionId (Get-Label 'answerIncomplete' '')
              continue
            }
            Set-CardHint $sendId $questionId ''
            $answer = [ordered]@{ id = $questionId; selected = @() }
            if ($null -ne $selected -and $selected.Count -gt 0) { $answer.selected = @($selected.ToArray()) }
            if (-not [string]::IsNullOrWhiteSpace($customText)) { $answer.custom = $customText }
            [void]$answers.Add($answer)
          }
          if ($unanswered -ne '') {
            Write-BallDebug ('send refused: question ' + $unanswered + ' has no answer yet')
            return
          }
          if ($answers.Count -eq 0) { return }
          Send-Action ([ordered]@{ kind = 'answer'; id = $sendId; answers = @($answers.ToArray()) })
        } catch {
          Write-BallLog ('send failed: ' + $_.Exception.Message)
        }
      })
      [void]$actionRow.Children.Add($send)

      [void]$card.Stack.Children.Add($actionRow)
    }

    $countdown = New-Object System.Windows.Controls.TextBlock
    $countdown.FontSize = 10
    $countdown.Foreground = ConvertTo-ColorBrush '#FF98A2B3'
    $countdown.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
    $countdown.Tag = 'countdown|' + [string](Get-ChildValue $item 'deadlineAt' 0)
    [void]$card.Stack.Children.Add($countdown)

    [void]$View.Cards.Children.Add($card.Border)
}

# ---------------------------------------------------------------------------
# Diagnostics: with DSH_BALL_DEBUG=1, log where the interactive elements really are on
# screen. Hit-testing problems are invisible in a screenshot; this makes them exact.
# ---------------------------------------------------------------------------


function Write-ElementGeometry {
  param($Element)
  if ($null -eq $Element) { return }
  try {
    $kind = $Element.GetType().Name
    $interactive = ($Element -is [System.Windows.Controls.Button]) -or
      ($Element -is [System.Windows.Controls.TextBox])
    if ($interactive) {
      $origin = $Element.PointToScreen((New-Object System.Windows.Point 0, 0))
      Write-BallDebug ('  geometry ' + $kind + ' "' + [string]$Element.Content + '" at ' +
        [math]::Round($origin.X) + ',' + [math]::Round($origin.Y) +
        ' size ' + [math]::Round($Element.ActualWidth) + 'x' + [math]::Round($Element.ActualHeight) +
        ' visible=' + [string]$Element.IsVisible + ' enabled=' + [string]$Element.IsEnabled)
    }
  } catch {
    Write-BallDebug ('  geometry failed: ' + $_.Exception.Message)
  }
  try {
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
    for ($index = 0; $index -lt $count; $index++) {
      Write-ElementGeometry ([System.Windows.Media.VisualTreeHelper]::GetChild($Element, $index))
    }
  } catch { }
}

function Write-CardGeometry {
  if ($env:DSH_BALL_DEBUG -ne '1') { return }
  try { $window.UpdateLayout() } catch { }
  Write-BallDebug ('window at ' + [math]::Round($window.Left) + ',' + [math]::Round($window.Top) +
    ' size ' + [math]::Round($window.Width) + 'x' + [math]::Round($window.Height) +
    ' expanded=' + [string]$script:Expanded + ' entries=' + [string]$script:EntryOrder.Count)
  foreach ($key in @($script:EntryOrder)) {
    $view = $script:EntryViews[$key]
    if ($null -eq $view) { continue }
    Write-BallDebug ('  entry ' + $key + ' title="' + [string]$view.Title.Text + '"')
    Write-ElementGeometry $view.Panel
  }
}

function Update-Countdowns {
  $now = Get-NowMs
  $template = Get-Label 'countdown' ''
  $expired = Get-Label 'expired' ''
  # The countdown lines live inside the cards, and the cards live inside their own entry:
  # walk the rows instead of a single card stack.
  foreach ($key in @($script:EntryOrder)) {
    $view = $script:EntryViews[$key]
    if ($null -eq $view) { continue }
    foreach ($card in $view.Cards.Children) {
      $stack = $card.Child
      if ($null -eq $stack) { continue }
      foreach ($child in $stack.Children) {
        $tag = [string]$child.Tag
        if (-not $tag.StartsWith('countdown|')) { continue }
        $deadline = [double]($tag.Substring(10))
        if ($deadline -le 0) { $child.Text = ''; continue }
        $remaining = [math]::Max(0, [math]::Round(($deadline - $now) / 1000))
        if ($remaining -le 0) {
          $child.Text = $expired
        } elseif (-not [string]::IsNullOrWhiteSpace($template)) {
          $child.Text = $template.Replace('{n}', [string]$remaining)
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Applying one state document
# ---------------------------------------------------------------------------



# The host's receipt for a message sent from the ball. It decides two things: which ROW the
# message came from (that row unlocks, and the outcome is written into its own notice line),
# and which session it really landed in (a row the "+" button invented is handed over to the
# real session as soon as the receipt names it).
#
# Only a receipt for a message THIS ball process sent counts (`AwaitingSend`): one left over
# from before the ball restarted must change nothing.

function Apply-SendResult {
  $result = Get-ChildValue $script:State 'sendResult' $null
  if ($null -eq $result) { return }
  $seq = [int](Get-ChildValue $result 'seq' 0)
  if ($seq -le 0) { return }
  if ($seq -eq $script:LastSendSeq) { return }
  $script:LastSendSeq = $seq
  if (-not $script:AwaitingSend) { return }
  $script:AwaitingSend = $false

  $ok = [bool](Get-ChildValue $result 'ok' $false)
  $key = [string](Get-ChildValue $result 'key' '')
  $id = [string](Get-ChildValue $result 'id' '')
  $note = [string](Get-ChildValue $result 'note' '')
  if ($key -eq '') { $key = $script:PendingSendKey }
  $script:PendingSendKey = ''
  Write-BallDebug ('send receipt seq=' + $seq + ' ok=' + [string]$ok + ' key=' + $key + ' id=' + $id)

  $wasLocal = $script:LocalEntries.ContainsKey($key)
  if (-not $ok) {
    # Nothing went out, so there is nothing to wait for: unlock AT ONCE and let the user retry
    # (the reason is also in the host's footer notice). A local "new session" row stays where
    # it is: nothing was created, so there is nothing to hand over to.
    $script:EntryHold.Remove($key)
    if ($note -ne '') { Set-EntryNotice $key $note }
    Update-EntryCompose $key $script:EntryData[$key]
    return
  }

  # The message is in the session now, but the turn it starts may take another moment to show
  # up in the host's own per-entry lock: keep the lock for a short grace instead of blinking
  # open and closed in between. Both names get it, because a local row is about to change name.
  $until = (Get-NowMs) + 1500
  $script:EntryHold[$key] = $until
  if ($wasLocal) {
    # Hand over: the host now lists an entry for the real session, and this local row's only
    # reason to exist is gone. Its text was already sent, so there is nothing to keep.
    $script:EntryData.Remove($key)
    Remove-EntryView $key
  }
  if ($id -ne '' -and $id -ne $key) {
    $script:EntryHold[$id] = $until
    if ($note -ne '') { Set-EntryNotice $id $note }
    Update-EntryCompose $id $script:EntryData[$id]
    return
  }
  if ($note -ne '') { Set-EntryNotice $key $note }
  Update-EntryCompose $key $script:EntryData[$key]
}

function Set-ElementPulse {
  param([string]$Name, $Element, [bool]$On, $Animation)
  if ($script:PulseOn[$Name] -eq $On) { return }
  $script:PulseOn[$Name] = $On
  if ($On) {
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $Animation)
  } else {
    # Taking the animation off puts the element back on its own value (1.0 -- nothing in the
    # XAML sets an Opacity), so a stopped breath is a perfectly steady element rather than one
    # frozen wherever the animation happened to be.
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $Element.Opacity = 1.0
  }
}

# Who breathes right now, decided from the last state document alone: the RING while the ball
# wears the 'still outputting' colour (`$script:Working` -- with an amber 'someone is waiting'
# or a red 'something errored' the ring stays steady, that one must not shimmer), and the HALO
# whenever any session is running (the host's `window.pulse`, the same boolean that lights it).
# Nothing breathes while the panel is open: the collapsed ball is hidden then, and an animation
# nobody can see would keep the layered window repainting.
function Update-BallPulse {
  $ballVisible = -not $script:Expanded
  Set-ElementPulse 'ring' $ballRing ($ballVisible -and $script:Working) $script:RingBreath
  Set-ElementPulse 'glow' $ballGlow ($ballVisible -and $script:Pulse) $script:GlowBreath
}

function Apply-State {
  param($State)

  $script:State = $State
  $script:HasState = $true
  $status = Get-ChildValue $State 'status' @{}
  $windowState = Get-ChildValue $State 'window' @{}

  $script:Pulse = [bool](Get-ChildValue $windowState 'pulse' $false)
  $statusKey = [string](Get-ChildValue $status 'key' '')
  $statusColor = [string](Get-ChildValue $status 'color' '#FF5B8DEF')
  # [local patch 2026-11-03] the pending-approval state reads amber (the same warm orange as
  # "asking"), so "waiting for you" is one colour family; red stays reserved for errors.
  if ([string](Get-ChildValue $status 'key' '') -eq 'approval') { $statusColor = '#FFE0A64B' }
  $script:Working = ($statusKey -eq 'working')

  # The turn signal: the colour above carries 'something is still outputting' (`working`), and
  # these two booleans say what should be breathing (see Update-BallPulse). Both are read off
  # THIS document, so the ball never has to guess when a turn ended -- the day the last session
  # stops outputting, the ring goes back to the idle grey and the halo stops breathing.
  #
  # HOSTS OLDER THAN v7 (the version is in the document, so this is version negotiation, not a
  # guess): back then "a session is still outputting" had no colour of its own -- such a host
  # sends the idle grey and mentions the count only in the label (the label itself is written by
  # the host, in its own language). Painting the accent blue here
  # makes the colour half of the turn signal work against that host as well; a v7 host sends
  # `working` with that same blue (STATUS_STYLES in mirror.ts), so its colour always wins and
  # this branch is dead. It only ever fires when the host has nothing to say about the state --
  # an amber 'someone is waiting for you' or a red 'something errored' is left exactly as sent.
  if ($script:Pulse -and -not $script:Working -and ($statusKey -eq '' -or $statusKey -eq 'idle') -and
      [int](Get-ChildValue $State 'v' 0) -lt 7) {
    $script:Working = $true
    $statusColor = $AccentBlue
  }

  $statusDot.Fill = ConvertTo-ColorBrush $statusColor
  if ($null -ne $statusDotGlow) { $statusDotGlow.Fill = ConvertTo-ColorBrush $statusColor }
  $ballRing.Stroke = ConvertTo-ColorBrush $statusColor
  $statusLabel.Text = [string](Get-ChildValue $status 'label' '')
  $ballGlow.Visibility = Get-Visibility $script:Pulse
  Update-BallPulse

  $metaLabel.Text = [string](Get-ChildValue $State 'meta' '')
  $footerText.Text = [string](Get-ChildValue $State 'footer' '')
  # The idle hint ("drag the panel ... press '-' to collapse") has done its job once the
  # panel has been opened. Keep real notices and hide exactly that line: the host sends the
  # hint as the footerIdle label, so it is recognised without hard-coding its text.
  $idleHint = Get-Label 'footerIdle' ''
  if ($footerText.Text -ne '' -and $idleHint -ne '' -and $footerText.Text -eq $idleHint) {
    $footerText.Visibility = 'Collapsed'
  } else {
    $footerText.Visibility = 'Visible'
  }

  $windowOpacity = [double](Get-ChildValue $windowState 'opacity' 0.94)
  if ($windowOpacity -lt 0.15) { $windowOpacity = 0.15 }
  if ($windowOpacity -gt 1) { $windowOpacity = 1 }
  $window.Opacity = $windowOpacity

  $visible = [bool](Get-ChildValue $windowState 'visible' $true)
  if ($visible) {
    if (-not $window.IsVisible) { $window.Show() }
  } else {
    if ($window.IsVisible) { $window.Hide() }
  }

  # (The halo's visibility and its breath were set above, next to the status colour: the two
  # together ARE the turn signal, and they are read off one document in one place.)

  $badge = [int](Get-ChildValue $State 'pendingCount' 0)
  if ($badge -gt 0) {
    $ballBadgeText.Text = [string]$badge
    $ballBadge.Visibility = 'Visible'
  } else {
    $ballBadge.Visibility = 'Collapsed'
  }

  # CONTENT FIRST, SHAPE SECOND -- one size per state document: everything that can change
  # how tall the panel wants to be (the entries, the cards inside them, the meta line, the
  # footer notice) is written first, and only then is the shape decided, so the window is
  # given one size and not two.

  Update-CreateButton
  Sync-Entries $State
  Apply-SendResult
  # Every row's lock is decided from the document that was just written (the host's own
  # per-entry flag) plus the local hold, and the receipt above may have changed both: this is
  # the one place that decides it, so the very first document paints the labels too.

  Update-AllEntryCompose
  Update-Countdowns

  $pingSeq = [int](Get-ChildValue $State 'pingSeq' 0)
  $soundEnabled = [bool](Get-ChildValue $State 'soundEnabled' $true)
  if ($script:LastPingSeq -lt 0) {
    $script:LastPingSeq = $pingSeq
  } elseif ($pingSeq -ne $script:LastPingSeq) {
    $script:LastPingSeq = $pingSeq
    if ($soundEnabled) {
      try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
  }

  # The shape: it measures the content written above, so an expand lands on its final size in
  # one step. Already expanded means Apply-PanelHeight -- a no-op when the height did not change.

  $wantExpanded = [bool](Get-ChildValue $windowState 'expanded' $false)
  if ($wantExpanded -ne $script:Expanded) {
    Apply-Shape $wantExpanded
  } elseif ($wantExpanded) {
    Apply-PanelHeight
  } else {
    Sync-BallSize
  }

  if (-not $script:Dragging) {
    $posX = Get-ChildValue $windowState 'x' $null
    $posY = Get-ChildValue $windowState 'y' $null
    if ($null -ne $posX -and $null -ne $posY -and -not $script:UserMoved) {
      $window.Left = [double]$posX
      $window.Top = [double]$posY
      # The remembered position is a point for the COLLAPSED ball, and it is applied while the
      # panel may already be open, so it goes through the same clamp as every other move --
      # dropping it in unclamped can push an auto-expanded panel past the screen edge.

      Move-IntoVirtualScreen
      # And since the remembered point IS the collapsed ball's spot, an open panel
      # has to remember it too: otherwise collapsing would send the ball back to
      # wherever it happened to sit before this state arrived.
      if ($script:Expanded) { $script:CollapsedAnchor = @{ Left = $window.Left; Top = $window.Top } }
    }
  }
}

# ---------------------------------------------------------------------------
# Mouse: drag the ball, click to expand
# ---------------------------------------------------------------------------

# Physical cursor position. The drag handler must NOT derive this from
# PointToScreen(e.GetPosition($window)): the window is moving while the pointer is captured, so
# the two calls inside that expression see different window origins and the resulting point
# jitters by tens of pixels. GetCursorPos is absolute and unaffected by our own window moves.
function Get-DragPoint {
  $nativePoint = New-Object DshBall.Native+NativePoint
  if (-not [DshBall.Native]::GetCursorPos([ref]$nativePoint)) {
    return $window.PointToScreen([System.Windows.Input.Mouse]::GetPosition($window))
  }
  return New-Object System.Windows.Point($nativePoint.X, $nativePoint.Y)
}

$ballView.Add_MouseLeftButtonDown({
  param($sender, $e)
  try {
    $script:Dragging = $true
    $script:DragMoved = $false
    $script:UserMoved = $true
    Write-BallDebug ('ball mouse down at ' + [math]::Round($e.GetPosition($window).X) + ',' + [math]::Round($e.GetPosition($window).Y))
    # PointToScreen returns DEVICE pixels, Window.Left/Top are DIP. At 125% scaling the pointer
    # travels 125 device pixels while the window only needs 100 DIP, so using the raw delta made
    # the ball fall behind by a fifth of the drag -- and the gap kept growing the further you
    # dragged. Convert with the window's DPI scale, sampled at drag start (a drag that crosses a
    # monitor with another scaling keeps one consistent factor for that drag).
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $script:DragScaleX = [math]::Max(0.1, $dpi.DpiScaleX)
    $script:DragScaleY = [math]::Max(0.1, $dpi.DpiScaleY)
    $point = Get-DragPoint
    $script:DragStart = @{ X = $point.X; Y = $point.Y; Left = $window.Left; Top = $window.Top }
    Write-BallDebug ('drag start at ' + [math]::Round($point.X) + ',' + [math]::Round($point.Y) +
      ' window ' + [math]::Round($window.Left) + ',' + [math]::Round($window.Top) +
      ' dpi ' + [string]$script:DragScaleX)
    [void]$ballView.CaptureMouse()
  } catch {
    Write-BallLog ('drag start failed: ' + $_.Exception.Message)
  }
})

$window.Add_MouseMove({
  param($sender, $e)
  try {
    if (-not $script:Dragging) { return }
    $point = Get-DragPoint
    $dx = ($point.X - $script:DragStart.X) / $script:DragScaleX
    $dy = ($point.Y - $script:DragStart.Y) / $script:DragScaleY
    if ($env:DSH_BALL_DEBUG -eq '1') {
      Write-BallDebug ('drag move point=' + [math]::Round($point.X) + ',' + [math]::Round($point.Y) +
        ' dx=' + [math]::Round($dx, 2) + ',' + [math]::Round($dy, 2) +
        ' scale=' + [string]$script:DragScaleX + ' left=' + [math]::Round($window.Left, 2) + ' top=' + [math]::Round($window.Top, 2))
    }
    if ([math]::Abs($dx) -gt 3 -or [math]::Abs($dy) -gt 3) { $script:DragMoved = $true }
    if ($script:DragMoved) {
      $window.Left = $script:DragStart.Left + $dx
      $window.Top = $script:DragStart.Top + $dy
    }
  } catch {
    Write-BallLog ('drag move failed: ' + $_.Exception.Message)
  }
})

$window.Add_MouseLeftButtonUp({
  param($sender, $e)
  try {
    Write-BallDebug ('mouse up dragging=' + [string]$script:Dragging + ' moved=' + [string]$script:DragMoved)
    if (-not $script:Dragging) { return }
    $script:Dragging = $false
    [void]$ballView.ReleaseMouseCapture()
    [void]$panelView.ReleaseMouseCapture()
    if ($script:DragMoved) {
      # Keep the window on the virtual desktop: a panel dragged half off the edge has its header
      # and collapse button out of reach, and the position reported to the host is the one
      # after this clamp, so a restart lands on a visible spot.

      Move-IntoVirtualScreen
      # While expanded, what the host remembers is the position of the small BALL,
      # so report the corner the collapsed ball would occupy (the panel's
      # top-right), never the panel's own top-left: otherwise the next start drops
      # the ball one panel-width away from where it was.
      $left = $window.Left
      if ($script:Expanded) { $left = $window.Left + $window.Width - (Get-BallWindowSize) }
      Send-Action ([ordered]@{ kind = 'pos'; x = [math]::Round($left, 1); y = [math]::Round($window.Top, 1) })
      # Dragging the panel IS choosing where the ball lives: keep the remembered
      # anchor in step so collapsing returns to this very corner.
      if ($script:Expanded) { $script:CollapsedAnchor = @{ Left = $left; Top = $window.Top } }
    } elseif ($script:Expanded -eq $false) {
      Apply-Shape $true
      Send-Action ([ordered]@{ kind = 'expanded'; expanded = $true })
    }
  } catch {
    Write-BallLog ('drag end failed: ' + $_.Exception.Message)
  }
})

# The EXPANDED panel is draggable too, from anywhere that is not a control: the header,
# the meta line, the footer, the empty part of the body, a card's own padding.
#
# The handler sits on the panel Border because it is hit-testable everywhere, while buttons
# and text boxes mark their own mouse-down as handled and therefore never reach it. The 3px
# threshold in the move handler keeps a sloppy click from moving anything.

$panelView.Add_MouseLeftButtonDown({
  param($sender, $e)
  try {
    $script:Dragging = $true
    $script:DragMoved = $false
    $script:UserMoved = $true
    Write-BallDebug ('panel mouse down at ' + [math]::Round($e.GetPosition($window).X) + ',' + [math]::Round($e.GetPosition($window).Y))
    # Same DEVICE -> DIP conversion as the ball's drag (see the ball handler above).
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $script:DragScaleX = [math]::Max(0.1, $dpi.DpiScaleX)
    $script:DragScaleY = [math]::Max(0.1, $dpi.DpiScaleY)
    $point = Get-DragPoint
    $script:DragStart = @{ X = $point.X; Y = $point.Y; Left = $window.Left; Top = $window.Top }
    [void]$panelView.CaptureMouse()
  } catch {
    Write-BallLog ('panel drag start failed: ' + $_.Exception.Message)
  }
})
$collapseButton.Add_Click({
  param($sender, $e)
  try {
    Collapse-Panel
  } catch {
    Write-BallLog ('collapse failed: ' + $_.Exception.Message)
  }
})

# ---------------------------------------------------------------------------
# The "+" button's workspace picker
# ---------------------------------------------------------------------------

# Open on the button's Click, exactly like a real ComboBox: toggling from a mouse-DOWN does
# not work with StaysOpen=False -- the popup captures the mouse during the press, so the
# mouse-up of that same click reads as 'up outside' and closes the list again about 30ms
# later. From a Click the press is already over.

$createButton.Add_Click({
  param($sender, $e)
  try {
    Toggle-CreatePopup
  } catch {
    Write-BallLog ('workspace picker failed: ' + $_.Exception.Message)
  }
})

# Dismissal is deliberately left to WPF's own StaysOpen=False: the popup closes on a click
# outside it, on the button's own toggle and on the row click. Do NOT add an 'outside' test
# on top of that: in this non-activated window the popup does not always hold the mouse, so
# such a test also fires for a click that landed ON a row and swallows the choice it was
# meant to help with.

# Our own popup is a window of its own: while it is open it may hold the foreground, which is
# not the user walking away. On close, take the foreground back so a box that was holding the
# keyboard still has it.
$createPopup.Add_Closed({
  try {
    Write-BallDebug 'workspace picker closed (event)'
    if ($script:KeyboardActive) {
      $script:ComposeReassertUntil = (Get-NowMs) + 500
      $script:ComposeRetries = 0
      Invoke-ReassertFocus
    }
  } catch { }
})

# ---------------------------------------------------------------------------
# The panel's own events
# ---------------------------------------------------------------------------
#
# There is deliberately NOTHING here for the boxes: every box belongs to one entry, is built
# with it (see New-EntryView) and goes away with it, so its handlers are wired where it is
# born. The only panel-wide handlers left are the ones below.

# Clicking anywhere else (another app, the desktop) ends keyboard mode. No need to
# give the foreground back: the user already moved on by themselves. Inside the
# grace window this is not that yet: it is Windows undoing our activation right
# after the click, and Assert-KeyboardFocus takes it back.
$window.Add_Deactivated({
  try {
    if (-not $script:KeyboardActive) { return }
    if ($createPopup.IsOpen) {
      Write-BallDebug 'deactivated while the picker is open; keeping keyboard mode'
      return
    }
    $now = Get-NowMs
    if ($now -lt $script:ComposeReassertUntil) {
      Write-BallDebug 'deactivated within the grace window; keeping keyboard mode'
      return
    }
    Exit-KeyboardMode -RestoreForeground $false
  } catch { }
})

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$pollTimer.Add_Tick({
  try {
    Assert-KeyboardFocus
    # Compare the document itself rather than file metadata: a Get-Item handle
    # would be one more thing that can collide with the host's publishing. A
    # half-written file simply fails to parse and is retried on the next tick.
    $path = Get-NewestStatePath
    if ($null -eq $path) { return }
    $raw = Read-StateText $path
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    if ($raw -eq $script:RawState) { return }
    $document = $null
    try {
      $document = ConvertFrom-Json -InputObject $raw
    } catch {
      return
    }
    # The document counts as seen even if applying it fails: without this, a single
    # bad document is retried on every 120ms tick forever, so the ball freezes on
    # it and nothing after it is ever shown (measured: 1261 identical failures in
    # five minutes, and a panel stuck at the wrong size).
    try {
      Apply-State $document
    } finally {
      $script:RawState = $raw
    }
  } catch {
    Write-BallLog ('poll failed: ' + $_.Exception.Message)
  }
})

$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$clockTimer.Add_Tick({
  try {
    # The theme can change while the ball is up (the user switches DSH light/dark): this
    # process has one palette baked into its XAML templates, so it hangs up and lets the host
    # start a fresh ball -- the host notices the child is gone and respawns it within ~2s.

    $nowMs = Get-NowMs
    # No state document has painted the shape yet (the window came up invisible for exactly
    # that reason). If the host stays silent -- it is gone, or the profile is half-loaded --
    # show the ball with the fallback shape instead of leaving an invisible window behind.
    if (-not $script:HasState -and $nowMs -gt ($script:BootMs + 2500)) {
      $script:HasState = $true
      Write-BallLog 'no state document after 2.5s; showing the ball with the fallback shape'
      Apply-Shape $false
      Set-DefaultPosition
      $window.Opacity = 0.96
    }
    if ($nowMs -ge $script:NextThemeCheck) {
      $script:NextThemeCheck = $nowMs + 3000
      $themeNow = Get-DshThemeKey
      if ($themeNow -ne $script:ThemeKey) {
        Write-BallLog ('theme changed (' + $script:ThemeKey + ' -> ' + $themeNow + '); restarting the ball')
        $window.Close()
        return
      }
    }
    # Two things run out on their own and no state document will announce them: the local hold
    # after a send (so the box unlocks by itself) and a row's own notice line. Both are
    # re-decided here, not only when a document arrives.
    Update-AllEntryCompose
    foreach ($key in @($script:EntryOrder)) { Apply-EntryNotice $key }
    if ($script:Expanded) {
      # Only the countdowns need a clock: nothing else on the panel changes with time.
      # A countdown line appearing or expiring changes the height of its card, and
      # therefore of the panel.
      Update-Countdowns
      Apply-PanelHeight
    }
    # The topmost watchdog, on the same clock but throttled: walking the z-order is
    # a handful of cheap calls, yet there is no reason to do it twice a second. This
    # is what keeps "the ball disappeared" from being permanent -- see
    # Assert-BallTopmost for what it is recovering from.
    $now = Get-NowMs
    if ($now -ge $script:NextTopmostCheck) {
      $script:NextTopmostCheck = $now + 1500
      Assert-BallTopmost
    }
    if ($ParentPid -gt 0) {
      $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
      if ($null -eq $parent) {
        Write-BallLog 'parent process is gone; closing'
        $window.Close()
      }
    }
  } catch { }
})

$window.Add_SourceInitialized({
  $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
  $script:Hwnd = $helper.Handle
  Update-WindowStyles
})

# A throwing handler must never take the whole ball down: without this, one bad
# click handler ends the process and the overlay silently disappears.
$window.Dispatcher.Add_UnhandledException({
  param($sender, $e)
  Write-BallLog ('unhandled exception: ' + $e.Exception.ToString())
  $e.Handled = $true
})

$window.Add_Closed({
  $pollTimer.Stop()
  $clockTimer.Stop()
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# Do NOT paint the ball before the first state document. Apply-Shape with no state uses the
# plugin's fallback ballSize (64) while the Profile asks for 48: measured, the ball came up at
# 64 and snapped to 48 when the first document arrived, which reads as "it starts huge".
# The window is created, positioned and kept at opacity 0 here; Apply-State paints the shape
# from real data and sets window.Opacity in the same dispatcher turn, so the FIRST VISIBLE
# FRAME is already the right size. The clock timer has a 2.5s fallback for a silent host.
$script:BootMs = Get-NowMs
$window.Width = Get-BallWindowSize
$window.Height = Get-BallWindowSize
$window.Show()
$window.Opacity = 0
Apply-Shape $false
Set-DefaultPosition
Update-WindowStyles
Write-BallLog ('ball started (parent pid ' + [string]$ParentPid + ', debug=' + [string]$env:DSH_BALL_DEBUG +
  ', foreground=' + [string]([DshBall.Native]::GetForegroundWindow()) + ')' + ' script=' + $PSCommandPath)
Read-UnreadDone
$pollTimer.Start()
$clockTimer.Start()
[System.Windows.Threading.Dispatcher]::Run()
Write-BallLog 'ball stopped'