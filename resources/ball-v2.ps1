# dsh-floating-ball - ball + panel, clean-room rewrite (phase 2, S1 refined style).
#
# PURE ASCII. PowerShell 5.1 decodes a .ps1 without a BOM as the ANSI code page, so every display
# string (status label, entry titles, chip text, button labels) comes from the state JSON read
# explicitly as UTF-8. Do not add non-ASCII characters.
#
# Phase 1 was the ball. This file is the phase-2 panel in the S1 refined look: white panel,
# light-gray session cards, thin low-saturation status bars, a 13px title with a small chip, a
# muted question/hint line, light "wash" buttons, and NO footer (the old footer hint and the
# pending/running counters are gone by design). Section headers group entries as pending / unread /
# running; their labels arrive in the state document too.
#
# The window keeps the CURRENT plugin's geometry: panelWidth 320 (contents) with a 28px
# transparent rim for the drop shadow, max panel height 460, ball 48. Those numbers come from
# state.metrics, with the same values as defaults here.
#
# Production still runs resources/ball.ps1 until the host side is rewritten (2b) and the A/B
# comparison passes; this file is exercised through tools/preview-ball.ps1.
#
# State document (v9 protocol):
#   { v, status:{key,color,label}, running, pendingCount,
#     labels:{send,ack,sent,close,pending,running,unread,approval,question,error},
#     entries:[{key,target,title,chip,state,color,errorNote,hint,canAck,showInput,lock,cards:[...]}],
#     metrics:{ballSize,panelWidth,panelHeight}, window:{visible,expanded,opacity,x,y} }
# Actions written (act-<pid>-<seq>.json):
#   pos / expanded / prompt / approval / question / ack / close / new
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace DshBallV2 -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetCursorPos(out NativePoint point);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SetWindowLong(System.IntPtr hWnd, int index, int newStyle);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct NativePoint { public int X; public int Y; }
'@

$Preview = ($env:DSH_BALL_PREVIEW -eq '1')
$StateFileOverride = $env:DSH_BALL_STATE_FILE
$RuntimeDir = if ($env:DSH_BALL_RUNTIME_DIR) { $env:DSH_BALL_RUNTIME_DIR } else {
  Join-Path $env:LOCALAPPDATA 'dsh-session-ball\default'
}
$LogPath = if ($env:DSH_BALL_LOG) { $env:DSH_BALL_LOG } else { Join-Path $RuntimeDir 'ball-v2.log' }

function Write-BallLog {
  param([string]$Text)
  try {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' [ball-v2 ' + $PID + '] ' + $Text + "`r`n"
    [System.IO.File]::AppendAllText($LogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# --------------------------------------------------------------------------- XAML (ours)
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        ShowActivated="False" SizeToContent="Manual"
        WindowStartupLocation="Manual" Width="128" Height="128"
        Left="0" Top="0" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="FlatButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="SnapsToDevicePixels" Value="True" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="9" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.86" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.68" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="6" />
      <Setter Property="Background" Value="Transparent" />
    </Style>
  </Window.Resources>
  <Grid Name="Root" Background="Transparent" Width="128" Height="128">

    <Grid Name="BallView">
      <!-- Copied from the hand-tuned production ball (resources/ball.ps1): white blurred glow
           that only exists while a session is running, translucent blue body, sheen, a 2.5px
           status-coloured ring, and the same whale mark with its soft shadow and bubbles. -->
      <Ellipse Name="Glow" Fill="#3DFFFFFF" Margin="-7" Visibility="Collapsed">
        <Ellipse.Effect>
          <BlurEffect Radius="7" RenderingBias="Quality" />
        </Ellipse.Effect>
      </Ellipse>
      <Ellipse Name="Body">
        <Ellipse.Fill>
          <RadialGradientBrush GradientOrigin="0.34,0.28" Center="0.34,0.28" RadiusX="0.9" RadiusY="0.9">
            <GradientStop Color="#B86E8BFF" Offset="0.0" />
            <GradientStop Color="#993550D8" Offset="1.0" />
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Name="Sheen" Margin="5" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush GradientOrigin="0.3,0.24" Center="0.3,0.24" RadiusX="0.85" RadiusY="0.85">
            <GradientStop Color="#38FFFFFF" Offset="0.0" />
            <GradientStop Color="#00FFFFFF" Offset="1.0" />
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Name="Ring" StrokeThickness="2.5" Stroke="#FF5B8DEF" Margin="-1" />
      <Viewbox Name="Whale" Width="36" Height="36" HorizontalAlignment="Center" VerticalAlignment="Center"
               IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5">
        <Viewbox.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="WhaleFlip" ScaleX="1" ScaleY="1" />
            <RotateTransform x:Name="WhaleRotate" Angle="0" />
          </TransformGroup>
        </Viewbox.RenderTransform>
        <Canvas Width="110" Height="100">
          <Canvas Name="MarkShadow" IsHitTestVisible="False">
            <Canvas.RenderTransform>
              <TranslateTransform X="1.4" Y="1.9" />
            </Canvas.RenderTransform>
            <Path Data="M 4 50 C 4 33 16 21 34 19 C 47 17 57 21 63 28 C 69 34 73 38 77 36 C 85 27 94 17 101 10 C 97 26 89 38 81 45 C 90 47 99 51 105 57 C 97 62 86 60 79 55 C 73 65 61 70 48 70 C 32 70 16 64 8 58 C 5 55 4 52 4 50 Z">
              <Path.Fill><SolidColorBrush Color="#57274296" /></Path.Fill>
              <Path.Effect><BlurEffect Radius="3" RenderingBias="Quality" /></Path.Effect>
            </Path>
            <Path Data="M 36 63 C 32 75 38 85 50 89 C 48 81 46 73 44 67 Z">
              <Path.Fill><SolidColorBrush Color="#57274296" /></Path.Fill>
              <Path.Effect><BlurEffect Radius="3" RenderingBias="Quality" /></Path.Effect>
            </Path>
            <Path Data="M 58 23 C 56 12 63 6 71 8 C 67 14 65 20 63 27 Z">
              <Path.Fill><SolidColorBrush Color="#57274296" /></Path.Fill>
              <Path.Effect><BlurEffect Radius="3" RenderingBias="Quality" /></Path.Effect>
            </Path>
          </Canvas>
          <Path Fill="#F4FFFFFF" Data="M 4 50 C 4 33 16 21 34 19 C 47 17 57 21 63 28 C 69 34 73 38 77 36 C 85 27 94 17 101 10 C 97 26 89 38 81 45 C 90 47 99 51 105 57 C 97 62 86 60 79 55 C 73 65 61 70 48 70 C 32 70 16 64 8 58 C 5 55 4 52 4 50 Z" />
          <Path Fill="#F2FFFFFF" Data="M 36 63 C 32 75 38 85 50 89 C 48 81 46 73 44 67 Z" />
          <Path Fill="#F2FFFFFF" Data="M 58 23 C 56 12 63 6 71 8 C 67 14 65 20 63 27 Z" />
          <Ellipse Canvas.Left="19.6" Canvas.Top="41.6" Width="4.8" Height="4.8" Fill="#FF2F55B8" />
          <Canvas Name="MarkBubbles" IsHitTestVisible="False">
            <Ellipse Canvas.Left="82" Canvas.Top="9" Width="6.6" Height="6.6" Fill="#D9FFFFFF" />
            <Ellipse Canvas.Left="92" Canvas.Top="2" Width="4.2" Height="4.2" Fill="#99FFFFFF" />
            <Ellipse Canvas.Left="99" Canvas.Top="-3" Width="2.6" Height="2.6" Fill="#66FFFFFF" />
          </Canvas>
        </Canvas>
      </Viewbox>
      <Border Name="Badge" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Top"
              CornerRadius="10" MinWidth="18" Height="18" Margin="0,-3,-3,0" Background="#FFE0A64B">
        <TextBlock Name="BadgeText" Text="1" FontSize="11" FontWeight="Bold"
                   Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="5,0,5,0" />
      </Border>
    </Grid>

    <Border Name="PanelView" Visibility="Collapsed" CornerRadius="18" BorderThickness="1" BorderBrush="#FFECEFF4">
      <Border.Effect>
        <DropShadowEffect BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.14" Color="#0B1B4A" />
      </Border.Effect>
      <Border.Background>
        <SolidColorBrush Color="#F0FFFFFF" />
      </Border.Background>
      <Grid Margin="14,12,14,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto" />
          <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <Grid Name="PanelHeader" Grid.Row="0" Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto" />
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <Ellipse Name="StatusDot" Grid.Column="0" Width="9" Height="9" Fill="#FF5B8DEF"
                   VerticalAlignment="Center" Margin="0,0,8,0" />
          <TextBlock Name="StatusLabel" Grid.Column="1" FontSize="14" FontWeight="SemiBold"
                     Foreground="#FF1B1F27" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" />
          <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Border Name="PendingPill" Visibility="Collapsed" CornerRadius="8" Margin="0,0,6,0"
                    Background="#FFFDF1E2" BorderBrush="#FFF3D3A2" BorderThickness="1"
                    Padding="6,1,6,2" VerticalAlignment="Center">
              <TextBlock Name="PendingPillText" FontSize="11" Foreground="#FFD97706" />
            </Border>
            <Button Name="NewButton" Content="+" Style="{StaticResource FlatButton}" FontSize="14" Width="26" Height="26"
                    Background="#FFFFFFFF" Foreground="#FF8B94A3" BorderBrush="#FFECEFF4" BorderThickness="1"
                    Cursor="Hand" Padding="0" />
            <Button Name="CollapseButton" Content="-" Style="{StaticResource FlatButton}" FontSize="14" Width="26" Height="26"
                    Margin="6,0,0,0" Background="#FFFFFFFF" Foreground="#FF8B94A3"
                    BorderBrush="#FFECEFF4" BorderThickness="1" Cursor="Hand" Padding="0" />
          </StackPanel>
        </Grid>

        <ScrollViewer Name="BodyScroll" Grid.Row="1" Margin="0,10,0,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Name="BodyStack" />
        </ScrollViewer>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$root = $window.FindName('Root')
$ballView = $window.FindName('BallView')
# The ball is clickable (one click opens the panel / drag moves it): show the pointing-hand
# cursor while the pointer is over the ball instead of the default arrow.
$ballView.Cursor = [System.Windows.Input.Cursors]::Hand
$glow = $window.FindName('Glow')
$body = $window.FindName('Body')
$sheen = $window.FindName('Sheen')
$ring = $window.FindName('Ring')
$whale = $window.FindName('Whale')
$badge = $window.FindName('Badge')
$badgeText = $window.FindName('BadgeText')
$panelView = $window.FindName('PanelView')
$panelHeader = $window.FindName('PanelHeader')
$statusDot = $window.FindName('StatusDot')
$statusLabel = $window.FindName('StatusLabel')
$pendingPill = $window.FindName('PendingPill')
$pendingPillText = $window.FindName('PendingPillText')
$bodyScroll = $window.FindName('BodyScroll')
$bodyStack = $window.FindName('BodyStack')
$newButton = $window.FindName('NewButton')
$collapseButton = $window.FindName('CollapseButton')
$whaleRotate = $window.FindName('WhaleRotate')
if (($null -eq $whaleRotate) -and ($null -ne $whale) -and ($null -ne $whale.RenderTransform) -and ($whale.RenderTransform -is [System.Windows.Media.TransformGroup])) {
  foreach ($transform in $whale.RenderTransform.Children) {
    if ($transform -is [System.Windows.Media.RotateTransform]) { $whaleRotate = $transform }
  }
}
$bubbles = $window.FindName('MarkBubbles')
$script:BubblesBaseOpacity = 1.0
if ($null -ne $bubbles) { $script:BubblesBaseOpacity = $bubbles.Opacity }
$script:SwimTranslate = New-Object System.Windows.Media.TranslateTransform
if (($null -ne $whale) -and ($null -ne $whale.RenderTransform) -and ($whale.RenderTransform -is [System.Windows.Media.TransformGroup])) {
  [void]$whale.RenderTransform.Children.Add($script:SwimTranslate)
} elseif ($null -ne $whale) {
  $script:WhaleTransformGroup = New-Object System.Windows.Media.TransformGroup
  [void]$script:WhaleTransformGroup.Children.Add($script:SwimTranslate)
  $whale.RenderTransform = $script:WhaleTransformGroup
}
$script:FirstShape = $true
$script:SwimStoryboard = $null
$script:Swimming = $false

# UI font. The DEFAULT is the production ball stack from the XAML above
# ("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI"): Latin from Segoe, Chinese from the system CJK face.
#
# The bundled Inter subset (assets/fonts/DshUiSans*) is only applied when DSH_BALL_FONT_FAMILY is
# set: it has no CJK glyphs, so Windows falls back to a different Chinese face and the mixed result
# looked worse than the system stack. It stays available for the font-comparison previews.
$fontOverride = $env:DSH_BALL_FONT_FAMILY
if ($fontOverride) {
  try {
    $window.FontFamily = New-Object System.Windows.Media.FontFamily $fontOverride
    Write-BallLog ('font: override ' + $fontOverride)
  } catch { Write-BallLog ('font override failed: ' + $_.Exception.Message) }
}

$script:State = $null
$script:BallSize = 48
$script:PanelWidth = 320
$script:PanelHeight = 460
$script:Expanded = $false
$script:UserMoved = $false
$script:Dragging = $false
$script:DragMoved = $false
$script:DragPoint = $null
$script:DragStart = $null
$script:ActionSeq = 0
$script:Working = $false
$script:Pulse = $false
$script:Entries = @{}
$script:EntryOrder = New-Object System.Collections.ArrayList
$script:PrevStates = @{}
$script:Unread = @{}
$script:SectionViews = @{}
$script:CardAnswerState = @{}
$script:EntryHashes = @{}
$script:LayoutSignature = ''
$script:ContentDirty = $false
# Display strings come from the state document; these are ASCII fallbacks.
$script:Labels = @{
  send = 'Send'; ack = 'Got it'; sent = 'Sent, waiting for the session...'; close = 'x'; placeholder = 'Write a line...'
  answer = 'Answer'; answerIncomplete = 'Answer every question first'; customAnswer = 'Or type your own answer...'
  next = 'Next'; prev = 'Back'; submit = 'Submit'
  pending = 'Pending'; running = 'Running'; unread = 'Unread'
  approval = 'Approval'; question = 'Question'; error = 'Error'
}

function Apply-FlatStyle {
  param($Button)
  try { $Button.Style = $window.FindResource('FlatButton') } catch { }
  return $Button
}

function ConvertTo-Brush {
  param([string]$Hex, [string]$Fallback = '#FF5B8DEF')
  try { return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)) }
  catch { return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Fallback)) }
}

