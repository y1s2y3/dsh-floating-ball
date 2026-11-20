param(
  [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Original whale: drawn from scratch for this icon (NOT the DeepSeek mark). Proportions chosen to
# read as a whale at 48px while being clearly a different drawing: big head / short body, flukes
# swept up at ~45 degrees, a spout of three droplets above the head, a rounded pectoral fin and a
# small dorsal fin. Local coordinates are 0..100 and get scaled into the 1024 canvas.
$whaleBody = 'M 4 50 C 4 33 16 21 34 19 C 47 17 57 21 63 28 C 69 34 73 38 77 36 C 85 27 94 17 101 10 C 97 26 89 38 81 45 C 90 47 99 51 105 57 C 97 62 86 60 79 55 C 73 65 61 70 48 70 C 32 70 16 64 8 58 C 5 55 4 52 4 50 Z'
$whaleFin = 'M 36 63 C 32 75 38 85 50 89 C 48 81 46 73 44 67 Z'
$whaleDorsal = 'M 58 23 C 56 12 63 6 71 8 C 67 14 65 20 63 27 Z'
$whaleBelly = 'M 30 66 C 40 68 50 66 58 62'

try {
  Add-Type -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Media;
public static class Geo {
  public static Geometry Unfrozen(string path) {
    var g = Geometry.Parse(path).Clone();
    g.Freeze();
    return g;
  }
}
'@ -ReferencedAssemblies WindowsBase, PresentationCore
} catch { }

$localScale = 4.7
$localCenterX = 53.0
$localCenterY = 47.0
$offsetX = 512 - $localCenterX * $localScale
$offsetY = 508 - $localCenterY * $localScale

function To-Global([double]$x, [double]$y) {
  return New-Object System.Windows.Point(($offsetX + $x * $localScale), ($offsetY + $y * $localScale))
}

function New-Solid([int]$a, [int]$r, [int]$g, [int]$b) {
  return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

function New-RadialBrush([double]$cx, [double]$cy, [double]$radius, [object[]]$stops) {
  $brush = New-Object System.Windows.Media.RadialGradientBrush
  $brush.Center = New-Object System.Windows.Point($cx, $cy)
  $brush.GradientOrigin = New-Object System.Windows.Point($cx, $cy)
  $brush.RadiusX = $radius
  $brush.RadiusY = $radius
  foreach ($stop in $stops) {
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb($stop[0], $stop[1], $stop[2], $stop[3])), $stop[4]))
  }
  return $brush
}

function New-LinearBrush([double]$x1, [double]$y1, [double]$x2, [double]$y2, [object[]]$stops) {
  $brush = New-Object System.Windows.Media.LinearGradientBrush
  $brush.StartPoint = New-Object System.Windows.Point($x1, $y1)
  $brush.EndPoint = New-Object System.Windows.Point($x2, $y2)
  foreach ($stop in $stops) {
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb($stop[0], $stop[1], $stop[2], $stop[3])), $stop[4]))
  }
  return $brush
}

$visual = New-Object System.Windows.Media.DrawingVisual
$dc = $visual.RenderOpen()
$center = New-Object System.Windows.Point(512, 512)
$radius = 440.0

# ball
$body = New-RadialBrush 0.34 0.26 0.92 @(
  @(255, 176, 202, 255, 0.0),
  @(255, 116, 154, 253, 0.40),
  @(255, 74, 122, 232, 0.74),
  @(255, 52, 92, 200, 1.0)
)
$dc.DrawEllipse($body, $null, $center, $radius, $radius)
$dc.PushClip((New-Object System.Windows.Media.EllipseGeometry($center, $radius, $radius)))
$shade = New-RadialBrush 0.5 0.44 0.56 @(
  @(0, 10, 26, 74, 0.0),
  @(0, 10, 26, 74, 0.62),
  @(120, 10, 26, 74, 1.0)
)
$dc.DrawEllipse($shade, $null, $center, $radius, $radius)
$gloss = New-RadialBrush 0.5 0.5 0.5 @(
  @(150, 255, 255, 255, 0.0),
  @(90, 255, 255, 255, 0.45),
  @(0, 255, 255, 255, 1.0)
)
$dc.DrawEllipse($gloss, $null, (New-Object System.Windows.Point(352, 296)), 306, 214)
$dc.Pop()
$rim = New-Solid 70 40 74 160
$dc.DrawEllipse($null, (New-Object System.Windows.Media.Pen($rim, 8)), $center, $radius, $radius)