# A soft version of a status color for the 2px bar: same hue, 40% alpha.
function ConvertTo-SoftBrush {
  param([string]$Hex, [string]$Fallback = '#FFD8DEE9')
  try {
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $soft = [System.Windows.Media.Color]::FromArgb(0x66, $color.R, $color.G, $color.B)
    return New-Object System.Windows.Media.SolidColorBrush $soft
  } catch {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Fallback))
  }
}

$script:LastRawState = $null
function Read-BallStateRaw {
  if ($StateFileOverride) {
    try { return [System.IO.File]::ReadAllText($StateFileOverride, [System.Text.Encoding]::UTF8) }
    catch { return $null }
  }
  try {
    $files = @(Get-ChildItem -LiteralPath $RuntimeDir -Filter 'state-*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $null }
    $best = $null; $bestN = -1
    foreach ($file in $files) {
      $m = [regex]::Match($file.Name, '^state-(\d+)\.json$')
      if (-not $m.Success) { continue }
      $n = [int]$m.Groups[1].Value
      if ($n -gt $bestN) { $bestN = $n; $best = $file }
    }
    if ($null -eq $best) { return $null }
    return [System.IO.File]::ReadAllText($best.FullName, [System.Text.Encoding]::UTF8)
  } catch { return $null }
}

function Write-BallAction {
  param([hashtable]$Action)
  if ($Preview) { Write-BallLog ('action (preview, not written): ' + (ConvertTo-Json -Compress -InputObject $Action)); return }
  try {
    $script:ActionSeq++
    $Action['seq'] = $script:ActionSeq
    $json = ConvertTo-Json -Compress -InputObject $Action
    $file = Join-Path $RuntimeDir ('act-' + $PID + '-' + $script:ActionSeq + '.json')
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { Write-BallLog ('action failed: ' + $_.Exception.Message) }
}

# Breathing is copied from the production ball: the RING (2.5px, status colour) breathes while a
# session is running, and the white GLOW only exists while a session is running (it breathes
# 0.35..1.0). With nothing running there is no glow at all - that was the "weird halo when idle"
# in the first cut of this file.
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

$script:RingBreath = New-BreathAnimation 0.55
$script:GlowBreath = New-BreathAnimation 0.35
$script:PulseOn = @{ ring = $false; glow = $false }

function Set-ElementPulse {
  param([string]$Name, $Element, [bool]$On, $Animation)
  if ($script:PulseOn[$Name] -eq $On) { return }
  $script:PulseOn[$Name] = $On
  if ($On) {
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $Animation)
  } else {
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $Element.Opacity = 1.0
  }
}

# Hovering the ball makes the deepseek whale "swim": it rocks around its centre, bobs a little and
# the bubbles pulse. Everything is a GPU opacity/transform animation - no layout work on the UI thread.
function Start-Swim {
  if ($Preview -or $script:Swimming) { return }
  if ($null -eq $whaleRotate) { return }
  $script:Swimming = $true
  # Animate the transforms directly. A Storyboard with SetTarget() silently does nothing for these
  # Freezable targets under PowerShell, so the whale never actually moved.
  $rotate = New-Object System.Windows.Media.Animation.DoubleAnimation
  $rotate.From = -6.0
  $rotate.To = 6.0
  $rotate.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(620))
  $rotate.AutoReverse = $true
  $rotate.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $rotate.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  $whaleRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $rotate)
  if ($null -ne $script:SwimTranslate) {
    $bob = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bob.From = -1.6
    $bob.To = 1.6
    $bob.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(520))
    $bob.AutoReverse = $true
    $bob.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $bob.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    $script:SwimTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $bob)
  }
  if ($null -ne $bubbles) {
    $bubble = New-Object System.Windows.Media.Animation.DoubleAnimation
    $bubble.From = 0.45
    $bubble.To = 1.0
    $bubble.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(900))
    $bubble.AutoReverse = $true
    $bubble.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $bubbles.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $bubble)
  }
}

function Stop-Swim {
  if (-not $script:Swimming) { return }
  $script:Swimming = $false
  if ($null -ne $script:SwimStoryboard) {
    try { $script:SwimStoryboard.Stop() } catch { }
    $script:SwimStoryboard = $null
  }
  if ($null -ne $whaleRotate) {
    $whaleRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $whaleRotate.Angle = 0.0
  }
  if ($null -ne $script:SwimTranslate) {
    $script:SwimTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $script:SwimTranslate.Y = 0.0
  }
  if ($null -ne $bubbles) {
    $bubbles.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $bubbles.Opacity = $script:BubblesBaseOpacity
  }
}

function Update-BallPulse {
  $ballVisible = ($ballView.Visibility -eq 'Visible') -and (-not $script:Expanded)
  Set-ElementPulse 'ring' $ring ($ballVisible -and $script:Working) $script:RingBreath
  Set-ElementPulse 'glow' $glow ($ballVisible -and $script:Pulse) $script:GlowBreath
  if ($ballVisible -and $script:Pulse) { $glow.Visibility = 'Visible' } else { $glow.Visibility = 'Collapsed' }
}
$script:BallHwnd = [IntPtr]::Zero
$script:NoActivateOn = $false

function Get-BallHwnd {
  if ($script:BallHwnd -ne [IntPtr]::Zero) { return $script:BallHwnd }
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $script:BallHwnd = $helper.Handle
  } catch { $script:BallHwnd = [IntPtr]::Zero }
  return $script:BallHwnd
}

# WS_EX_NOACTIVATE: clicks go straight to the button instead of first activating the window.
# A text box needs the keyboard, so focus temporarily drops the style and activates the window.
function Set-BallNoActivate {
  param([bool]$On)
  $hwnd = Get-BallHwnd
  if ($hwnd -eq [IntPtr]::Zero) { return }
  $NOACTIVATE = 0x08000000
  $TOOLWINDOW = 0x00000080
  $style = [DshBallV2.Native]::GetWindowLong($hwnd, -20)
  if ($On) { $style = $style -bor $NOACTIVATE -bor $TOOLWINDOW }
  else { $style = $style -band (-bnot $NOACTIVATE) }
  [void][DshBallV2.Native]::SetWindowLong($hwnd, -20, $style)
  $script:NoActivateOn = $On
}

function Enable-BallKeyboard {
  Set-BallNoActivate $false
  try { $window.Activate() } catch { }
  try { [void][DshBallV2.Native]::SetForegroundWindow((Get-BallHwnd)) } catch { }
}

function Disable-BallKeyboard { Set-BallNoActivate $true }

# WS_EX_NOACTIVATE stops Windows from activating the window, but WPF still answers WM_MOUSEACTIVATE
# with MA_ACTIVATE by default and then the click is swallowed by the failed activation - that is the
# "first click after the panel is up needs several clicks" bug. Answering the message with
# MA_NOACTIVATE (3) passes the click straight to the control underneath.
$script:HwndHook = $null
function Install-BallMouseActivateHook {
  $hwnd = Get-BallHwnd
  if ($hwnd -eq [IntPtr]::Zero) { return }
  try {
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
    if ($null -eq $source) { return }
    if ($null -ne $script:HwndHook) { return }
    $script:HwndHook = [System.Windows.Interop.HwndSourceHook]{
      param($hWnd, $msg, $wParam, $lParam, [ref]$handled)
      if ($msg -eq 0x0021) {
        $handled.Value = $true
        return [IntPtr]3
      }
      return [IntPtr]::Zero
    }
    $source.AddHook($script:HwndHook)
    Write-BallLog ("mouse activate hook installed (MA_NOACTIVATE)")
  } catch { Write-BallLog ("mouse activate hook failed: " + $_.Exception.Message) }
}

function Get-CursorPoint {
  $point = New-Object DshBallV2.Native+NativePoint
  if ([DshBallV2.Native]::GetCursorPos([ref]$point)) { return New-Object System.Windows.Point($point.X, $point.Y) }
  return New-Object System.Windows.Point($window.Left, $window.Top)
}

function Get-DpiScale {
  try {
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    return @{ X = [math]::Max(0.1, $dpi.DpiScaleX); Y = [math]::Max(0.1, $dpi.DpiScaleY) }
  } catch { return @{ X = 1.0; Y = 1.0 } }
}

# --------------------------------------------------------------------------- panel sizing
function Reset-Measure {
  param($Element)
  if ($Element -is [System.Windows.UIElement]) { $Element.InvalidateMeasure() }
  $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
  for ($index = 0; $index -lt $count; $index++) {
    Reset-Measure ([System.Windows.Media.VisualTreeHelper]::GetChild($Element, $index))
  }
}

function Measure-PanelHeight {
  # An explicit Height would be measured as-is, so content changes would never move the panel.
  $panelView.Height = [double]::NaN
  $panelView.Width = $script:PanelWidth
  Reset-Measure $panelView
  $panelView.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
  $desired = $panelView.DesiredSize.Height
  if ($desired -lt 96) { $desired = 96 }
  if ($desired -gt $script:PanelHeight) { $desired = $script:PanelHeight }
  return [math]::Ceiling($desired)
}

# Keep the whole window inside the virtual desktop (the union of every monitor), exactly like the
# production ball. The window keeps a transparent rim around the ball/panel (25px / 16px), so
# clamping the window to the screen edge still leaves the visible ball a few pixels away from it.
# First launch (no remembered position from the host): park the ball on the right side of the
# work area, vertically centred. The work area excludes the taskbar, so "centred" looks centred.
# Default placement for the panel shape (only used when the panel is open on the very first state
# and the host has no remembered point): right side of the work area, vertically centred.
function Set-DefaultPanelPosition {
  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - $window.Width - 12
  $window.Top = $work.Top + (($work.Height - $window.Height) / 2)
  [void](Move-IntoVirtualScreen)
  $script:CollapsedAnchor = @{ Left = ($window.Left + $window.Width - ($script:BallSize + 50)); Top = $window.Top }
  Write-BallLog ("default panel position " + [math]::Round($window.Left) + "," + [math]::Round($window.Top))
}

function Test-HostPositionUsable([double]$left, [double]$top) {
  $work = [System.Windows.SystemParameters]::WorkArea
  $tolerance = 8.0
  if ($left -lt ($work.Left - $tolerance)) { return $false }
  if ($top -lt ($work.Top - $tolerance)) { return $false }
  $size = $script:BallSize + 50
  if (($left + $size) -gt ($work.Right + $tolerance)) { return $false }
  if (($top + $size) -gt ($work.Bottom + $tolerance)) { return $false }
  return $true
}

function Set-DefaultBallPosition {
  $size = $script:BallSize + 50
  $work = [System.Windows.SystemParameters]::WorkArea
  $left = $work.Right - $size - 12
  $top = $work.Top + (($work.Height - $size) / 2)
  $window.Left = $left
  $window.Top = $top
  Write-BallLog ("default position " + [math]::Round($left) + "," + [math]::Round($top))
}

function Get-ScreenClamped([double]$left, [double]$top) {
  $minX = [System.Windows.SystemParameters]::VirtualScreenLeft
  $minY = [System.Windows.SystemParameters]::VirtualScreenTop
  $maxX = $minX + [System.Windows.SystemParameters]::VirtualScreenWidth - $window.Width
  $maxY = $minY + [System.Windows.SystemParameters]::VirtualScreenHeight - $window.Height
  if ($maxX -lt $minX) { $maxX = $minX }
  if ($maxY -lt $minY) { $maxY = $minY }
  $x = $left
  $y = $top
  if ($x -lt $minX) { $x = $minX }
  if ($y -lt $minY) { $y = $minY }
  if ($x -gt $maxX) { $x = $maxX }
  if ($y -gt $maxY) { $y = $maxY }
  return @{ Left = $x; Top = $y }
}

function Move-IntoVirtualScreen {
  $clamped = Get-ScreenClamped $window.Left $window.Top
  $moved = ([math]::Abs($window.Left - $clamped.Left) -gt 0.5) -or ([math]::Abs($window.Top - $clamped.Top) -gt 0.5)
  $window.Left = $clamped.Left
  $window.Top = $clamped.Top
  return $moved
}

# A short fade after every shape change. The single-window architecture cannot avoid one composited
# frame while the window is resized; a ~110ms fade makes that frame invisible (and reads as an
# intentional open/close animation instead of a flash).
$script:CrossFade = $null
$script:ClosingAnchor = $null

# The ball and the panel live in one window, so opening/closing is an instant content swap. A
# cross-fade (ball fades out while the panel fades in, and the reverse on close) is what makes
# that swap read as an expand/collapse animation instead of a flash.
function Set-BallViewInWindow {
  param([double]$screenLeft, [double]$screenTop, [double]$size)
  $ballView.HorizontalAlignment = 'Left'
  $ballView.VerticalAlignment = 'Top'
  $ballView.Width = $size
  $ballView.Height = $size
  $ballView.Margin = New-Object System.Windows.Thickness -ArgumentList @(($screenLeft - $window.Left), ($screenTop - $window.Top), 0, 0)
}

function Reset-BallViewLayout {
  $ballView.HorizontalAlignment = 'Center'
  $ballView.VerticalAlignment = 'Center'
  $ballView.Width = [double]::NaN
  $ballView.Height = [double]::NaN
  $ballView.Margin = New-Object System.Windows.Thickness -ArgumentList 0
}

function Stop-CrossFade {
  if ($null -eq $script:CrossFade) { return }
  try { $script:CrossFade.Stop() } catch { }
  $script:CrossFade = $null
  $ballView.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  $panelView.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
}

function Complete-CrossFade {
  $script:CrossFade = $null
  if ($script:CrossFadeOpening) {
    $ballView.Visibility = 'Collapsed'
    $ballView.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ballView.Opacity = 1.0
    $panelView.Opacity = 1.0
  } else {
    $ballSize = $script:BallSize
    $window.Width = $ballSize + 50
    $window.Height = $ballSize + 50
    $root.Width = $window.Width
    $root.Height = $window.Height
    if ($null -ne $script:ClosingAnchor) {
      $window.Left = [double]$script:ClosingAnchor['Left']
      $window.Top = [double]$script:ClosingAnchor['Top']
    }
    $panelView.Visibility = 'Collapsed'
    $panelView.Opacity = 1.0
    $ballView.Visibility = 'Visible'
    Reset-BallViewLayout
    $ballView.Opacity = 1.0
    $script:CollapsedAnchor = $null
$script:FirstPositionPending = $true
    [void](Move-IntoVirtualScreen)
  }
}

function Start-CrossFade {
  param([bool]$Opening)
  Stop-CrossFade
  $script:CrossFadeOpening = $Opening
  $duration = 130
  $ballAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
  $panelAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
  if ($Opening) {
    $ballAnim.From = 1.0; $ballAnim.To = 0.0
    $panelAnim.From = 0.0; $panelAnim.To = 1.0
  } else {
    $ballAnim.From = 0.0; $ballAnim.To = 1.0
    $panelAnim.From = 1.0; $panelAnim.To = 0.0
  }
  $ballAnim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($duration))
  $panelAnim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($duration))
  $ease = New-Object System.Windows.Media.Animation.QuadraticEase
  $ballAnim.EasingFunction = $ease
  $panelAnim.EasingFunction = $ease
  $storyboard = New-Object System.Windows.Media.Animation.Storyboard
  [System.Windows.Media.Animation.Storyboard]::SetTarget($ballAnim, $ballView)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($ballAnim, (New-Object System.Windows.PropertyPath 'Opacity'))
  [System.Windows.Media.Animation.Storyboard]::SetTarget($panelAnim, $panelView)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($panelAnim, (New-Object System.Windows.PropertyPath 'Opacity'))
  [void]$storyboard.Children.Add($ballAnim)
  [void]$storyboard.Children.Add($panelAnim)
  $script:CrossFade = $storyboard
  $storyboard.Add_Completed({ try { Complete-CrossFade } catch { Write-BallLog ('cross-fade failed: ' + $_.Exception.Message) } })
  [void]$storyboard.Begin()
}

# The first shape of a session (window shown from a remembered "expanded" state, or the initial
# collapsed placement) is painted instantly: a fade at startup would show the ball moving to the
# remembered spot before the panel arrives.
function Invoke-CrossFade {
  param([bool]$Opening)
  if ($script:FirstShape) {
    $script:FirstShape = $false
    $script:CrossFadeOpening = $Opening
    Complete-CrossFade
    return
  }
  Start-CrossFade $Opening
}