# whale: body, pectoral fin and dorsal fin are three simple white shapes drawn on top of each
# other (same colour, so the joins are invisible and no fill-rule trick is needed)
$transform = New-Object System.Windows.Media.TransformGroup
$transform.Children.Add((New-Object System.Windows.Media.ScaleTransform($localScale, $localScale)))
$transform.Children.Add((New-Object System.Windows.Media.TranslateTransform($offsetX, $offsetY)))
$whaleFill = New-LinearBrush 0 0 0 1 @(
  @(255, 255, 255, 255, 0.0),
  @(255, 232, 241, 255, 1.0)
)
$whaleFill.MappingMode = 'Absolute'
$whaleFill.StartPoint = New-Object System.Windows.Point(380, 250)
$whaleFill.EndPoint = New-Object System.Windows.Point(640, 780)
foreach ($pathData in @($whaleBody, $whaleFin, $whaleDorsal)) {
  $piece = [System.Windows.Media.Geometry]::Parse($pathData)
  $piece = $piece.Clone()
  $piece.Transform = $transform
  $dc.DrawGeometry($whaleFill, $null, $piece)
}

# eye, cut in the ball's blue so it reads on the white body
$eye = To-Global 22 44
$dc.DrawEllipse((New-Solid 235 58 96 198), $null, $eye, (2.4 * $localScale), (2.4 * $localScale))

# (no belly line: on the white body it read as a second mouth line)

# spout: three droplets above the head (different from the official mark, which has none)
$dc.DrawEllipse((New-Solid 240 255 255 255), $null, (To-Global 18 11), (2.5 * $localScale), (2.5 * $localScale))
$dc.DrawEllipse((New-Solid 190 255 255 255), $null, (To-Global 11.5 4.5), (1.6 * $localScale), (1.6 * $localScale))
$dc.DrawEllipse((New-Solid 140 255 255 255), $null, (To-Global 23 5.5), (1.1 * $localScale), (1.1 * $localScale))

# the rising bubbles keep the "floating ball" language from the first version
$dc.DrawEllipse((New-Solid 220 255 255 255), $null, (New-Object System.Windows.Point(742, 286)), 17, 17)
$dc.DrawEllipse((New-Solid 160 255 255 255), $null, (New-Object System.Windows.Point(792, 232)), 11, 11)
$dc.DrawEllipse((New-Solid 105 255 255 255), $null, (New-Object System.Windows.Point(828, 190)), 7, 7)

$dc.Close()

function Save-Png([object]$bitmap, [string]$file) {
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $stream = [System.IO.File]::Create($file)
  try { $encoder.Save($stream) } finally { $stream.Close() }
}

$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1024, 1024, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($visual)
Save-Png $rtb (Join-Path $OutDir 'icon-1024.png')
foreach ($size in @(512, 256, 128, 64, 48, 32, 16)) {
  $ratio = $size / 1024.0
  $scaled = New-Object System.Windows.Media.Imaging.TransformedBitmap($rtb, (New-Object System.Windows.Media.ScaleTransform($ratio, $ratio)))
  Save-Png $scaled (Join-Path $OutDir ("icon-$size.png"))
}
Write-Output 'original-whale icons written'
Get-ChildItem $OutDir -Filter 'icon-*.png' | Select-Object Name, Length | Format-Table -AutoSize