function Apply-Shape {
  param([bool]$Expanded)
  $ballSize = $script:BallSize
  $oldWidth = $window.Width
  $script:Expanded = $Expanded

  if ($Expanded) {
    Stop-Swim
    if ($null -eq $script:CollapsedAnchor) {
      $script:CollapsedAnchor = @{ Left = $window.Left; Top = $window.Top }
    }
    $ballLeft = $window.Left
    $ballTop = $window.Top
    $panelView.Visibility = 'Visible'
    $panelView.Width = $script:PanelWidth
    $height = Measure-PanelHeight
    $newWidth = $script:PanelWidth + 32
    $newHeight = $height + 32
    $panelView.Visibility = 'Hidden'
    # resize while only the (transparent) window grows - both views stay faded out for this step
    $window.Width = $newWidth
    $window.Height = $newHeight
    $window.Left = $ballLeft + $oldWidth - $newWidth
    $window.Top = $ballTop
    $panelView.Margin = New-Object System.Windows.Thickness 16
    $panelView.Height = $height
    $root.Width = $window.Width
    $root.Height = $window.Height
    $panelView.Visibility = 'Visible'
    $panelView.Opacity = 0.0
    [void](Move-IntoVirtualScreen)
    # keep the ball exactly where it was on screen, then fade it out while the panel fades in
    Set-BallViewInWindow $ballLeft $ballTop $oldWidth
    $ballView.Visibility = 'Visible'
    $ballView.Opacity = 1.0
    Invoke-CrossFade $true
  } else {
    $ballView.Width = $ballSize
    $ballView.Height = $ballSize
    $body.Width = $ballSize
    $body.Height = $ballSize
    $ring.Width = $ballSize + 2
    $ring.Height = $ballSize + 2
    $whale.Width = [math]::Round($ballSize * 0.68)
    $whale.Height = $whale.Width
    $anchor = $script:CollapsedAnchor
    if ($null -eq $anchor) { $anchor = @{ Left = $window.Left; Top = $window.Top } }
    $script:ClosingAnchor = $anchor
    Set-BallViewInWindow ([double]$anchor['Left']) ([double]$anchor['Top']) ($ballSize + 50)
    $ballView.Visibility = 'Visible'
    $ballView.Opacity = 0.0
    $panelView.Visibility = 'Visible'
    $panelView.Opacity = 1.0
    Invoke-CrossFade $false
  }
}

function Apply-PanelHeight {
  if (-not $script:Expanded) { return }
  $height = Measure-PanelHeight
  $want = $height + 32
  if ([math]::Abs($window.Height - $want) -lt 1) { return }
  $window.Height = $want
  $panelView.Height = $height
  $root.Height = $window.Height
  [void](Move-IntoVirtualScreen)
}

# A collapsed window that was shaped from stale metrics gets its current size back.
function Sync-BallSize {
  if ($script:Expanded) { return }
  $want = $script:BallSize + 50
  if (([math]::Abs($window.Width - $want) -lt 1) -and ([math]::Abs($window.Height - $want) -lt 1)) { return }
  Apply-Shape $false
}

function Get-EntryRank {
  param([string]$State, [bool]$Unread, [bool]$Local)
  if ($Local) { return -1 }
  if ($State -eq 'local') { return -1 }
  switch ($State) {
    'approval' { return 0 }
    'question' { return 0 }
    'error' { return 1 }
    'running' { return 3 }
  }
  if ($Unread) { return 2 }
  return $null
}

function Get-ChipText {
  param([string]$State, $Entry)
  if ($Entry -and $Entry.chip) { return [string]$Entry.chip }
  switch ($State) {
    'approval' { return $script:Labels.approval }
    'question' { return $script:Labels.question }
    'error' { return $script:Labels.error }
    'running' { return $script:Labels.running }
  }
  return $script:Labels.unread
}

function Set-ChipStyle {
  param($ChipBorder, $ChipText, [string]$State)
  switch ($State) {
    'approval' { $ChipBorder.Background = ConvertTo-Brush '#FFFDF1E2'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFF3D3A2'; $ChipText.Foreground = ConvertTo-Brush '#FFD97706'; break }
    'question' { $ChipBorder.Background = ConvertTo-Brush '#FFFCF8EF'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFEFE2C6'; $ChipText.Foreground = ConvertTo-Brush '#FF8A6A2B'; break }
    'error' { $ChipBorder.Background = ConvertTo-Brush '#FFFDF6F5'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFF0DAD7'; $ChipText.Foreground = ConvertTo-Brush '#FFA85A55'; break }
    'running' { $ChipBorder.Background = ConvertTo-Brush '#FFEEF3FF'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFDCE6FF'; $ChipText.Foreground = ConvertTo-Brush '#FF2552C4'; break }
    'local' { $ChipBorder.Background = ConvertTo-Brush '#FFEEF3FF'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFDCE6FF'; $ChipText.Foreground = ConvertTo-Brush '#FF2F6BFF'; break }
    default { $ChipBorder.Background = ConvertTo-Brush '#E8FFFFFF'; $ChipBorder.BorderBrush = ConvertTo-Brush '#FFECEFF4'; $ChipText.Foreground = ConvertTo-Brush '#FF8B94A3' }
  }
}

function New-TextButton {
  param([string]$Text, [string]$Color = '#FF6B7280', [double]$FontSize = 11)
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $Text
  $button.FontSize = $FontSize
  $button.Foreground = ConvertTo-Brush $Color
  $button.Background = ConvertTo-Brush '#00FFFFFF'
  $button.BorderThickness = New-Object System.Windows.Thickness 0
  $button.Padding = New-Object System.Windows.Thickness 0
  $button.Cursor = 'Hand'
  $button.HorizontalAlignment = 'Left'
  [void](Apply-FlatStyle $button)
  return $button
}

function New-EntryView {
  param([string]$Key)
  $card = New-Object System.Windows.Controls.Border
  $card.CornerRadius = New-Object System.Windows.CornerRadius 12
  $card.BorderThickness = New-Object System.Windows.Thickness 1
  $card.BorderBrush = ConvertTo-Brush '#FFEFEFF2'
  $card.Background = ConvertTo-Brush '#E6F5F6F8'
  $card.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
  $card.Tag = $Key

  $outer = New-Object System.Windows.Controls.Grid
  $barColumn = New-Object System.Windows.Controls.ColumnDefinition
  $barColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Pixel)
  $outer.ColumnDefinitions.Add($barColumn)
  $outer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

  $bar = New-Object System.Windows.Controls.Border
  $bar.Width = 2
  $bar.CornerRadius = New-Object System.Windows.CornerRadius 1
  $bar.Background = ConvertTo-Brush '#FFD8DEE9'
  $bar.Margin = New-Object System.Windows.Thickness 5, 12, 0, 12
  $bar.HorizontalAlignment = 'Left'
  [System.Windows.Controls.Grid]::SetColumn($bar, 0)
  [void]$outer.Children.Add($bar)

  $content = New-Object System.Windows.Controls.StackPanel
  $content.Margin = New-Object System.Windows.Thickness 12, 10, 11, 10
  [System.Windows.Controls.Grid]::SetColumn($content, 1)
  [void]$outer.Children.Add($content)

  $head = New-Object System.Windows.Controls.Grid
  $head.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $chipColumn = New-Object System.Windows.Controls.ColumnDefinition
  $chipColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $head.ColumnDefinitions.Add($chipColumn)
  $closeColumn = New-Object System.Windows.Controls.ColumnDefinition
  $closeColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $head.ColumnDefinitions.Add($closeColumn)

  $title = New-Object System.Windows.Controls.TextBlock
  $title.FontSize = 13
  $title.FontWeight = 'SemiBold'
  $title.Foreground = ConvertTo-Brush '#FF1B1F27'
  $title.TextTrimming = 'CharacterEllipsis'
  $title.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($title, 0)
  [void]$head.Children.Add($title)

  $chipBorder = New-Object System.Windows.Controls.Border
  $chipBorder.CornerRadius = New-Object System.Windows.CornerRadius 999
  $chipBorder.BorderThickness = New-Object System.Windows.Thickness 1
  $chipBorder.Padding = New-Object System.Windows.Thickness 7, 2, 7, 2
  $chipBorder.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($chipBorder, 1)
  $chipText = New-Object System.Windows.Controls.TextBlock
  $chipText.FontSize = 10.5
  $chipText.FontWeight = 'SemiBold'
  $chipBorder.Child = $chipText
  [void]$head.Children.Add($chipBorder)

  $close = New-TextButton $script:Labels.close '#FFC6CCD6' 13
  $close.HorizontalAlignment = 'Right'
  $close.VerticalAlignment = 'Top'
  $close.Padding = New-Object System.Windows.Thickness 6, 0, 0, 0
  $close.Tag = $Key
  $close.Add_Click({
    param($sender, $e)
    $sender.IsEnabled = $false
    Write-BallAction @{ kind = 'close'; id = [string]$sender.Tag }
  })
  [System.Windows.Controls.Grid]::SetColumn($close, 2)
  [void]$head.Children.Add($close)

  [void]$content.Children.Add($head)

  $hint = New-Object System.Windows.Controls.TextBlock
  $hint.FontSize = 11.5
  $hint.Foreground = ConvertTo-Brush '#FF6B7280'
  $hint.TextWrapping = 'Wrap'
  $hint.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
  $hint.Visibility = 'Collapsed'
  [void]$content.Children.Add($hint)

  $cardsStack = New-Object System.Windows.Controls.StackPanel
  $cardsStack.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
  [void]$content.Children.Add($cardsStack)

  $inputGrid = New-Object System.Windows.Controls.Grid
  $inputGrid.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
  $inputGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $sendColumn = New-Object System.Windows.Controls.ColumnDefinition
  $sendColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
  $inputGrid.ColumnDefinitions.Add($sendColumn)
  $textBox = New-Object System.Windows.Controls.TextBox
  $textBox.FontSize = 12
  $textBox.Padding = New-Object System.Windows.Thickness 9, 4, 9, 4
  $textBox.Background = ConvertTo-Brush '#E8FFFFFF'
  $textBox.Foreground = ConvertTo-Brush '#FF1B1F27'
  $textBox.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
  $textBox.BorderThickness = New-Object System.Windows.Thickness 1
  $textBox.Tag = $Key
  [System.Windows.Controls.Grid]::SetColumn($textBox, 0)
  [void]$inputGrid.Children.Add($textBox)

  $placeholder = New-Object System.Windows.Controls.TextBlock
  $placeholder.Text = $script:Labels.placeholder
  $placeholder.FontSize = 12
  $placeholder.Foreground = ConvertTo-Brush '#FFA4ACBA'
  $placeholder.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
  $placeholder.VerticalAlignment = 'Center'
  $placeholder.IsHitTestVisible = $false
  [System.Windows.Controls.Grid]::SetColumn($placeholder, 0)
  [void]$inputGrid.Children.Add($placeholder)
  $textBox.Add_TextChanged({
    param($sender, $e)
    if ([string]::IsNullOrEmpty([string]$sender.Text)) { $placeholder.Visibility = 'Visible' } else { $placeholder.Visibility = 'Collapsed' }
  }.GetNewClosure())
  $textBox.Add_GotKeyboardFocus({ $placeholder.Visibility = 'Collapsed'; Enable-BallKeyboard }.GetNewClosure())
  $textBox.Add_LostKeyboardFocus({
    param($sender, $e)
    if ([string]::IsNullOrEmpty([string]$sender.Text)) { $placeholder.Visibility = 'Visible' }
    Disable-BallKeyboard
  }.GetNewClosure())

  $send = New-Object System.Windows.Controls.Button
  $send.FontSize = 13
  $send.Width = 32
  $send.Height = 32
  $send.Margin = New-Object System.Windows.Thickness 7, 0, 0, 0
  $send.Background = ConvertTo-Brush '#FFEEF3FF'
  $send.Foreground = ConvertTo-Brush '#FF2F6BFF'
  $send.BorderBrush = ConvertTo-Brush '#FFDCE6FF'
  $send.BorderThickness = New-Object System.Windows.Thickness 1
  $send.Cursor = 'Hand'
  $send.Padding = New-Object System.Windows.Thickness 0
  $send.Tag = $Key
  [void](Apply-FlatStyle $send)
  [System.Windows.Controls.Grid]::SetColumn($send, 1)
  [void]$inputGrid.Children.Add($send)
  $inputGrid.Visibility = 'Collapsed'
  [void]$content.Children.Add($inputGrid)

  $ack = New-TextButton $script:Labels.ack '#FFB56A64' 11
  $ack.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
  $ack.Tag = $Key
  $ack.Visibility = 'Collapsed'
  $ack.Add_Click({
    param($sender, $e)
    $sender.IsEnabled = $false
    Write-BallAction @{ kind = 'ack'; id = [string]$sender.Tag }
  })
  [void]$content.Children.Add($ack)

  $notice = New-Object System.Windows.Controls.TextBlock
  $notice.FontSize = 10.5
  $notice.Foreground = ConvertTo-Brush '#FF8B94A3'
  $notice.TextWrapping = 'Wrap'
  $notice.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
  $notice.Visibility = 'Collapsed'
  [void]$content.Children.Add($notice)

  $card.Child = $outer

  $view = @{
    Panel = $card; Bar = $bar; Title = $title; ChipBorder = $chipBorder; ChipText = $chipText
    Hint = $hint; CardsStack = $cardsStack; InputGrid = $inputGrid; TextBox = $textBox
    Send = $send; Ack = $ack; Notice = $notice; Close = $close; Placeholder = $placeholder; Target = ''; CardSignature = ''
  }

  $send.Add_Click({
    param($sender, $e)
    $key = [string]$sender.Tag
    $entryView = $script:Entries[$key]
    if ($null -eq $entryView) { return }
    $text = [string]$entryView.TextBox.Text
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $entryView.TextBox.Text = ''
    $entryView.Notice.Text = $script:Labels.sent
    $entryView.Notice.Visibility = 'Visible'
    Write-BallAction @{ kind = 'prompt'; key = $key; target = [string]$entryView.Target; text = $text }
  })
  $textBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -ne 'Enter') { return }
    $key = [string]$sender.Tag
    $entryView = $script:Entries[$key]
    if ($null -eq $entryView) { return }
    $text = [string]$entryView.TextBox.Text
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $entryView.TextBox.Text = ''
    $entryView.Notice.Text = $script:Labels.sent
    $entryView.Notice.Visibility = 'Visible'
    Write-BallAction @{ kind = 'prompt'; key = $key; target = [string]$entryView.Target; text = $text }
  })

  return $view
}

function New-OptionButton {
  param($cardData, $option, [int]$Index)
  $button = New-Object System.Windows.Controls.Button
  $button.Content = [string]$option.label
  $button.FontSize = 12
  $button.Height = 30
  $button.Padding = New-Object System.Windows.Thickness 10, 0, 10, 0
  $button.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
  $button.Cursor = 'Hand'
  $button.BorderThickness = New-Object System.Windows.Thickness 1
  if ($Index -eq 0) {
    $button.Background = ConvertTo-Brush '#FFEEF3FF'
    $button.BorderBrush = ConvertTo-Brush '#FFDCE6FF'
    $button.Foreground = ConvertTo-Brush '#FF2F6BFF'
    $button.FontWeight = 'SemiBold'
  } else {
    $button.Background = ConvertTo-Brush '#E8FFFFFF'
    $button.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
    $button.Foreground = ConvertTo-Brush '#FF4B5563'
  }
  [void](Apply-FlatStyle $button)
  $button.Tag = @{ kind = [string]$cardData.kind; id = [string]$cardData.id; optionId = [string]$option.id }
  $button.Add_Click({
    param($sender, $e)
    $sender.IsEnabled = $false
    $tag = $sender.Tag
    Write-BallLog ('action approval ' + [string]$tag.id + ' -> ' + [string]$tag.optionId)
    Write-BallAction @{ kind = 'approval'; id = $tag.id; optionId = $tag.optionId }
  })
  return $button
}

function Get-QuestionValue {
  param($State, [int]$Index)
  $itemId = [string]$State.items[$Index]
  $selected = New-Object System.Collections.ArrayList
  if ($State.selected.ContainsKey($itemId)) { $selected = $State.selected[$itemId] }
  $custom = ''
  if ($State.boxes.ContainsKey($itemId)) { $custom = ([string]$State.boxes[$itemId].Text).Trim() }
  $ok = ($selected.Count -gt 0 -or $custom -ne '')
  return @{ id = $itemId; selected = @($selected); custom = $custom; ok = $ok }
}

function Update-QuestionOptionStyles {
  param($State, [string]$ItemId)
  $rows = @($State.optionRows[$ItemId])
  $selected = New-Object System.Collections.ArrayList
  if ($State.selected.ContainsKey($ItemId)) { $selected = $State.selected[$ItemId] }
  foreach ($row in $rows) {
    if ($selected -contains [string]$row.label) {
      $row.border.Background = ConvertTo-Brush '#FFEEF3FF'
      $row.border.BorderBrush = ConvertTo-Brush '#FFDCE6FF'
      $row.labelBlock.Foreground = ConvertTo-Brush '#FF2F6BFF'
      $row.labelBlock.FontWeight = 'SemiBold'
    } else {
      $row.border.Background = ConvertTo-Brush '#E8FFFFFF'
      $row.border.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
      $row.labelBlock.Foreground = ConvertTo-Brush '#FF1B1F27'
      $row.labelBlock.FontWeight = 'Normal'
    }
  }
}
function Update-QuestionNav {
  param($State)
  $total = $State.items.Count
  for ($i = 0; $i -lt $total; $i++) {
    if ($i -eq $State.index) { $State.pages[$i].Visibility = 'Visible' } else { $State.pages[$i].Visibility = 'Collapsed' }
  }
  $State.progress.Text = [string]($State.index + 1) + ' / ' + [string]$total
  if ($State.index -gt 0) { $State.prevButton.Visibility = 'Visible' } else { $State.prevButton.Visibility = 'Collapsed' }
  if ($State.index -eq $total - 1) {
    $State.nextButton.Visibility = 'Collapsed'
    $State.submitButton.Visibility = 'Visible'
  } else {
    $State.nextButton.Visibility = 'Visible'
    $State.submitButton.Visibility = 'Collapsed'
  }
}

function New-QuestionCard {
  param($CardData, $View)
  $cardId = [string]$CardData.id
  $box = New-Object System.Windows.Controls.StackPanel
  $state = @{
    items = New-Object System.Collections.ArrayList
    selected = @{}
    boxes = @{}
    optionRows = @{}
    notice = $View.Notice
    index = 0
    pages = New-Object System.Collections.ArrayList
    progress = $null
    prevButton = $null
    nextButton = $null
    submitButton = $null
  }

  $progress = New-Object System.Windows.Controls.TextBlock
  $progress.FontSize = 10.5
  $progress.Foreground = ConvertTo-Brush '#FFA4ACBA'
  $progress.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
  $state.progress = $progress
  [void]$box.Children.Add($progress)

  $items = @($CardData.items)
  if ($items.Count -eq 0) {
    $items = @([pscustomobject]@{ id = $cardId; prompt = [string]$CardData.title; options = @() })
  }

  for ($index = 0; $index -lt $items.Count; $index++) {
    $item = $items[$index]
    $itemId = [string]$item.id
    $multi = $false
    if ($item.multiSelect -eq $true) { $multi = $true }
    $page = New-Object System.Windows.Controls.StackPanel
    if ($index -ne 0) { $page.Visibility = 'Collapsed' }

    $headerText = [string]$item.header
    if ($headerText -ne '') {
      $headerBlock = New-Object System.Windows.Controls.TextBlock
      $headerBlock.Text = $headerText
      $headerBlock.FontSize = 10.5
      $headerBlock.FontWeight = 'Bold'
      $headerBlock.Foreground = ConvertTo-Brush '#FFA4ACBA'
      $headerBlock.TextWrapping = 'Wrap'
      $headerBlock.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
      [void]$page.Children.Add($headerBlock)
    }

    $promptText = [string]$item.prompt
    if ($promptText -eq '') { $promptText = [string]$CardData.title }
    if ($promptText -ne '') {
      $prompt = New-Object System.Windows.Controls.TextBlock
      $prompt.Text = $promptText
      $prompt.FontSize = 12.5
      $prompt.Foreground = ConvertTo-Brush '#FF1B1F27'
      $prompt.TextWrapping = 'Wrap'
      $prompt.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
      [void]$page.Children.Add($prompt)
    }

    $detailText = [string]$item.detail
    if ($detailText -ne '') {
      $detailBlock = New-Object System.Windows.Controls.TextBlock
      $detailBlock.Text = $detailText
      $detailBlock.FontSize = 11
      $detailBlock.Foreground = ConvertTo-Brush '#FF6B7280'
      $detailBlock.TextWrapping = 'Wrap'
      $detailBlock.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
      [void]$page.Children.Add($detailBlock)
    }

    $options = @($item.options)
    if ($options.Count -gt 0) {
      $optionsStack = New-Object System.Windows.Controls.StackPanel
      $optionsStack.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
      $rows = New-Object System.Collections.ArrayList
      foreach ($option in $options) {
        if ($null -eq $option) { continue }
        $label = [string]$option.label
        if ($label -eq '') { continue }
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius 10
        $row.BorderThickness = New-Object System.Windows.Thickness 1
        $row.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
        $row.Background = ConvertTo-Brush '#E8FFFFFF'
        $row.Padding = New-Object System.Windows.Thickness 9, 7, 9, 7
        $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $row.Cursor = 'Hand'
        $rowText = New-Object System.Windows.Controls.StackPanel
        $labelBlock = New-Object System.Windows.Controls.TextBlock
        $labelBlock.Text = $label
        $labelBlock.FontSize = 12
        $labelBlock.Foreground = ConvertTo-Brush '#FF1B1F27'
        $labelBlock.TextWrapping = 'Wrap'
        [void]$rowText.Children.Add($labelBlock)
        $description = [string]$option.description
        if ($description -ne '') {
          $descriptionBlock = New-Object System.Windows.Controls.TextBlock
          $descriptionBlock.Text = $description
          $descriptionBlock.FontSize = 10.5
          $descriptionBlock.Foreground = ConvertTo-Brush '#FF8B94A3'
          $descriptionBlock.TextWrapping = 'Wrap'
          $descriptionBlock.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
          [void]$rowText.Children.Add($descriptionBlock)
        }
        $row.Child = $rowText
        [void]$rows.Add(@{ label = $label; border = $row; labelBlock = $labelBlock })
        $optionState = $state
        $optionItemId = $itemId
        $optionLabel = $label
        $optionMulti = $multi
        $row.Add_MouseLeftButtonUp({
          param($sender, $e)
          $current = $optionState.selected[$optionItemId]
          if ($null -eq $current) {
            $current = New-Object System.Collections.ArrayList
            $optionState.selected[$optionItemId] = $current
          }
          if ($optionMulti) {
            if ($current -contains $optionLabel) { [void]$current.Remove($optionLabel) } else { [void]$current.Add($optionLabel) }
          } else {
            $current.Clear()
            [void]$current.Add($optionLabel)
          }
          Update-QuestionOptionStyles $optionState $optionItemId
        }.GetNewClosure())
        [void]$optionsStack.Children.Add($row)
      }
      $state.optionRows[$itemId] = $rows
      [void]$page.Children.Add($optionsStack)
    }

    $textBox = New-Object System.Windows.Controls.TextBox
    $textBox.FontSize = 12
    $textBox.Padding = New-Object System.Windows.Thickness 9, 4, 9, 4
    $textBox.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
    $textBox.Background = ConvertTo-Brush '#E8FFFFFF'
    $textBox.Foreground = ConvertTo-Brush '#FF1B1F27'
    $textBox.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
    $textBox.BorderThickness = New-Object System.Windows.Thickness 1
    $textBox.ToolTip = $script:Labels.customAnswer
    $textBox.Add_GotKeyboardFocus({ Enable-BallKeyboard })
    $textBox.Add_LostKeyboardFocus({ Disable-BallKeyboard })
    [void]$page.Children.Add($textBox)
    $state.boxes[$itemId] = $textBox
    $state.items.Add($itemId) | Out-Null

    [void]$state.pages.Add($page)
    [void]$box.Children.Add($page)
  }
  $navRow = New-Object System.Windows.Controls.WrapPanel
  $navRow.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0

  $prevButton = New-Object System.Windows.Controls.Button
  $prevButton.Content = $script:Labels.prev
  $prevButton.FontSize = 12
  $prevButton.Height = 30
  $prevButton.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
  $prevButton.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
  $prevButton.Cursor = 'Hand'
  $prevButton.Background = ConvertTo-Brush '#E8FFFFFF'
  $prevButton.Foreground = ConvertTo-Brush '#FF4B5563'
  $prevButton.BorderBrush = ConvertTo-Brush '#FFE7EAF0'
  $prevButton.BorderThickness = New-Object System.Windows.Thickness 1
  $prevButton.Visibility = 'Collapsed'
  [void](Apply-FlatStyle $prevButton)
  $prevState = $state
  $prevButton.Add_Click({
    param($sender, $e)
    if ($prevState.index -le 0) { return }
    $prevState.index = $prevState.index - 1
    Update-QuestionNav $prevState
  }.GetNewClosure())
  [void]$navRow.Children.Add($prevButton)
  $state.prevButton = $prevButton

  $nextButton = New-Object System.Windows.Controls.Button
  $nextButton.Content = $script:Labels.next
  $nextButton.FontSize = 12
  $nextButton.Height = 30
  $nextButton.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
  $nextButton.Cursor = 'Hand'
  $nextButton.Background = ConvertTo-Brush '#FFEEF3FF'
  $nextButton.Foreground = ConvertTo-Brush '#FF2F6BFF'
  $nextButton.BorderBrush = ConvertTo-Brush '#FFDCE6FF'
  $nextButton.BorderThickness = New-Object System.Windows.Thickness 1
  $nextButton.FontWeight = 'SemiBold'
  [void](Apply-FlatStyle $nextButton)
  $nextState = $state
  $nextButton.Add_Click({
    param($sender, $e)
    $value = Get-QuestionValue $nextState $nextState.index
    if (-not $value.ok) {
      $nextState.notice.Text = $script:Labels.answerIncomplete
      $nextState.notice.Visibility = 'Visible'
      return
    }
    if ($nextState.index -ge ($nextState.items.Count - 1)) { return }
    $nextState.index = $nextState.index + 1
    Update-QuestionNav $nextState
  }.GetNewClosure())
  [void]$navRow.Children.Add($nextButton)
  $state.nextButton = $nextButton

  $submitButton = New-Object System.Windows.Controls.Button
  $submitButton.Content = $script:Labels.submit
  $submitButton.FontSize = 12
  $submitButton.Height = 30
  $submitButton.Padding = New-Object System.Windows.Thickness 12, 0, 12, 0
  $submitButton.Cursor = 'Hand'
  $submitButton.Background = ConvertTo-Brush '#FFEEF3FF'
  $submitButton.Foreground = ConvertTo-Brush '#FF2F6BFF'
  $submitButton.BorderBrush = ConvertTo-Brush '#FFDCE6FF'
  $submitButton.BorderThickness = New-Object System.Windows.Thickness 1
  $submitButton.FontWeight = 'SemiBold'
  [void](Apply-FlatStyle $submitButton)
  $submitState = $state
  $submitCardId = $cardId
  $submitButton.Add_Click({
    param($sender, $e)
    $answers = New-Object System.Collections.ArrayList
    $complete = $true
    $firstMissing = -1
    for ($i = 0; $i -lt $submitState.items.Count; $i++) {
      $value = Get-QuestionValue $submitState $i
      if (-not $value.ok) { $complete = $false; $firstMissing = $i; break }
      $answer = @{ id = $value.id }
      if (@($value.selected).Count -gt 0) { $answer['selected'] = @($value.selected) }
      if ($value.custom -ne '') { $answer['custom'] = $value.custom }
      [void]$answers.Add($answer)
    }
    if (-not $complete) {
      $submitState.index = $firstMissing
      Update-QuestionNav $submitState
      $submitState.notice.Text = $script:Labels.answerIncomplete
      $submitState.notice.Visibility = 'Visible'
      return
    }
    $submitState.notice.Text = $script:Labels.sent
    $submitState.notice.Visibility = 'Visible'
    Write-BallAction @{ kind = 'answer'; id = $submitCardId; answers = @($answers) }
  }.GetNewClosure())
  [void]$navRow.Children.Add($submitButton)
  $state.submitButton = $submitButton

  [void]$box.Children.Add($navRow)
  Update-QuestionNav $state
  $script:CardAnswerState[$cardId] = $state
  return $box
}

function Update-EntryView {
  param($View, $Entry)
  $state = [string]$Entry.state
  $color = '#FFD8DEE9'
  if ($Entry.color) { $color = [string]$Entry.color }
  $View.Bar.Background = ConvertTo-SoftBrush $color
  # The send / Enter handlers read this to build the prompt action. Without it every prompt
  # went out with an empty target and the host silently dropped it (message "sent" but the
  # session never received anything).
  $View.Target = [string]$Entry.target
  $View.Title.Text = [string]$Entry.title
  $View.ChipText.Text = Get-ChipText $state $Entry
  Set-ChipStyle $View.ChipBorder $View.ChipText $state
  $View.Close.Content = $script:Labels.close
  $View.Ack.Content = $script:Labels.ack
  $View.Send.Content = $script:Labels.send
  $View.Placeholder.Text = $script:Labels.placeholder

  $hint = ''
  if ($Entry.hint) { $hint = [string]$Entry.hint }
  elseif ($Entry.errorNote) { $hint = [string]$Entry.errorNote }
  if ($hint -ne '') { $View.Hint.Text = $hint; $View.Hint.Visibility = 'Visible' }
  else { $View.Hint.Visibility = 'Collapsed' }

  if ($Entry.canAck) { $View.Ack.Visibility = 'Visible' } else { $View.Ack.Visibility = 'Collapsed' }

  $showInput = $false
  if ($Entry.showInput -ne $null) { $showInput = [bool]$Entry.showInput }
  if ($showInput) { $View.InputGrid.Visibility = 'Visible' } else { $View.InputGrid.Visibility = 'Collapsed' }
  $locked = $false
  if ($Entry.lock -ne $null) { $locked = [bool]$Entry.lock }
  $View.TextBox.IsEnabled = -not $locked
  $View.Send.IsEnabled = -not $locked
  if ($locked) { $View.TextBox.Background = ConvertTo-Brush '#E6F1F2F5' } else { $View.TextBox.Background = ConvertTo-Brush '#E8FFFFFF' }

  $cards = @()
  if ($Entry.cards) { $cards = @($Entry.cards) }
  $signature = ($cards | ForEach-Object { [string]$_.id + ':' + [string]$_.kind }) -join '|'
  if ($signature -ne $View.CardSignature) {
    $View.CardSignature = $signature
    $View.CardsStack.Children.Clear()
    foreach ($cardData in $cards) {
      $kind = [string]$cardData.kind
      if ($kind -eq 'question') {
        [void]$View.CardsStack.Children.Add((New-QuestionCard $cardData $View))
        continue
      }
      $questionText = New-Object System.Windows.Controls.TextBlock
      $questionText.Text = [string]$cardData.title
      $questionText.FontSize = 11.5
      $questionText.Foreground = ConvertTo-Brush '#FF6B7280'
      $questionText.TextWrapping = 'Wrap'
      [void]$View.CardsStack.Children.Add($questionText)
      if ($cardData.hint) {
        $hintText = New-Object System.Windows.Controls.TextBlock
        $hintText.Text = [string]$cardData.hint
        $hintText.FontSize = 10.5
        $hintText.Foreground = ConvertTo-Brush '#FFA4ACBA'
        $hintText.TextWrapping = 'Wrap'
        $hintText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
        [void]$View.CardsStack.Children.Add($hintText)
      }
      $optionsRow = New-Object System.Windows.Controls.WrapPanel
      $optionsRow.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
      $index = 0
      foreach ($option in @($cardData.options)) {
        if ($null -eq $option) { continue }
        [void]$optionsRow.Children.Add((New-OptionButton $cardData $option $index))
        $index++
      }
      [void]$View.CardsStack.Children.Add($optionsRow)
    }
  }
}

function Get-SectionLabel {
  param([int]$Rank)
  switch ($Rank) {
    0 { return $script:Labels.pending }
    1 { return $script:Labels.pending }
    2 { return $script:Labels.unread }
    3 { return $script:Labels.running }
  }
  return ''
}

function Sync-Entries {
  param($Document)
  $wanted = @()
  if ($Document.entries) { $wanted = @($Document.entries) }

  $data = @{}
  foreach ($entry in $wanted) {
    $key = [string]$entry.key
    if ($key -eq '') { continue }
    $data[$key] = $entry
    $state = [string]$entry.state
    $previous = $script:PrevStates[$key]
    if ($null -ne $previous -and $previous -ne $state) {
      if ($state -eq 'idle' -and ($previous -eq 'running' -or $previous -eq 'approval' -or $previous -eq 'question' -or $previous -eq 'error')) {
        $script:Unread[$key] = $true
      } elseif ($state -ne 'idle') {
        $script:Unread.Remove($key)
      }
    }
    $script:PrevStates[$key] = $state
  }

  $buckets = @{ '-1' = New-Object System.Collections.ArrayList; '0' = New-Object System.Collections.ArrayList; '1' = New-Object System.Collections.ArrayList; '2' = New-Object System.Collections.ArrayList; '3' = New-Object System.Collections.ArrayList }
  foreach ($entry in $wanted) {
    $key = [string]$entry.key
    if ($key -eq '') { continue }
    $state = [string]$entry.state
    $unread = $script:Unread.ContainsKey($key)
    if ($entry.unread -ne $null) { $unread = [bool]$entry.unread }
    $rank = Get-EntryRank $state $unread $false
    if ($null -eq $rank) { continue }
    [void]$buckets[[string]$rank].Add($key)
  }

  # One section per visual group: pending (approval + error), running, then completed-unread.
  # Labels come from the host so the ball script stays ASCII.
  $groups = @(
    @{ key = 'pending'; ranks = @(0, 1); label = $script:Labels.pending },
    @{ key = 'running'; ranks = @(3); label = $script:Labels.running },
    @{ key = 'unread'; ranks = @(2); label = $script:Labels.unread }
  )
  $sequence = New-Object System.Collections.ArrayList
  # Local rows ("new session") always come first and carry no section header.
  foreach ($key in @($buckets['-1'])) { [void]$sequence.Add($key) }
  foreach ($group in $groups) {
    $keys = New-Object System.Collections.ArrayList
    foreach ($rank in $group.ranks) { foreach ($key in @($buckets[[string]$rank])) { [void]$keys.Add($key) } }
    if ($keys.Count -eq 0) { continue }
    $headerKey = 'section-' + [string]$group.key
    $header = $script:SectionViews[$headerKey]
    if ($null -eq $header) {
      $header = New-Object System.Windows.Controls.TextBlock
      $header.FontSize = 10.5
      $header.FontWeight = 'Bold'
      $header.Foreground = ConvertTo-Brush '#FFA4ACBA'
      $header.Margin = New-Object System.Windows.Thickness 2, 6, 0, 5
      $script:SectionViews[$headerKey] = $header
    }
    if ([string]$header.Text -ne $group.label) { $header.Text = $group.label; $script:ContentDirty = $true }
    [void]$sequence.Add($header)
    foreach ($key in $keys) { [void]$sequence.Add($key) }
  }

  foreach ($key in @($script:EntryOrder)) {
    $view = $script:Entries[$key]
    if ($null -ne $view) {
      [void]$bodyStack.Children.Remove($view.Panel)
      $script:Entries.Remove($key)
      $script:EntryHashes.Remove($key)
      $script:ContentDirty = $true
    }
  }
  foreach ($headerKey in @($script:SectionViews.Keys)) {
    $header = $script:SectionViews[$headerKey]
    if (-not ($sequence -contains $header)) {
      [void]$bodyStack.Children.Remove($header)
      $script:SectionViews.Remove($headerKey)
    }
  }
  $script:EntryOrder = New-Object System.Collections.ArrayList

  for ($index = 0; $index -lt $sequence.Count; $index++) {
    $item = $sequence[$index]
    if ($item -is [string]) {
      $key = [string]$item
      [void]$script:EntryOrder.Add($key)
      $view = $script:Entries[$key]
      if ($null -eq $view) {
        $view = New-EntryView $key
        $script:Entries[$key] = $view
        [void]$bodyStack.Children.Add($view.Panel)
        $script:ContentDirty = $true
      }
      $entryHash = ConvertTo-Json -Compress -Depth 8 -InputObject $data[$key]
      if ($script:EntryHashes[$key] -ne $entryHash) {
        $script:EntryHashes[$key] = $entryHash
        Update-EntryView $view $data[$key]
        $script:ContentDirty = $true
      }
      $element = $view.Panel
    } else {
      $element = $item
      if (-not $bodyStack.Children.Contains($element)) { [void]$bodyStack.Children.Add($element) }
    }
    if ($index -lt $bodyStack.Children.Count -and -not [object]::ReferenceEquals($bodyStack.Children[$index], $element)) {
      [void]$bodyStack.Children.Remove($element)
      $bodyStack.Children.Insert($index, $element)
    }
  }
}

# --------------------------------------------------------------------------- state apply
function Apply-State {
  param($State)
  if ($null -eq $State) { return }
  $script:State = $State
  $status = $State.status
  $windowState = $State.window
  $metrics = $State.metrics

  if ($null -ne $State.labels) {
    foreach ($name in @('send', 'ack', 'sent', 'close', 'placeholder', 'answer', 'answerIncomplete', 'customAnswer', 'next', 'prev', 'submit', 'pending', 'pendingHint', 'running', 'unread', 'approval', 'question', 'error')) {
      $value = $State.labels.PSObject.Properties[$name]
      if ($null -ne $value -and $value.Value) { $script:Labels[$name] = [string]$value.Value }
    }
  }

  $expanded = $false
  if ($null -ne $windowState -and $null -ne $windowState.expanded) { $expanded = [bool]$windowState.expanded }

  $ballSize = 48.0
  if ($null -ne $metrics -and $null -ne $metrics.ballSize) { $ballSize = [double]$metrics.ballSize }
  if ($null -ne $metrics -and $null -ne $metrics.panelWidth) { $script:PanelWidth = [double]$metrics.panelWidth }
  if ($null -ne $metrics -and $null -ne $metrics.panelHeight) { $script:PanelHeight = [double]$metrics.panelHeight }
  $script:BallSize = $ballSize

  # 1) shape first: the position code below must run against the FINAL window size
  $script:ContentDirty = $false
  if ($expanded) { Sync-Entries $State }
  if ($null -ne $script:CrossFade) {
    # animation in flight: let it finish, the state tick for the same toggle must not reshape
  } elseif ($expanded -ne $script:Expanded) {
    Apply-Shape $expanded
  } elseif ($expanded) {
    Apply-PanelHeight
  } else {
    Sync-BallSize
  }

  # 2) position: the host remembers the COLLAPSED ball's top-left. While the panel is open it is
  #    converted to the panel's left edge and clamped, so a restart can never put the panel off
  #    screen. When there is no remembered point the shape's own default corner is used.
  $positionApplied = $false
  if (($null -ne $windowState) -and ($null -ne $windowState.x) -and (-not $script:UserMoved)) {
    $wantLeft = [double]$windowState.x
    $wantTop = [double]$windowState.y
    $hostChanged = ($null -eq $script:LastHostX) -or ([math]::Abs($wantLeft - $script:LastHostX) -gt 0.5) -or ([math]::Abs($wantTop - $script:LastHostY) -gt 0.5)
    if ($hostChanged) {
      $script:FirstPositionPending = $false
      $script:LastHostX = $wantLeft
      $script:LastHostY = $wantTop
      $positionApplied = $true
      if (Test-HostPositionUsable $wantLeft $wantTop) {
        $ballWindowSize = $script:BallSize + 50
        if ($script:Expanded) {
          $window.Left = $wantLeft + $ballWindowSize - $window.Width
          $window.Top = $wantTop
        } else {
          $window.Left = $wantLeft
          $window.Top = $wantTop
        }
        [void](Move-IntoVirtualScreen)
        if ($script:Expanded) {
          $script:CollapsedAnchor = @{ Left = ($window.Left + $window.Width - $ballWindowSize); Top = $window.Top }
        } else {
          $script:CollapsedAnchor = @{ Left = $window.Left; Top = $window.Top }
        }
      } else {
        if ($script:Expanded) { Set-DefaultPanelPosition } else { Set-DefaultBallPosition }
        Write-BallAction @{ kind = 'pos'; x = [math]::Round($window.Left, 1); y = [math]::Round($window.Top, 1) }
      }
    }
  }
  if ((-not $positionApplied) -and (-not $script:UserMoved) -and $script:FirstPositionPending -and (($null -eq $windowState) -or ($null -eq $windowState.x))) {
    $script:FirstPositionPending = $false
    if ($script:Expanded) { Set-DefaultPanelPosition } else { Set-DefaultBallPosition }
    Write-BallAction @{ kind = 'pos'; x = [math]::Round($window.Left, 1); y = [math]::Round($window.Top, 1) }
  }

  # 3) status / pulse / badges
  $key = 'idle'
  $color = '#FF7C8598'
  $label = ''
  if ($null -ne $status) {
    if ($status.key) { $key = [string]$status.key }
    if ($status.color) { $color = [string]$status.color }
    if ($status.label) { $label = [string]$status.label }
  }
  $ring.Stroke = ConvertTo-Brush $color '#FF7C8598'
  $statusDot.Fill = ConvertTo-Brush $color '#FF7C8598'
  $statusLabel.Text = $label

  $running = $false
  if ($State.running -ne $null) { $running = [bool]$State.running }
  if ($key -eq 'working') { $running = $true }
  $script:Working = $running
  $script:Pulse = $running
  Update-BallPulse

  # pending count: host value, or count entries that carry cards for older documents
  $pending = -1
  if ($null -ne $State.pendingCount) {
    try { $pending = [int]$State.pendingCount } catch { $pending = -1 }
  }
  if ($pending -lt 0 -and $null -ne $State.entries) {
    $pending = 0
    foreach ($entry in $State.entries) {
      if ($null -ne $entry.cards -and @($entry.cards).Count -gt 0) { $pending++ }
    }
  }
  if ($pending -lt 0) { $pending = 0 }
  if ($null -ne $pendingPill) {
    if ($pending -gt 0) {
      $hint = [string]$script:Labels['pendingHint']
      $pillText = [string]$pending
      if ($hint -ne '') { $pillText = $pillText + ' ' + $hint }
      $pendingPillText.Text = $pillText
      $pendingPill.Visibility = 'Visible'
    } else {
      $pendingPill.Visibility = 'Collapsed'
    }
  }
  if ($pending -gt 0) { $badgeText.Text = [string]$pending; $badge.Visibility = 'Visible' } else { $badge.Visibility = 'Collapsed' }

  # 4) window visibility / opacity
  if ($null -ne $windowState) {
    if ($windowState.visible -eq $false) { $window.Visibility = 'Hidden'; return }
    if ($windowState.opacity -ne $null) {
      $opacity = [double]$windowState.opacity
      if ($opacity -lt 0) { $opacity = 0 }
      if ($opacity -gt 1) { $opacity = 1 }
      $window.Opacity = $opacity
    }
  }
  if ($window.Visibility -ne 'Visible') { $window.Visibility = 'Visible' }
}


# --------------------------------------------------------------------------- input
function Expand-Panel {
  # Build the entries BEFORE the panel is measured: otherwise the panel opens with the previous
  # (empty) content height and grows on the next state tick, which reads as a flash.
  if ($null -ne $script:State) {
    $script:ContentDirty = $false
    Sync-Entries $script:State
  }
  Apply-Shape $true
  $script:ContentDirty = $false
  Write-BallAction @{ kind = 'expanded'; expanded = $true }
}
function Collapse-Panel {
  Disable-BallKeyboard
  Apply-Shape $false
  Write-BallAction @{ kind = 'expanded'; expanded = $false }
}

$body.Add_MouseLeftButtonDown({
  param($sender, $e)
  try {
    $script:Dragging = $true
    $script:DragMoved = $false
    if ($null -ne $poll) { $poll.Stop() }
    $script:UserMoved = $true
    $script:DragScale = Get-DpiScale
    $script:DragPoint = Get-CursorPoint
    $script:DragStart = @{ X = $script:DragPoint.X; Y = $script:DragPoint.Y; Left = $window.Left; Top = $window.Top }
    [void]$body.CaptureMouse()
  } catch { Write-BallLog ('drag start failed: ' + $_.Exception.Message) }
}.GetNewClosure())
$ballView.Add_MouseLeftButtonDown({
  param($sender, $e)
  try {
    $script:Dragging = $true
    $script:DragMoved = $false
    if ($null -ne $poll) { $poll.Stop() }
    $script:UserMoved = $true
    $script:DragScale = Get-DpiScale
    $script:DragPoint = Get-CursorPoint
    $script:DragStart = @{ X = $script:DragPoint.X; Y = $script:DragPoint.Y; Left = $window.Left; Top = $window.Top }
    [void]$ballView.CaptureMouse()
  } catch { Write-BallLog ('drag start failed: ' + $_.Exception.Message) }
})
$panelHeader.Add_MouseLeftButtonDown({
  param($sender, $e)
  try {
    $script:Dragging = $true
    $script:DragMoved = $false
    if ($null -ne $poll) { $poll.Stop() }
    $script:UserMoved = $true
    $script:DragScale = Get-DpiScale
    $script:DragPoint = Get-CursorPoint
    $script:DragStart = @{ X = $script:DragPoint.X; Y = $script:DragPoint.Y; Left = $window.Left; Top = $window.Top }
    [void]$panelHeader.CaptureMouse()
  } catch { Write-BallLog ('panel drag start failed: ' + $_.Exception.Message) }
})
$window.Add_MouseMove({
  param($sender, $e)
  try {
    if (-not $script:Dragging) { return }
    $point = Get-CursorPoint
    $dx = ($point.X - $script:DragStart.X) / $script:DragScale.X
    $dy = ($point.Y - $script:DragStart.Y) / $script:DragScale.Y
    if ([math]::Abs($dx) -gt 3 -or [math]::Abs($dy) -gt 3) { $script:DragMoved = $true }
    if ($script:DragMoved) {
      $window.Left = $script:DragStart.Left + $dx
      $window.Top = $script:DragStart.Top + $dy
    }
  } catch { Write-BallLog ('drag move failed: ' + $_.Exception.Message) }
})
$window.Add_LostMouseCapture({
  # A click on a non-activating window can lose the mouse capture immediately after CaptureMouse();
  # that is NOT a cancelled drag. Keep $script:Dragging intact so the matching MouseUp still opens
  # the panel, and let the watchdog below look after the poll.
  try {
    if (-not $script:Dragging -and $null -ne $poll -and -not $poll.IsEnabled) { $poll.Start() }
  } catch { }
})
$window.Add_MouseLeftButtonUp({
  param($sender, $e)
  try {
    if ($null -ne $poll) { $poll.Start() }
    if (-not $script:Dragging) { return }
    $script:Dragging = $false
    [void]$body.ReleaseMouseCapture(); [void]$ballView.ReleaseMouseCapture(); [void]$panelHeader.ReleaseMouseCapture()
    if ($script:DragMoved) {
      [void](Move-IntoVirtualScreen)
      $reportLeft = $window.Left
      if ($script:Expanded) { $reportLeft = $window.Left + $window.Width - ($script:BallSize + 50) }
      Write-BallAction @{ kind = 'pos'; x = [math]::Round($reportLeft, 1); y = [math]::Round($window.Top, 1) }
      if ($script:Expanded) { $script:CollapsedAnchor = @{ Left = $reportLeft; Top = $window.Top } }
    } elseif (-not $script:Expanded) {
      Expand-Panel
    }
  } catch { Write-BallLog ('drag end failed: ' + $_.Exception.Message) }
})
$collapseButton.Add_Click({ try { Collapse-Panel } catch { Write-BallLog ('collapse failed: ' + $_.Exception.Message) } })
$newButton.Add_Click({ Write-BallAction @{ kind = 'new' } })

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(100)
$watchdog = New-Object System.Windows.Threading.DispatcherTimer
$watchdog.Interval = [TimeSpan]::FromSeconds(1)
$watchdog.Add_Tick({
  try {
    if (-not $script:Dragging -and (-not $poll.IsEnabled)) { $poll.Start() }
  } catch { }
})
$watchdog.Start()

$poll.Add_Tick({
  try {
    if ($script:Dragging) { return }
    $raw = Read-BallStateRaw
    if ($null -eq $raw) { return }
    if ($raw -eq $script:LastRawState) { return }
    $script:LastRawState = $raw
    Apply-State ($raw | ConvertFrom-Json)
  } catch { Write-BallLog ('state tick failed: ' + $_.Exception.Message) }
})

$firstRaw = Read-BallStateRaw
if ($null -ne $firstRaw) {
  $script:LastRawState = $firstRaw
  Apply-State ($firstRaw | ConvertFrom-Json)
} else {
  Apply-Shape $false
  Set-DefaultBallPosition
}
$window.Show()
Set-BallNoActivate $true
Install-BallMouseActivateHook
if ($null -eq $whaleRotate) { Write-BallLog 'swim disabled: no whale rotate transform' }
$ballView.Add_MouseEnter({ try { Start-Swim } catch { Write-BallLog ('swim start failed: ' + $_.Exception.Message) } })
$ballView.Add_MouseLeave({ try { Stop-Swim } catch { } })
try {
  $window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try { Write-BallLog ('dispatcher error (handled): ' + $e.Exception.ToString()) } catch { }
    $e.Handled = $true
  })
} catch { }
Write-BallLog ('ball-v2 started (preview=' + [string]$Preview + ')')

# Render-to-PNG mode for tools/preview-ball.ps1 (layered windows have no usable alpha in a screen
# grab, so the preview renders the visual tree instead).
if ($env:DSH_BALL_RENDER) {
  # A render is a still: skip the cross-fade and show the final state of the requested shape.
  Stop-CrossFade
  $ballView.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  $panelView.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  if ($script:Expanded) {
    $ballView.Visibility = 'Collapsed'
    $panelView.Visibility = 'Visible'
    $panelView.Opacity = 1.0
  } else {
    $panelView.Visibility = 'Collapsed'
    $ballView.Visibility = 'Visible'
    Reset-BallViewLayout
    $ballView.Opacity = 1.0
  }
  $window.UpdateLayout()
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [Action] {})
  Set-ElementPulse 'ring' $ring $false $script:RingBreath
  if ($glow.Visibility -eq 'Visible') {
    Set-ElementPulse 'glow' $glow $false $script:GlowBreath
    if ($env:DSH_BALL_HALO) { $glow.Opacity = [double]$env:DSH_BALL_HALO }
  }
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [Action] {})
  $width = [int][math]::Ceiling($root.Width)
  $height = [int][math]::Ceiling($root.Height)
  $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $bitmap.Render($root)
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $stream = [System.IO.File]::Create($env:DSH_BALL_RENDER)
  try { $encoder.Save($stream) } finally { $stream.Close() }
  Write-BallLog ('rendered ' + $env:DSH_BALL_RENDER)
  $window.Close()
  exit 0
}

if (-not $Preview) { $poll.Start() }
[System.Windows.Threading.Dispatcher]::Run()
