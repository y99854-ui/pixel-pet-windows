param(
    [switch]$SelfTest,
    [string]$PreviewPath = "",
    [switch]$Hourly,
    [double]$IntervalMinutes = 60,
    [int]$ShowSeconds = 30,
    [ValidateSet("Auto", "GrayCat", "Corgi", "Hamster", "TuxCorgi", "BlackCat", "FlowerBloom", "Aussie")]
    [string]$PetStyle = "Auto",
    [switch]$EnsureShortcut,
    [string]$ShortcutPath = "",
    [string]$ShortcutInstallDirectory = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if ($EnsureShortcut) {
    try {
        if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
            $desktopDirectory = [Environment]::GetFolderPath("Desktop")
            $ShortcutPath = Join-Path $desktopDirectory "Pixel Pet.lnk"
        }

        $installDirectory = $ShortcutInstallDirectory
        if ([string]::IsNullOrWhiteSpace($installDirectory)) {
            $installDirectory = Join-Path $env:LOCALAPPDATA "PixelCatPet\app"
        }
        $launcherVersion = "6717"
        $firstLaunchMarker = Join-Path $installDirectory "unified-launcher.ready"
        $installedVersion = ""
        if (Test-Path -LiteralPath $firstLaunchMarker) {
            try { $installedVersion = (Get-Content -LiteralPath $firstLaunchMarker -Raw).Trim() } catch { }
        }

        # Only the first unified-launcher run creates/updates the shortcut and app copy.
        # The marker is separate from an older shortcut so upgrading this package repairs it.
        if ($installedVersion -ne $launcherVersion) {
            $packageRoot = Split-Path -Path $PSScriptRoot -Parent
            $sourceLauncher = Join-Path $packageRoot "01-Start\Start-Pixel-Pet.cmd"
            if (-not (Test-Path -LiteralPath $sourceLauncher)) {
                # The installed app keeps its launcher beside PixelPet.ps1.
                $sourceLauncher = Join-Path $PSScriptRoot "Start-Pixel-Pet.cmd"
            }
            $sourceIcon = Join-Path $PSScriptRoot "PixelCat.ico"
            $sourceHiddenLauncher = Join-Path $PSScriptRoot "Launch-Pixel-Pet.vbs"
            $installedScript = Join-Path $installDirectory "PixelPet.ps1"
            $installedLauncher = Join-Path $installDirectory "Start-Pixel-Pet.cmd"
            $installedIcon = Join-Path $installDirectory "PixelCat.ico"
            $installedHiddenLauncher = Join-Path $installDirectory "Launch-Pixel-Pet.vbs"

            foreach ($requiredFile in @($sourceLauncher, $sourceIcon, $sourceHiddenLauncher)) {
                if (-not (Test-Path -LiteralPath $requiredFile)) {
                    throw "Required shortcut file is missing: $requiredFile"
                }
            }

            New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null

            # Avoid copying a file onto itself when launched from the installed shortcut.
            if (-not [string]::Equals($PSCommandPath, $installedScript, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
            }
            if (-not [string]::Equals($sourceLauncher, $installedLauncher, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $sourceLauncher -Destination $installedLauncher -Force
            }
            if (-not [string]::Equals($sourceIcon, $installedIcon, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $sourceIcon -Destination $installedIcon -Force
            }
            if (-not [string]::Equals($sourceHiddenLauncher, $installedHiddenLauncher, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $sourceHiddenLauncher -Destination $installedHiddenLauncher -Force
            }

            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($ShortcutPath)
            $shortcut.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
            $shortcut.Arguments = "`"$installedHiddenLauncher`""
            $shortcut.WorkingDirectory = $installDirectory
            $shortcut.IconLocation = "$installedIcon,0"
            $shortcut.Description = "Start the rotating Pixel Pet"
            $shortcut.WindowStyle = 7
            $shortcut.Save()
            Set-Content -LiteralPath $firstLaunchMarker -Value $launcherVersion -Encoding ASCII
        }
    } catch {
        # Shortcut creation should never prevent the pet itself from starting.
        [System.Windows.MessageBox]::Show(
            "The desktop shortcut could not be created, but Pixel Pet will still start.`n`n$($_.Exception.Message)",
            "Pixel Pet"
        ) | Out-Null
    }
}

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PixelPetNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    public static bool TryGetCursorPosition(out int x, out int y)
    {
        POINT point;
        bool ok = GetCursorPos(out point);
        x = point.X;
        y = point.Y;
        return ok;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr RegisterPowerSettingNotification(
        IntPtr recipient,
        ref Guid settingGuid,
        int flags
    );

    [DllImport("user32.dll")]
    public static extern bool UnregisterPowerSettingNotification(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

    [DllImport("user32.dll")]
    private static extern bool SwitchDesktop(IntPtr desktop);

    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr desktop);

    public static bool IsSessionUnlocked()
    {
        const uint DESKTOP_SWITCHDESKTOP = 0x0100;
        IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
        if (desktop == IntPtr.Zero) return false;
        try { return SwitchDesktop(desktop); }
        finally { CloseDesktop(desktop); }
    }
}
"@

if ($IntervalMinutes -le 0) { throw "IntervalMinutes must be greater than zero." }
if ($ShowSeconds -le 0) { throw "ShowSeconds must be greater than zero." }

$createdNew = $false
$mutexName = "Local\CodexPixelCatPet"
if ($SelfTest -or -not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $mutexName = "Local\CodexPixelCatPetTest-$PID"
}
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    if (-not $Hourly -and -not $SelfTest -and [string]::IsNullOrWhiteSpace($PreviewPath)) {
        [System.Windows.MessageBox]::Show("Pixel Cat is already running.", "Pixel Cat") | Out-Null
    }
    exit 0
}

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$window = New-Object System.Windows.Window
$window.Title = "Pixel Cat"
$petWidth = 216.0
$petHeight = 204.0
$expandedStageSize = 620.0
$stageOffsetX = 0.0
$stageOffsetY = 0.0
$script:stageExpanded = $false
$window.Width = $petWidth
$window.Height = $petHeight
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $true
$window.SizeToContent = [System.Windows.SizeToContent]::Manual

$canvas = New-Object System.Windows.Controls.Canvas
$canvas.Width = 216
$canvas.Height = 204
$canvas.Background = [System.Windows.Media.Brushes]::Transparent

$stage = New-Object System.Windows.Controls.Canvas
$stage.Width = $petWidth
$stage.Height = $petHeight
[System.Windows.Controls.Canvas]::SetLeft($canvas, $stageOffsetX)
[System.Windows.Controls.Canvas]::SetTop($canvas, $stageOffsetY)
$stage.Children.Add($canvas) | Out-Null
$window.Content = $stage

$petScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$petRotation = New-Object System.Windows.Media.RotateTransform(0)
$petTransform = New-Object System.Windows.Media.TransformGroup
$petTransform.Children.Add($petScale) | Out-Null
$petTransform.Children.Add($petRotation) | Out-Null
$canvas.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$canvas.RenderTransform = $petTransform

$unit = 6.0
$palette = @{
    Outline = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(82, 88, 94))
    Fur     = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(221, 226, 229))
    Shade   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(181, 188, 192))
    White   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(253, 253, 251))
    Dark    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(44, 46, 47))
    Blue    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(35, 82, 164))
    Gold    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 217, 15))
    Pink    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(244, 119, 143))
    Red     = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(238, 75, 94))
    Shadow  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(45, 24, 28, 32))
    Orange  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(226, 119, 37))
    Amber   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 174, 72))
    Cream   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 222, 154))
    Brown   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(91, 39, 29))
    Cookie  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(190, 112, 43))
    Cocoa   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(105, 55, 25))
    Peach   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 165, 145))
    Navy    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(34, 54, 83))
    Wine    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(119, 38, 66))
    BlackFur = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(70, 74, 80))
    BlackShade = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(48, 52, 58))
    MintEye = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(151, 218, 178))
    AussieBase = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(139, 139, 134))
    AussieDark = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(69, 68, 66))
    AussieLight = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(190, 184, 170))
    AussieTan = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(205, 158, 105))
    AussieNose = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(205, 126, 137))
    Tongue = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(242, 112, 126))
    EyeAmber = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(184, 139, 82))
}

# A separate overlay lets the pre-jump heart grow without scaling the pet.
# buy me a coffee：https://paypal.me/GiornoMarino

# Pixel-art magic overlay shown only during the existing 6711 pet switch.
$magicCanvas = New-Object System.Windows.Controls.Canvas
$magicCanvas.Width = $petWidth
$magicCanvas.Height = $petHeight
$magicCanvas.IsHitTestVisible = $false
$magicCanvas.Visibility = [System.Windows.Visibility]::Collapsed
$magicCanvas.Opacity = 0
[System.Windows.Controls.Canvas]::SetLeft($magicCanvas, $stageOffsetX)
[System.Windows.Controls.Canvas]::SetTop($magicCanvas, $stageOffsetY)
$stage.Children.Add($magicCanvas) | Out-Null

$magicScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$magicRotation = New-Object System.Windows.Media.RotateTransform(0)
$magicTransform = New-Object System.Windows.Media.TransformGroup
$magicTransform.Children.Add($magicScale) | Out-Null
$magicTransform.Children.Add($magicRotation) | Out-Null
$magicCanvas.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$magicCanvas.RenderTransform = $magicTransform

$magicViolet = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(168, 85, 247))
$magicCyan = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(103, 232, 249))
$magicGold = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(253, 224, 71))
$magicPink = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(244, 114, 182))
$magicWhite = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(255, 255, 255))

function Add-MagicRect {
    param(
        [double]$X,
        [double]$Y,
        [double]$W,
        [double]$H,
        [System.Windows.Media.Brush]$Brush
    )

    $rect = New-Object System.Windows.Shapes.Rectangle
    $rect.Width = $W
    $rect.Height = $H
    $rect.Fill = $Brush
    $rect.SnapsToDevicePixels = $true
    [System.Windows.Controls.Canvas]::SetLeft($rect, $X)
    [System.Windows.Controls.Canvas]::SetTop($rect, $Y)
    $magicCanvas.Children.Add($rect) | Out-Null
}

function Add-MagicStar {
    param([double]$X, [double]$Y, [System.Windows.Media.Brush]$Brush)

    Add-MagicRect ($X + 9) $Y 6 24 $Brush
    Add-MagicRect $X ($Y + 9) 24 6 $Brush
    Add-MagicRect ($X + 6) ($Y + 6) 12 12 $Brush
}

$ringPoints = @(
    @(102, 10), @(143, 21), @(177, 51), @(191, 94),
    @(177, 139), @(143, 169), @(102, 180), @(61, 169),
    @(27, 139), @(13, 94), @(27, 51), @(61, 21)
)
$ringBrushes = @($magicViolet, $magicCyan, $magicGold, $magicPink)
for ($pointIndex = 0; $pointIndex -lt $ringPoints.Count; $pointIndex++) {
    $point = $ringPoints[$pointIndex]
    Add-MagicRect $point[0] $point[1] 12 8 $ringBrushes[$pointIndex % $ringBrushes.Count]
}
Add-MagicStar 18 24 $magicGold
Add-MagicStar 174 22 $magicCyan
Add-MagicStar 22 151 $magicPink
Add-MagicStar 170 149 $magicViolet
Add-MagicRect 102 72 12 60 $magicWhite
Add-MagicRect 78 96 60 12 $magicWhite
Add-MagicRect 96 90 24 24 $magicGold

function Show-MagicTransition {
    $magicCanvas.Visibility = [System.Windows.Visibility]::Visible
    $magicCanvas.Opacity = 0
    $magicScale.ScaleX = 0.35
    $magicScale.ScaleY = 0.35
    $magicRotation.Angle = 0
}

function Hide-MagicTransition {
    $magicCanvas.Visibility = [System.Windows.Visibility]::Collapsed
    $magicCanvas.Opacity = 0
    $magicScale.ScaleX = 1
    $magicScale.ScaleY = 1
    $magicRotation.Angle = 0
}

$bigHeartCanvas = New-Object System.Windows.Controls.Canvas
$bigHeartCanvas.Width = 120
$bigHeartCanvas.Height = 92
$bigHeartCanvas.IsHitTestVisible = $false
$bigHeartCanvas.Visibility = [System.Windows.Visibility]::Collapsed
[System.Windows.Controls.Canvas]::SetLeft($bigHeartCanvas, $stageOffsetX + (($petWidth - $bigHeartCanvas.Width) / 2))
[System.Windows.Controls.Canvas]::SetTop($bigHeartCanvas, $stageOffsetY - 62)
$stage.Children.Add($bigHeartCanvas) | Out-Null

$bigHeartScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$bigHeartRotation = New-Object System.Windows.Media.RotateTransform(0)
$bigHeartTransform = New-Object System.Windows.Media.TransformGroup
$bigHeartTransform.Children.Add($bigHeartScale) | Out-Null
$bigHeartTransform.Children.Add($bigHeartRotation) | Out-Null
$bigHeartCanvas.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.72)
$bigHeartCanvas.RenderTransform = $bigHeartTransform

function Add-BigHeartRect {
    param([double]$X, [double]$Y, [double]$W, [double]$H)

    $heartUnit = 6.0
    $rect = New-Object System.Windows.Shapes.Rectangle
    $rect.Width = $W * $heartUnit
    $rect.Height = $H * $heartUnit
    $rect.Fill = $palette.Red
    [System.Windows.Controls.Canvas]::SetLeft($rect, $X * $heartUnit)
    [System.Windows.Controls.Canvas]::SetTop($rect, $Y * $heartUnit)
    $bigHeartCanvas.Children.Add($rect) | Out-Null
}

# Large 90 x 72 pixel heart used as a clear anticipation cue.
Add-BigHeartRect 3 0 4 3
Add-BigHeartRect 10 0 4 3
Add-BigHeartRect 1 2 15 4
Add-BigHeartRect 3 6 11 2
Add-BigHeartRect 5 8 7 2
Add-BigHeartRect 7 10 3 2

function Show-BigHeart {
    $bigHeartCanvas.Opacity = 0
    $bigHeartScale.ScaleX = 0.35
    $bigHeartScale.ScaleY = 0.35
    $bigHeartRotation.Angle = 0
    $bigHeartCanvas.Visibility = [System.Windows.Visibility]::Visible
}

function Hide-BigHeart {
    $bigHeartCanvas.Visibility = [System.Windows.Visibility]::Collapsed
    $bigHeartCanvas.Opacity = 0
    $bigHeartScale.ScaleX = 1
    $bigHeartScale.ScaleY = 1
    $bigHeartRotation.Angle = 0
}

function Add-PixelRect {
    param(
        [double]$X,
        [double]$Y,
        [double]$W,
        [double]$H,
        [System.Windows.Media.Brush]$Brush,
        [double]$YOffset = 0
    )

    $rect = New-Object System.Windows.Shapes.Rectangle
    $rect.Width = $W * $unit
    $rect.Height = $H * $unit
    $rect.Fill = $Brush
    [System.Windows.Controls.Canvas]::SetLeft($rect, $X * $unit)
    [System.Windows.Controls.Canvas]::SetTop($rect, ($Y * $unit) + $YOffset)
    $canvas.Children.Add($rect) | Out-Null
}

function Draw-Heart {
    param([double]$YOffset)

    Add-PixelRect 18 0 2 2 $palette.Red $YOffset
    Add-PixelRect 21 0 2 2 $palette.Red $YOffset
    Add-PixelRect 17 1 7 3 $palette.Red $YOffset
    Add-PixelRect 18 4 5 1 $palette.Red $YOffset
    Add-PixelRect 19 5 3 1 $palette.Red $YOffset
    Add-PixelRect 20 6 1 1 $palette.Red $YOffset
}

function Draw-Cat {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()

    # Pixel shadow.
    Add-PixelRect 10 31 20 1 $palette.Shadow 0
    Add-PixelRect 13 32 14 1 $palette.Shadow 0

    # Tail, behind the body. Two frames make a gentle wag.
    Add-PixelRect 3 18 8 4 $palette.Outline $YOffset
    Add-PixelRect 2 15 3 5 $palette.Outline $YOffset
    Add-PixelRect 4 13 5 3 $palette.Outline $YOffset
    Add-PixelRect 8 15 3 7 $palette.Outline $YOffset
    Add-PixelRect 4 19 5 2 $palette.Fur $YOffset
    Add-PixelRect 5 15 3 4 $palette.Fur $YOffset
    if ($TailFrame -eq 0) {
        Add-PixelRect 1 14 3 3 $palette.Outline $YOffset
        Add-PixelRect 0 15 2 2 $palette.Outline $YOffset
    } else {
        Add-PixelRect 2 12 3 3 $palette.Outline $YOffset
        Add-PixelRect 1 11 2 2 $palette.Outline $YOffset
    }

    # Body and paws.
    Add-PixelRect 10 20 20 10 $palette.Outline $YOffset
    Add-PixelRect 12 21 16 8 $palette.Fur $YOffset
    Add-PixelRect 12 27 6 4 $palette.Outline $YOffset
    Add-PixelRect 23 27 6 4 $palette.Outline $YOffset
    Add-PixelRect 14 26 3 4 $palette.Fur $YOffset
    Add-PixelRect 24 26 3 4 $palette.Fur $YOffset

    # Head, ears, and light-gray markings.
    Add-PixelRect 8 6 23 17 $palette.Outline $YOffset
    Add-PixelRect 10 2 6 7 $palette.Outline $YOffset
    Add-PixelRect 25 2 6 7 $palette.Outline $YOffset
    Add-PixelRect 12 4 3 4 $palette.Shade $YOffset
    Add-PixelRect 26 4 3 4 $palette.Shade $YOffset
    Add-PixelRect 10 7 19 14 $palette.Fur $YOffset
    Add-PixelRect 15 5 11 4 $palette.Fur $YOffset
    Add-PixelRect 10 8 3 6 $palette.Shade $YOffset
    Add-PixelRect 27 8 2 6 $palette.Shade $YOffset
    Add-PixelRect 11 7 3 3 $palette.Shade $YOffset
    Add-PixelRect 26 7 3 3 $palette.Shade $YOffset

    # Eyes, muzzle, nose, and tiny cheeks.
    if ($Blink) {
        Add-PixelRect 14 13 3 1 $palette.Dark $YOffset
        Add-PixelRect 24 13 3 1 $palette.Dark $YOffset
    } else {
        Add-PixelRect 14 11 2 4 $palette.Dark $YOffset
        Add-PixelRect 25 11 2 4 $palette.Dark $YOffset
    }
    Add-PixelRect 15 15 11 5 $palette.White $YOffset
    Add-PixelRect 19 16 3 2 $palette.Dark $YOffset
    Add-PixelRect 13 16 2 1 $palette.Pink $YOffset
    Add-PixelRect 26 16 2 1 $palette.Pink $YOffset

    # Blue collar and yellow tag.
    Add-PixelRect 12 20 17 2 $palette.Blue $YOffset
    Add-PixelRect 19 22 3 3 $palette.Gold $YOffset

    if ($ShowHeart) {
        Draw-Heart ($YOffset - 2)
    }
}

function Draw-Corgi {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()
    Add-PixelRect 8 31 23 1 $palette.Shadow 0
    Add-PixelRect 11 32 17 1 $palette.Shadow 0

    # Upright fluffy tail, behind the body.
    if ($TailFrame -eq 0) {
        Add-PixelRect 28 12 4 12 $palette.Brown $YOffset
        Add-PixelRect 29 10 4 10 $palette.Orange $YOffset
        Add-PixelRect 30 9 3 5 $palette.White $YOffset
    } else {
        Add-PixelRect 29 13 4 11 $palette.Brown $YOffset
        Add-PixelRect 30 11 4 9 $palette.Orange $YOffset
        Add-PixelRect 31 10 3 5 $palette.White $YOffset
    }

    # Body, chest, short legs.
    Add-PixelRect 11 18 20 11 $palette.Brown $YOffset
    Add-PixelRect 13 18 16 10 $palette.Orange $YOffset
    Add-PixelRect 14 20 7 8 $palette.White $YOffset
    Add-PixelRect 12 27 6 4 $palette.Brown $YOffset
    Add-PixelRect 24 27 6 4 $palette.Brown $YOffset
    Add-PixelRect 13 27 4 3 $palette.White $YOffset
    Add-PixelRect 25 27 4 3 $palette.White $YOffset

    # Large ears and corgi head.
    Add-PixelRect 6 3 7 11 $palette.Brown $YOffset
    Add-PixelRect 7 1 5 10 $palette.Orange $YOffset
    Add-PixelRect 8 3 3 6 $palette.Peach $YOffset
    Add-PixelRect 24 3 7 11 $palette.Brown $YOffset
    Add-PixelRect 25 1 5 10 $palette.Orange $YOffset
    Add-PixelRect 26 3 3 6 $palette.Peach $YOffset
    Add-PixelRect 7 9 24 13 $palette.Brown $YOffset
    Add-PixelRect 9 8 20 13 $palette.Orange $YOffset
    Add-PixelRect 16 7 6 11 $palette.White $YOffset
    Add-PixelRect 12 15 14 6 $palette.White $YOffset
    Add-PixelRect 9 14 4 5 $palette.Amber $YOffset
    Add-PixelRect 27 14 3 5 $palette.Amber $YOffset

    if ($Blink) {
        Add-PixelRect 12 13 3 1 $palette.Brown $YOffset
        Add-PixelRect 24 13 3 1 $palette.Brown $YOffset
    } else {
        Add-PixelRect 12 11 3 3 $palette.Brown $YOffset
        Add-PixelRect 24 11 3 3 $palette.Brown $YOffset
        Add-PixelRect 13 11 1 1 $palette.White $YOffset
        Add-PixelRect 25 11 1 1 $palette.White $YOffset
    }
    Add-PixelRect 18 15 4 3 $palette.Brown $YOffset
    Add-PixelRect 17 18 2 1 $palette.Brown $YOffset
    Add-PixelRect 21 18 2 1 $palette.Brown $YOffset
    Add-PixelRect 18 19 4 3 $palette.Peach $YOffset

    if ($ShowHeart) { Draw-Heart ($YOffset - 2) }
}

function Draw-Hamster {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()
    Add-PixelRect 8 31 23 1 $palette.Shadow 0
    Add-PixelRect 11 32 17 1 $palette.Shadow 0

    # Curled orange tail.
    if ($TailFrame -eq 0) {
        Add-PixelRect 29 21 5 8 $palette.Outline $YOffset
        Add-PixelRect 30 22 3 6 $palette.Orange $YOffset
        Add-PixelRect 31 22 2 2 $palette.Peach $YOffset
    } else {
        Add-PixelRect 30 20 4 9 $palette.Outline $YOffset
        Add-PixelRect 31 21 2 7 $palette.Orange $YOffset
        Add-PixelRect 31 21 2 2 $palette.Peach $YOffset
    }

    # Round seated body and feet.
    Add-PixelRect 9 18 22 12 $palette.Outline $YOffset
    Add-PixelRect 11 18 18 11 $palette.White $YOffset
    Add-PixelRect 11 18 5 7 $palette.Peach $YOffset
    Add-PixelRect 24 18 5 7 $palette.Peach $YOffset
    Add-PixelRect 8 27 8 4 $palette.Outline $YOffset
    Add-PixelRect 25 27 8 4 $palette.Outline $YOffset
    Add-PixelRect 10 27 5 3 $palette.White $YOffset
    Add-PixelRect 26 27 5 3 $palette.White $YOffset

    # Hamster head, ears, and patches.
    Add-PixelRect 7 6 27 15 $palette.Outline $YOffset
    Add-PixelRect 9 4 7 7 $palette.Outline $YOffset
    Add-PixelRect 10 5 5 5 $palette.Peach $YOffset
    Add-PixelRect 26 4 7 7 $palette.Outline $YOffset
    Add-PixelRect 27 5 5 5 $palette.Peach $YOffset
    Add-PixelRect 9 7 23 13 $palette.White $YOffset
    Add-PixelRect 9 7 12 8 $palette.Peach $YOffset
    Add-PixelRect 10 7 6 4 $palette.Orange $YOffset
    Add-PixelRect 11 9 2 2 $palette.Cookie $YOffset

    if ($Blink) {
        Add-PixelRect 13 14 3 1 $palette.Dark $YOffset
        Add-PixelRect 25 14 3 1 $palette.Dark $YOffset
    } else {
        Add-PixelRect 12 12 4 4 $palette.Dark $YOffset
        Add-PixelRect 25 12 4 4 $palette.Dark $YOffset
        Add-PixelRect 13 12 1 1 $palette.White $YOffset
        Add-PixelRect 26 12 1 1 $palette.White $YOffset
    }
    Add-PixelRect 10 16 3 2 $palette.Pink $YOffset
    Add-PixelRect 29 16 3 2 $palette.Pink $YOffset
    Add-PixelRect 19 15 3 2 $palette.Dark $YOffset
    Add-PixelRect 17 17 2 1 $palette.Dark $YOffset
    Add-PixelRect 22 17 2 1 $palette.Dark $YOffset

    # Cookie held between the paws.
    Add-PixelRect 16 20 9 9 $palette.Cocoa $YOffset
    Add-PixelRect 17 21 7 7 $palette.Cookie $YOffset
    Add-PixelRect 18 22 2 2 $palette.Cocoa $YOffset
    Add-PixelRect 22 23 1 2 $palette.Cocoa $YOffset
    Add-PixelRect 19 26 2 1 $palette.Cocoa $YOffset
    Add-PixelRect 14 21 3 5 $palette.White $YOffset
    Add-PixelRect 25 21 3 5 $palette.White $YOffset

    if ($ShowHeart) { Draw-Heart ($YOffset - 2) }
}

function Draw-TuxCorgi {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()
    Add-PixelRect 9 31 22 1 $palette.Shadow 0
    Add-PixelRect 12 32 16 1 $palette.Shadow 0

    # Small wagging tail behind the jacket.
    if ($TailFrame -eq 0) {
        Add-PixelRect 29 22 4 4 $palette.Brown $YOffset
        Add-PixelRect 30 21 3 3 $palette.Orange $YOffset
    } else {
        Add-PixelRect 30 20 4 4 $palette.Brown $YOffset
        Add-PixelRect 31 19 3 3 $palette.Orange $YOffset
    }

    # Suit jacket, shirt, legs, and gold button.
    Add-PixelRect 10 18 22 12 $palette.Outline $YOffset
    Add-PixelRect 12 18 18 10 $palette.Navy $YOffset
    Add-PixelRect 18 18 5 10 $palette.White $YOffset
    Add-PixelRect 12 18 6 7 $palette.Navy $YOffset
    Add-PixelRect 23 18 7 7 $palette.Navy $YOffset
    Add-PixelRect 10 26 7 4 $palette.Outline $YOffset
    Add-PixelRect 25 26 7 4 $palette.Outline $YOffset
    Add-PixelRect 12 26 4 3 $palette.White $YOffset
    Add-PixelRect 26 26 4 3 $palette.White $YOffset
    Add-PixelRect 20 24 2 2 $palette.Gold $YOffset

    # Corgi head and tall ears.
    Add-PixelRect 7 3 7 11 $palette.Brown $YOffset
    Add-PixelRect 8 1 5 10 $palette.Orange $YOffset
    Add-PixelRect 9 3 3 6 $palette.Peach $YOffset
    Add-PixelRect 26 3 7 11 $palette.Brown $YOffset
    Add-PixelRect 27 1 5 10 $palette.Orange $YOffset
    Add-PixelRect 28 3 3 6 $palette.Peach $YOffset
    Add-PixelRect 8 8 25 13 $palette.Brown $YOffset
    Add-PixelRect 10 7 21 13 $palette.Orange $YOffset
    Add-PixelRect 17 8 7 10 $palette.White $YOffset
    Add-PixelRect 12 15 17 6 $palette.White $YOffset

    if ($Blink) {
        Add-PixelRect 13 13 3 1 $palette.Brown $YOffset
        Add-PixelRect 26 13 3 1 $palette.Brown $YOffset
    } else {
        Add-PixelRect 13 11 3 3 $palette.Brown $YOffset
        Add-PixelRect 26 11 3 3 $palette.Brown $YOffset
        Add-PixelRect 14 11 1 1 $palette.White $YOffset
        Add-PixelRect 27 11 1 1 $palette.White $YOffset
    }
    Add-PixelRect 19 15 4 3 $palette.Dark $YOffset
    Add-PixelRect 18 18 2 1 $palette.Dark $YOffset
    Add-PixelRect 22 18 2 1 $palette.Dark $YOffset

    # Burgundy bow tie.
    Add-PixelRect 16 19 4 3 $palette.Wine $YOffset
    Add-PixelRect 22 19 4 3 $palette.Wine $YOffset
    Add-PixelRect 20 20 2 2 $palette.Wine $YOffset

    if ($ShowHeart) { Draw-Heart ($YOffset - 2) }
}

function Draw-BlackCat {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()
    Add-PixelRect 9 31 22 1 $palette.Shadow 0
    Add-PixelRect 12 32 16 1 $palette.Shadow 0

    # Long curled tail behind the body.
    Add-PixelRect 28 19 5 11 $palette.Dark $YOffset
    Add-PixelRect 29 20 3 9 $palette.BlackShade $YOffset
    if ($TailFrame -eq 0) {
        Add-PixelRect 31 14 4 8 $palette.Dark $YOffset
        Add-PixelRect 32 15 2 6 $palette.BlackFur $YOffset
    } else {
        Add-PixelRect 30 13 4 8 $palette.Dark $YOffset
        Add-PixelRect 31 14 2 6 $palette.BlackFur $YOffset
    }

    # Sitting body and paws.
    Add-PixelRect 10 19 21 11 $palette.Dark $YOffset
    Add-PixelRect 12 19 17 10 $palette.BlackFur $YOffset
    Add-PixelRect 11 27 7 4 $palette.Dark $YOffset
    Add-PixelRect 24 27 7 4 $palette.Dark $YOffset
    Add-PixelRect 13 27 4 3 $palette.BlackFur $YOffset
    Add-PixelRect 25 27 4 3 $palette.BlackFur $YOffset
    Add-PixelRect 18 21 6 8 $palette.BlackShade $YOffset

    # Pointed ears and charcoal face.
    Add-PixelRect 7 4 8 10 $palette.Dark $YOffset
    Add-PixelRect 9 1 5 10 $palette.BlackFur $YOffset
    Add-PixelRect 10 3 3 5 $palette.BlackShade $YOffset
    Add-PixelRect 26 4 8 10 $palette.Dark $YOffset
    Add-PixelRect 27 1 5 10 $palette.BlackFur $YOffset
    Add-PixelRect 28 3 3 5 $palette.BlackShade $YOffset
    Add-PixelRect 8 8 25 14 $palette.Dark $YOffset
    Add-PixelRect 10 7 21 14 $palette.BlackFur $YOffset
    Add-PixelRect 12 8 7 4 $palette.BlackShade $YOffset
    Add-PixelRect 25 8 5 4 $palette.BlackShade $YOffset

    if ($Blink) {
        Add-PixelRect 12 14 5 1 $palette.Dark $YOffset
        Add-PixelRect 25 14 5 1 $palette.Dark $YOffset
    } else {
        Add-PixelRect 12 12 5 2 $palette.Dark $YOffset
        Add-PixelRect 25 12 5 2 $palette.Dark $YOffset
        Add-PixelRect 14 12 2 1 $palette.MintEye $YOffset
        Add-PixelRect 26 12 2 1 $palette.MintEye $YOffset
    }
    Add-PixelRect 10 15 5 2 $palette.Pink $YOffset
    Add-PixelRect 27 15 5 2 $palette.Pink $YOffset
    Add-PixelRect 19 14 4 3 $palette.Dark $YOffset
    Add-PixelRect 18 17 2 1 $palette.Dark $YOffset
    Add-PixelRect 23 17 2 1 $palette.Dark $YOffset

    if ($ShowHeart) { Draw-Heart ($YOffset - 2) }
}

function Draw-FlowerBloom {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    $canvas.Children.Clear()
    Add-PixelRect 7 31 27 1 $palette.Shadow 0
    Add-PixelRect 10 32 21 1 $palette.Shadow 0

    # Shaggy side tail, with two gentle wag positions.
    if ($TailFrame -eq 0) {
        Add-PixelRect 2 20 9 7 $palette.Outline $YOffset
        Add-PixelRect 1 22 5 6 $palette.AussieLight $YOffset
        Add-PixelRect 3 19 6 5 $palette.AussieDark $YOffset
        Add-PixelRect 1 26 5 2 $palette.White $YOffset
    } else {
        Add-PixelRect 2 18 9 8 $palette.Outline $YOffset
        Add-PixelRect 1 19 5 6 $palette.AussieLight $YOffset
        Add-PixelRect 3 17 6 5 $palette.AussieDark $YOffset
        Add-PixelRect 1 24 5 2 $palette.White $YOffset
    }

    # Broad fluffy body and the two large white front paws.
    Add-PixelRect 8 18 26 11 $palette.Outline $YOffset
    Add-PixelRect 10 18 22 10 $palette.AussieLight $YOffset
    Add-PixelRect 11 19 6 8 $palette.AussieBase $YOffset
    Add-PixelRect 25 19 6 8 $palette.AussieDark $YOffset
    Add-PixelRect 17 18 9 11 $palette.White $YOffset
    Add-PixelRect 7 25 10 6 $palette.Outline $YOffset
    Add-PixelRect 25 25 10 6 $palette.Outline $YOffset
    Add-PixelRect 9 25 7 5 $palette.White $YOffset
    Add-PixelRect 26 25 7 5 $palette.White $YOffset
    Add-PixelRect 10 29 1 2 $palette.AussieLight $YOffset
    Add-PixelRect 13 29 1 2 $palette.AussieLight $YOffset
    Add-PixelRect 28 29 1 2 $palette.AussieLight $YOffset
    Add-PixelRect 31 29 1 2 $palette.AussieLight $YOffset

    # Drooping merle ears, including uneven shaggy tips.
    Add-PixelRect 4 5 9 14 $palette.Outline $YOffset
    Add-PixelRect 5 4 8 12 $palette.AussieDark $YOffset
    Add-PixelRect 4 8 5 10 $palette.AussieBase $YOffset
    Add-PixelRect 3 15 5 5 $palette.AussieDark $YOffset
    Add-PixelRect 6 6 3 3 $palette.AussieLight $YOffset
    Add-PixelRect 29 5 8 14 $palette.Outline $YOffset
    Add-PixelRect 30 5 6 12 $palette.AussieDark $YOffset
    Add-PixelRect 33 10 4 9 $palette.AussieBase $YOffset
    Add-PixelRect 34 16 3 4 $palette.AussieDark $YOffset
    Add-PixelRect 31 7 3 3 $palette.AussieLight $YOffset

    # Rounded head: blue-merle sides, cream blaze and tan markings.
    Add-PixelRect 7 5 28 16 $palette.Outline $YOffset
    Add-PixelRect 9 4 24 16 $palette.AussieBase $YOffset
    Add-PixelRect 10 5 8 8 $palette.AussieDark $YOffset
    Add-PixelRect 27 5 5 9 $palette.AussieDark $YOffset
    Add-PixelRect 9 12 6 7 $palette.AussieDark $YOffset
    Add-PixelRect 28 13 5 6 $palette.AussieDark $YOffset
    Add-PixelRect 18 4 8 13 $palette.White $YOffset
    Add-PixelRect 16 7 12 11 $palette.White $YOffset
    Add-PixelRect 12 9 5 4 $palette.AussieTan $YOffset
    Add-PixelRect 27 9 4 4 $palette.AussieTan $YOffset
    Add-PixelRect 10 14 5 4 $palette.AussieTan $YOffset
    Add-PixelRect 29 14 4 4 $palette.AussieTan $YOffset
    Add-PixelRect 13 6 2 2 $palette.AussieLight $YOffset
    Add-PixelRect 29 5 2 2 $palette.AussieLight $YOffset

    # Warm brown eyes with white glints, or a single dark line when blinking.
    if ($Blink) {
        Add-PixelRect 13 12 4 1 $palette.Dark $YOffset
        Add-PixelRect 27 12 4 1 $palette.Dark $YOffset
    } else {
        Add-PixelRect 13 10 4 4 $palette.Dark $YOffset
        Add-PixelRect 27 10 4 4 $palette.Dark $YOffset
        Add-PixelRect 14 11 2 2 $palette.EyeAmber $YOffset
        Add-PixelRect 28 11 2 2 $palette.EyeAmber $YOffset
        Add-PixelRect 14 10 1 1 $palette.White $YOffset
        Add-PixelRect 28 10 1 1 $palette.White $YOffset
    }

    # Cream muzzle, mottled pink nose, smiling mouth, and hanging tongue.
    Add-PixelRect 15 14 14 6 $palette.White $YOffset
    Add-PixelRect 19 14 6 4 $palette.AussieNose $YOffset
    Add-PixelRect 20 15 2 1 $palette.Peach $YOffset
    Add-PixelRect 23 16 1 1 $palette.Brown $YOffset
    Add-PixelRect 18 18 3 1 $palette.Dark $YOffset
    Add-PixelRect 24 18 3 1 $palette.Dark $YOffset
    Add-PixelRect 20 19 6 4 $palette.Dark $YOffset
    Add-PixelRect 20 19 4 5 $palette.Tongue $YOffset
    Add-PixelRect 22 19 2 4 $palette.Pink $YOffset

    if ($ShowHeart) { Draw-Heart ($YOffset - 2) }
}

function Draw-Pet {
    param(
        [int]$TailFrame,
        [bool]$Blink,
        [double]$YOffset,
        [bool]$ShowHeart
    )

    switch ($script:petStyle) {
        "Corgi"    { Draw-Corgi $TailFrame $Blink $YOffset $ShowHeart }
        "Hamster"  { Draw-Hamster $TailFrame $Blink $YOffset $ShowHeart }
        "TuxCorgi" { Draw-TuxCorgi $TailFrame $Blink $YOffset $ShowHeart }
        "BlackCat" { Draw-BlackCat $TailFrame $Blink $YOffset $ShowHeart }
        "FlowerBloom" { Draw-FlowerBloom $TailFrame $Blink $YOffset $ShowHeart }
        "Aussie"      { Draw-FlowerBloom $TailFrame $Blink $YOffset $ShowHeart }
        default     { Draw-Cat $TailFrame $Blink $YOffset $ShowHeart }
    }
}

function Clamp-ToWorkArea {
    $area = [System.Windows.SystemParameters]::WorkArea
    $petLeft = $window.Left + $stageOffsetX
    $petTop = $window.Top + $stageOffsetY
    $maxLeft = $area.Right - $petWidth
    $maxTop = $area.Bottom - $petHeight
    $petLeft = [Math]::Max($area.Left, [Math]::Min($petLeft, $maxLeft))
    $petTop = [Math]::Max($area.Top, [Math]::Min($petTop, $maxTop))
    $window.Left = $petLeft - $stageOffsetX
    $window.Top = $petTop - $stageOffsetY
}

function Get-PetLeft {
    return ($window.Left + $stageOffsetX)
}

function Get-PetTop {
    return ($window.Top + $stageOffsetY)
}

function Set-PetPosition {
    param([double]$Left, [double]$Top)

    $window.Left = $Left - $stageOffsetX
    $window.Top = $Top - $stageOffsetY
}

function Set-PetCenter {
    param([double]$CenterX, [double]$CenterY)

    $window.Left = $CenterX - $stageOffsetX - ($petWidth / 2)
    $window.Top = $CenterY - $stageOffsetY - ($petHeight / 2)
}

function Set-PetTransform {
    param([double]$ScaleX, [double]$ScaleY, [double]$Angle)

    $petScale.ScaleX = $ScaleX
    $petScale.ScaleY = $ScaleY
    $petRotation.Angle = $Angle
}

function Set-StageExpanded {
    param([bool]$Expanded)

    if ($script:stageExpanded -eq $Expanded) { return }

    # Preserve the pet's screen coordinates while changing only the transparent margin.
    $petLeft = Get-PetLeft
    $petTop = Get-PetTop
    if ($Expanded) {
        $newWidth = $expandedStageSize
        $newHeight = $expandedStageSize
        $newOffsetX = ($expandedStageSize - $petWidth) / 2
        $newOffsetY = ($expandedStageSize - $petHeight) / 2
    } else {
        $newWidth = $petWidth
        $newHeight = $petHeight
        $newOffsetX = 0.0
        $newOffsetY = 0.0
    }

    $script:stageOffsetX = $newOffsetX
    $script:stageOffsetY = $newOffsetY
    $stage.Width = $newWidth
    $stage.Height = $newHeight
    $window.Width = $newWidth
    $window.Height = $newHeight
    [System.Windows.Controls.Canvas]::SetLeft($canvas, $stageOffsetX)
    [System.Windows.Controls.Canvas]::SetTop($canvas, $stageOffsetY)
    [System.Windows.Controls.Canvas]::SetLeft($magicCanvas, $stageOffsetX)
    [System.Windows.Controls.Canvas]::SetTop($magicCanvas, $stageOffsetY)
    [System.Windows.Controls.Canvas]::SetLeft($bigHeartCanvas, $stageOffsetX + (($petWidth - $bigHeartCanvas.Width) / 2))
    [System.Windows.Controls.Canvas]::SetTop($bigHeartCanvas, $stageOffsetY - 62)
    $window.Left = $petLeft - $stageOffsetX
    $window.Top = $petTop - $stageOffsetY
    $script:stageExpanded = $Expanded
}

function Ease-OutCubic {
    param([double]$T)
    return (1.0 - [Math]::Pow(1.0 - $T, 3))
}

function Ease-InCubic {
    param([double]$T)
    return ($T * $T * $T)
}

function Ease-InOutCubic {
    param([double]$T)
    if ($T -lt 0.5) { return (4 * $T * $T * $T) }
    return (1 - [Math]::Pow(-2 * $T + 2, 3) / 2)
}

$settingsDirectory = Join-Path $env:LOCALAPPDATA "PixelCatPet"
$settingsPath = Join-Path $settingsDirectory "settings.json"
$styleStatePath = Join-Path $settingsDirectory "style-state.json"
$petStyles = @("GrayCat", "Corgi", "Hamster", "TuxCorgi", "BlackCat", "FlowerBloom")
$petNames = @{
    GrayCat = "Gray Cat"
    Corgi = "Corgi"
    Hamster = "Cookie Hamster"
    TuxCorgi = "Tuxedo Corgi"
    BlackCat = "Black Cat"
    FlowerBloom = "花开 / FlowerBloom"
    Aussie = "花开 / FlowerBloom"
}
$script:petStyle = $PetStyle

if ($script:petStyle -eq "Auto") {
    $lastStyleIndex = -1
    if (Test-Path -LiteralPath $styleStatePath) {
        try {
            $styleState = Get-Content -LiteralPath $styleStatePath -Raw | ConvertFrom-Json
            if ($null -ne $styleState.lastIndex) {
                $lastStyleIndex = [int]$styleState.lastIndex
            }
        } catch {
            $lastStyleIndex = -1
        }
    }

    $currentStyleIndex = ($lastStyleIndex + 1) % $petStyles.Count
    $script:petStyle = $petStyles[$currentStyleIndex]

    # Preview and self-test modes must not consume a turn in the visible rotation.
    if (-not $SelfTest -and [string]::IsNullOrWhiteSpace($PreviewPath)) {
        try {
            New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
            @{ lastIndex = $currentStyleIndex } | ConvertTo-Json | Set-Content -LiteralPath $styleStatePath -Encoding UTF8
        } catch {
            # Rotation persistence is optional; the pet should still run.
        }
    }
}

$window.Title = "Pixel Pet - $($petNames[$script:petStyle])"
$area = [System.Windows.SystemParameters]::WorkArea
$initialPetLeft = $area.Right - $petWidth - 28
$initialPetTop = $area.Bottom - $petHeight - 8
Set-PetPosition $initialPetLeft $initialPetTop
$script:wanderEnabled = $true
$opacityLevels = @(1.0, 0.8, 0.6, 0.4, 0.2)
$script:petOpacity = 1.0

if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if (($null -ne $saved.left) -and ($null -ne $saved.top)) {
            Set-PetPosition ([double]$saved.left) ([double]$saved.top)
        }
        if ($null -ne $saved.wander) { $script:wanderEnabled = [bool]$saved.wander }
        if ($null -ne $saved.topmost) { $window.Topmost = [bool]$saved.topmost }
        if ($null -ne $saved.opacity) {
            $savedOpacity = [double]$saved.opacity
            if (($savedOpacity -ge 0.2) -and ($savedOpacity -le 1.0)) {
                # Snap hand-edited settings to the nearest supported menu level.
                $nearestOpacity = $opacityLevels[0]
                $nearestDistance = [Math]::Abs($savedOpacity - $nearestOpacity)
                foreach ($level in $opacityLevels) {
                    $distance = [Math]::Abs($savedOpacity - $level)
                    if ($distance -lt $nearestDistance) {
                        $nearestOpacity = $level
                        $nearestDistance = $distance
                    }
                }
                $script:petOpacity = $nearestOpacity
            }
        }
    } catch {
        # Ignore a damaged settings file and use safe defaults.
    }
}
$window.Opacity = $script:petOpacity
Clamp-ToWorkArea

$menu = New-Object System.Windows.Controls.ContextMenu
$wanderItem = New-Object System.Windows.Controls.MenuItem
$wanderItem.Header = "Wandering"
$wanderItem.IsCheckable = $true
$wanderItem.IsChecked = $script:wanderEnabled
$topmostItem = New-Object System.Windows.Controls.MenuItem
$topmostItem.Header = "Always on top"
$topmostItem.IsCheckable = $true
$topmostItem.IsChecked = $window.Topmost
$opacityMenu = New-Object System.Windows.Controls.MenuItem
$opacityMenu.Header = "Opacity / $([char]0x900F)$([char]0x660E)$([char]0x5EA6)"
$script:opacityItems = @()
foreach ($level in $opacityLevels) {
    $opacityItem = New-Object System.Windows.Controls.MenuItem
    $opacityItem.Header = "{0}%" -f [int]($level * 100)
    $opacityItem.Tag = [double]$level
    $opacityItem.IsCheckable = $true
    $opacityItem.IsChecked = ([Math]::Abs($script:petOpacity - $level) -lt 0.001)
    $opacityItem.Add_Click({
        param($sender, $eventArgs)

        $script:petOpacity = [double]$sender.Tag
        $window.Opacity = $script:petOpacity
        foreach ($item in $script:opacityItems) {
            $item.IsChecked = ([Math]::Abs(([double]$item.Tag) - $script:petOpacity) -lt 0.001)
        }
    })
    $script:opacityItems += $opacityItem
    $opacityMenu.Items.Add($opacityItem) | Out-Null
}
$homeItem = New-Object System.Windows.Controls.MenuItem
$homeItem.Header = "Back to bottom-right"
$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = "Exit"

$menu.Items.Add($wanderItem) | Out-Null
$menu.Items.Add($topmostItem) | Out-Null
$menu.Items.Add($opacityMenu) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add($homeItem) | Out-Null
$menu.Items.Add($exitItem) | Out-Null
$canvas.ContextMenu = $menu

$script:tick = 0
$script:direction = -1
$script:walking = $true
$script:stateUntil = 90
$script:nextBlink = Get-Random -Minimum 35 -Maximum 90
$script:blinkUntil = -1
$script:heartUntil = -1
$script:closing = $false
$script:floorTop = Get-PetTop
$script:interactionActive = $false
$script:interactionPhase = "Idle"
$script:interactionPhaseStarted = [DateTime]::UtcNow
$script:interactionOriginCenterX = 0.0
$script:interactionOriginCenterY = 0.0
$script:interactionTopCenterX = 0.0
$script:interactionTopCenterY = 0.0
$script:interactionLandingCenterX = 0.0
$script:interactionSpinDirection = 1.0
$script:displayOn = $true
$script:powerNotification = [IntPtr]::Zero
$script:windowSource = $null
$script:windowHook = $null
$script:hourlyVisible = $false
$script:appearancePending = $false
$script:appearanceRemaining = [TimeSpan]::FromSeconds($ShowSeconds)
$script:lastVisibilityCheck = [DateTime]::UtcNow
$script:nextAppearance = [DateTime]::UtcNow.AddMinutes($IntervalMinutes)
$script:outsideSwitchActive = $false
$script:outsideSwitchPhase = "Idle"
$script:outsideSwitchPhaseStarted = [DateTime]::UtcNow
$script:outsideSwitchEdge = ""
$script:outsideSwitchStartLeft = 0.0
$script:outsideSwitchStartTop = 0.0
$script:outsideSwitchTargetLeft = 0.0
$script:outsideSwitchTargetTop = 0.0
$script:centerReturnActive = $false
$script:centerReturnStarted = [DateTime]::UtcNow
$script:centerReturnStartCenterX = 0.0
$script:centerReturnStartCenterY = 0.0
$script:centerReturnTargetCenterX = 0.0
$script:centerReturnTargetCenterY = 0.0
$script:centerReturnDirectionX = 0.0
$script:centerReturnDirectionY = 0.0
$script:centerReturnSpinDirection = 1.0
$petEyeBounds = @{
    GrayCat = [pscustomobject]@{ Left = 84.0; Top = 66.0; Right = 162.0; Bottom = 90.0 }
    Corgi = [pscustomobject]@{ Left = 72.0; Top = 66.0; Right = 162.0; Bottom = 84.0 }
    Hamster = [pscustomobject]@{ Left = 72.0; Top = 72.0; Right = 174.0; Bottom = 96.0 }
    TuxCorgi = [pscustomobject]@{ Left = 78.0; Top = 66.0; Right = 174.0; Bottom = 84.0 }
    BlackCat = [pscustomobject]@{ Left = 72.0; Top = 72.0; Right = 180.0; Bottom = 90.0 }
    FlowerBloom = [pscustomobject]@{ Left = 78.0; Top = 60.0; Right = 186.0; Bottom = 84.0 }
    Aussie = [pscustomobject]@{ Left = 78.0; Top = 60.0; Right = 186.0; Bottom = 84.0 }
}
$stopRequestPath = Join-Path $settingsDirectory "stop.request"

function Test-InteractiveDisplay {
    return ($script:displayOn -and [PixelPetNative]::IsSessionUnlocked())
}

function Update-PetIdentityText {
    $window.Title = "Pixel Pet - $($petNames[$script:petStyle])"
    $window.ToolTip = "$($petNames[$script:petStyle]) | Hide both eyes off-screen to switch | Partial edge drag rolls to center | Double-click to pet | Right-click for menu"
}

function Save-CurrentStyleIndex {
    param([int]$StyleIndex)

    if ($SelfTest -or -not [string]::IsNullOrWhiteSpace($PreviewPath)) { return }
    try {
        New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
        @{ lastIndex = $StyleIndex } | ConvertTo-Json | Set-Content -LiteralPath $styleStatePath -Encoding UTF8
    } catch {
        # Rotation persistence is optional; switching must still complete.
    }
}

function Switch-ToNextPet {
    $currentIndex = -1
    if ($script:petStyle -eq "Aussie") {
        $currentIndex = $petStyles.Count - 1
    } else {
        for ($index = 0; $index -lt $petStyles.Count; $index++) {
            if ($petStyles[$index] -eq $script:petStyle) {
                $currentIndex = $index
                break
            }
        }
    }
    if ($currentIndex -lt 0) { $currentIndex = 0 }

    $nextIndex = ($currentIndex + 1) % $petStyles.Count
    $script:petStyle = $petStyles[$nextIndex]
    Update-PetIdentityText
    Save-CurrentStyleIndex $nextIndex
}

function Get-CurrentPetEyeBounds {
    $bounds = $petEyeBounds[$script:petStyle]
    if ($null -eq $bounds) { $bounds = $petEyeBounds.GrayCat }
    return $bounds
}

function Get-PetOutsideEdge {
    $work = [System.Windows.SystemParameters]::WorkArea
    $petLeft = Get-PetLeft
    $petTop = Get-PetTop
    $bounds = Get-CurrentPetEyeBounds
    $eyeLeft = $petLeft + $bounds.Left
    $eyeTop = $petTop + $bounds.Top
    $eyeRight = $petLeft + $bounds.Right
    $eyeBottom = $petTop + $bounds.Bottom
    $distances = @{
        Left = $work.Left - $eyeRight
        Right = $eyeLeft - $work.Right
        Top = $work.Top - $eyeBottom
        Bottom = $eyeTop - $work.Bottom
    }

    $outsideEdge = ""
    $largestDistance = [double]::NegativeInfinity
    foreach ($edge in @("Left", "Right", "Top", "Bottom")) {
        if (($distances[$edge] -ge 0.0) -and ($distances[$edge] -gt $largestDistance)) {
            $outsideEdge = $edge
            $largestDistance = $distances[$edge]
        }
    }

    # Switching is deliberate only when the complete eye rectangle is beyond one edge.
    return $outsideEdge
}

function Get-PetCrossedEdge {
    $work = [System.Windows.SystemParameters]::WorkArea
    $left = Get-PetLeft
    $top = Get-PetTop
    $distances = @{
        Left = $work.Left - $left
        Right = ($left + $petWidth) - $work.Right
        Top = $work.Top - $top
        Bottom = ($top + $petHeight) - $work.Bottom
    }

    $crossedEdge = ""
    $largestDistance = 1.0
    foreach ($edge in @("Left", "Right", "Top", "Bottom")) {
        if ($distances[$edge] -gt $largestDistance) {
            $crossedEdge = $edge
            $largestDistance = $distances[$edge]
        }
    }
    return $crossedEdge
}

function Start-OutsidePetSwitch {
    param([string]$Edge)

    if ($script:interactionActive -or $script:outsideSwitchActive -or $script:centerReturnActive) { return }
    if (@("Left", "Right", "Top", "Bottom") -notcontains $Edge) { return }

    $work = [System.Windows.SystemParameters]::WorkArea
    $margin = 12.0
    $left = Get-PetLeft
    $top = Get-PetTop
    $targetLeft = [Math]::Max($work.Left + $margin, [Math]::Min($left, $work.Right - $petWidth - $margin))
    $targetTop = [Math]::Max($work.Top + $margin, [Math]::Min($top, $work.Bottom - $petHeight - $margin))

    switch ($Edge) {
        "Left" { $targetLeft = $work.Left + $margin }
        "Right" { $targetLeft = $work.Right - $petWidth - $margin }
        "Top" { $targetTop = $work.Top + $margin }
        "Bottom" { $targetTop = $work.Bottom - $petHeight - $margin }
    }

    # Dragging uses a pet-sized transparent window; expand only after mouse release.
    Set-StageExpanded $true
    Set-PetTransform 1 1 0
    Hide-BigHeart
    Hide-MagicTransition
    $script:outsideSwitchEdge = $Edge
    $script:outsideSwitchStartLeft = $left
    $script:outsideSwitchStartTop = $top
    $script:outsideSwitchTargetLeft = $targetLeft
    $script:outsideSwitchTargetTop = $targetTop
    $script:outsideSwitchPhase = "Hold"
    $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow
    $script:outsideSwitchActive = $true
}

function Update-OutsidePetSwitch {
    if (-not $script:outsideSwitchActive) { return }

    $elapsedMs = ([DateTime]::UtcNow - $script:outsideSwitchPhaseStarted).TotalMilliseconds
    if ($script:outsideSwitchPhase -eq "Hold") {
        if ($elapsedMs -lt 700.0) { return }

        Show-MagicTransition
        $script:outsideSwitchPhase = "MagicOut"
        $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow
        return
    }

    if ($script:outsideSwitchPhase -eq "MagicOut") {
        $t = [Math]::Min(1.0, $elapsedMs / 360.0)
        $eased = Ease-OutCubic $t
        $magicCanvas.Opacity = [Math]::Min(1.0, $t / 0.22)
        $magicSize = 0.35 + (0.95 * $eased)
        $magicScale.ScaleX = $magicSize
        $magicScale.ScaleY = $magicSize
        $magicRotation.Angle = 180.0 * $eased

        if ($t -ge 1.0) {
            Switch-ToNextPet
            $script:outsideSwitchPhase = "MagicIn"
            $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow
        }
        return
    }

    if ($script:outsideSwitchPhase -eq "MagicIn") {
        $t = [Math]::Min(1.0, $elapsedMs / 360.0)
        $eased = Ease-OutCubic $t
        $magicCanvas.Opacity = 1.0 - $eased
        $magicSize = 1.30 + (0.50 * $eased)
        $magicScale.ScaleX = $magicSize
        $magicScale.ScaleY = $magicSize
        $magicRotation.Angle = 180.0 + (180.0 * $eased)

        if ($t -ge 1.0) {
            Hide-MagicTransition
            $script:outsideSwitchPhase = "Return"
            $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow
        }
        return
    }

    if ($script:outsideSwitchPhase -eq "Return") {
        $t = [Math]::Min(1.0, $elapsedMs / 420.0)
        $eased = Ease-OutCubic $t
        $left = $script:outsideSwitchStartLeft + (($script:outsideSwitchTargetLeft - $script:outsideSwitchStartLeft) * $eased)
        $top = $script:outsideSwitchStartTop + (($script:outsideSwitchTargetTop - $script:outsideSwitchStartTop) * $eased)
        Set-PetPosition $left $top

        if ($t -ge 1.0) {
            Set-PetPosition $script:outsideSwitchTargetLeft $script:outsideSwitchTargetTop
            $script:outsideSwitchActive = $false
            $script:outsideSwitchPhase = "Idle"
            Set-StageExpanded $false
            $script:floorTop = Get-PetTop
            $script:walking = $true
            $script:stateUntil = $script:tick + (Get-Random -Minimum 45 -Maximum 90)
            if ($script:outsideSwitchEdge -eq "Left") { $script:direction = 1 }
            if ($script:outsideSwitchEdge -eq "Right") { $script:direction = -1 }
        }
    }
}

function Reset-OutsidePetSwitch {
    if ($script:outsideSwitchActive) {
        Set-PetPosition $script:outsideSwitchTargetLeft $script:outsideSwitchTargetTop
    }
    $script:outsideSwitchActive = $false
    $script:outsideSwitchPhase = "Idle"
    Hide-MagicTransition
    if (-not $script:interactionActive -and -not $script:centerReturnActive) { Set-StageExpanded $false }
}

function Start-CenterReturn {
    param([string]$Edge)

    if ($script:interactionActive -or $script:outsideSwitchActive -or $script:centerReturnActive) { return }
    if (@("Left", "Right", "Top", "Bottom") -notcontains $Edge) { return }

    $work = [System.Windows.SystemParameters]::WorkArea
    $startCenterX = (Get-PetLeft) + ($petWidth / 2)
    $startCenterY = (Get-PetTop) + ($petHeight / 2)
    $targetCenterX = ($work.Left + $work.Right) / 2
    $targetCenterY = ($work.Top + $work.Bottom) / 2
    $deltaX = $targetCenterX - $startCenterX
    $deltaY = $targetCenterY - $startCenterY
    $distance = [Math]::Sqrt(($deltaX * $deltaX) + ($deltaY * $deltaY))
    if ($distance -gt 0.001) {
        $directionX = $deltaX / $distance
        $directionY = $deltaY / $distance
    } else {
        $directionX = 0.0
        $directionY = -1.0
    }

    if ([Math]::Abs($deltaX) -ge [Math]::Abs($deltaY) -and [Math]::Abs($deltaX) -gt 0.001) {
        $spinDirection = [Math]::Sign($deltaX)
    } elseif (($Edge -eq "Left") -or ($Edge -eq "Top")) {
        $spinDirection = 1.0
    } else {
        $spinDirection = -1.0
    }

    Set-StageExpanded $true
    Set-PetTransform 1 1 0
    Hide-BigHeart
    Hide-MagicTransition
    $script:centerReturnStartCenterX = $startCenterX
    $script:centerReturnStartCenterY = $startCenterY
    $script:centerReturnTargetCenterX = $targetCenterX
    $script:centerReturnTargetCenterY = $targetCenterY
    $script:centerReturnDirectionX = $directionX
    $script:centerReturnDirectionY = $directionY
    $script:centerReturnSpinDirection = $spinDirection
    $script:centerReturnStarted = [DateTime]::UtcNow
    $script:centerReturnActive = $true
    $script:walking = $false
}

function Update-CenterReturn {
    if (-not $script:centerReturnActive) { return }

    $elapsedMs = ([DateTime]::UtcNow - $script:centerReturnStarted).TotalMilliseconds
    $t = [Math]::Min(1.0, $elapsedMs / 950.0)
    $eased = Ease-InOutCubic $t
    $pop = 48.0 * [Math]::Sin($t * [Math]::PI)
    $centerX = $script:centerReturnStartCenterX + (($script:centerReturnTargetCenterX - $script:centerReturnStartCenterX) * $eased) + ($script:centerReturnDirectionX * $pop)
    $centerY = $script:centerReturnStartCenterY + (($script:centerReturnTargetCenterY - $script:centerReturnStartCenterY) * $eased) + ($script:centerReturnDirectionY * $pop)
    $pulse = [Math]::Sin($t * [Math]::PI)
    $scale = 1.0 + (0.10 * $pulse)
    $angle = 720.0 * $script:centerReturnSpinDirection * $eased
    Set-PetCenter $centerX $centerY
    Set-PetTransform $scale $scale $angle

    if ($t -ge 1.0) {
        Set-PetCenter $script:centerReturnTargetCenterX $script:centerReturnTargetCenterY
        Set-PetTransform 1 1 0
        $script:centerReturnActive = $false
        Set-StageExpanded $false
        $script:floorTop = Get-PetTop
        $script:walking = $true
        $script:stateUntil = $script:tick + (Get-Random -Minimum 45 -Maximum 90)
    }
}

function Reset-CenterReturn {
    if ($script:centerReturnActive) {
        Set-PetCenter $script:centerReturnTargetCenterX $script:centerReturnTargetCenterY
    }
    Set-PetTransform 1 1 0
    $script:centerReturnActive = $false
    if (-not $script:interactionActive -and -not $script:outsideSwitchActive) { Set-StageExpanded $false }
}

function Reset-Interaction {
    if ($script:interactionActive) {
        Set-PetCenter $script:interactionOriginCenterX $script:interactionOriginCenterY
    }
    Set-PetTransform 1 1 0
    Hide-BigHeart
    $script:interactionActive = $false
    $script:interactionPhase = "Idle"
    if (-not $script:outsideSwitchActive -and -not $script:centerReturnActive) { Set-StageExpanded $false }
}

function Start-SuperJump {
    if ($script:interactionActive -or $script:outsideSwitchActive -or $script:centerReturnActive) { return }

    # The 2x jump and large heart need the original wide animation stage.
    Set-StageExpanded $true
    $work = [System.Windows.SystemParameters]::WorkArea
    $originLeft = Get-PetLeft
    $originTop = Get-PetTop
    $originCenterX = $originLeft + ($petWidth / 2)
    $originCenterY = $originTop + ($petHeight / 2)

    # At 2x scale the center must stay one unscaled pet height below the top edge.
    $topCenterX = [Math]::Max(
        $work.Left + $petWidth,
        [Math]::Min($originCenterX, $work.Right - $petWidth)
    )
    $topCenterY = $work.Top + $petHeight

    # Fall slightly to one side, then visibly roll back to the exact start point.
    $spaceRight = ($work.Right - ($petWidth / 2)) - $originCenterX
    $spaceLeft = $originCenterX - ($work.Left + ($petWidth / 2))
    if ($spaceRight -ge $spaceLeft) {
        $spinDirection = 1.0
        $rollDistance = [Math]::Min(300.0, [Math]::Max(100.0, $spaceRight))
    } else {
        $spinDirection = -1.0
        $rollDistance = [Math]::Min(300.0, [Math]::Max(100.0, $spaceLeft))
    }

    $landingCenterX = $originCenterX + ($spinDirection * $rollDistance)
    $landingCenterX = [Math]::Max(
        $work.Left + ($petWidth / 2),
        [Math]::Min($landingCenterX, $work.Right - ($petWidth / 2))
    )

    $script:interactionOriginCenterX = $originCenterX
    $script:interactionOriginCenterY = $originCenterY
    $script:interactionTopCenterX = $topCenterX
    $script:interactionTopCenterY = $topCenterY
    $script:interactionLandingCenterX = $landingCenterX
    $script:interactionSpinDirection = $spinDirection
    $script:interactionPhase = "Heart"
    $script:interactionPhaseStarted = [DateTime]::UtcNow
    $script:interactionActive = $true
    $script:heartUntil = -1
    Show-BigHeart
}

function Update-SuperJump {
    if (-not $script:interactionActive) { return }

    $elapsedMs = ([DateTime]::UtcNow - $script:interactionPhaseStarted).TotalMilliseconds
    switch ($script:interactionPhase) {
        "Heart" {
            $duration = 760.0
            $t = [Math]::Min(1.0, $elapsedMs / $duration)

            # Quickly grow past full size, then settle back with a small pulse.
            if ($t -lt 0.62) {
                $growT = $t / 0.62
                $scale = 0.35 + (1.08 * (Ease-OutCubic $growT))
            } else {
                $settleT = ($t - 0.62) / 0.38
                $scale = 1.43 - (0.43 * (Ease-InOutCubic $settleT))
            }

            $bigHeartCanvas.Opacity = [Math]::Min(1.0, $t / 0.16)
            $bigHeartScale.ScaleX = $scale
            $bigHeartScale.ScaleY = $scale
            $bigHeartRotation.Angle = 5.0 * [Math]::Sin($t * [Math]::PI * 2)

            # The pet crouches slightly while the heart provides anticipation.
            $crouch = [Math]::Sin($t * [Math]::PI)
            Set-PetTransform (1.0 + 0.05 * $crouch) (1.0 - 0.07 * $crouch) 0

            if ($t -ge 1.0) {
                Hide-BigHeart
                Set-PetTransform 1 1 0
                $script:interactionPhase = "Launch"
                $script:interactionPhaseStarted = [DateTime]::UtcNow
            }
        }
        "Launch" {
            $duration = 850.0
            $t = [Math]::Min(1.0, $elapsedMs / $duration)
            $eased = Ease-OutCubic $t
            $centerX = $script:interactionOriginCenterX + (($script:interactionTopCenterX - $script:interactionOriginCenterX) * $eased)
            $centerY = $script:interactionOriginCenterY + (($script:interactionTopCenterY - $script:interactionOriginCenterY) * $eased)
            $scale = 1.0 + $eased
            Set-PetCenter $centerX $centerY
            Set-PetTransform $scale $scale (-8.0 * $script:interactionSpinDirection * [Math]::Sin($t * [Math]::PI))

            if ($t -ge 1.0) {
                $script:interactionPhase = "Impact"
                $script:interactionPhaseStarted = [DateTime]::UtcNow
            }
        }
        "Impact" {
            $duration = 220.0
            $t = [Math]::Min(1.0, $elapsedMs / $duration)
            $pulse = [Math]::Sin($t * [Math]::PI)
            Set-PetCenter $script:interactionTopCenterX ($script:interactionTopCenterY + (8.0 * $pulse))
            Set-PetTransform (2.0 + 0.16 * $pulse) (2.0 - 0.18 * $pulse) (12.0 * $script:interactionSpinDirection * $pulse)

            if ($t -ge 1.0) {
                $script:interactionPhase = "Fall"
                $script:interactionPhaseStarted = [DateTime]::UtcNow
            }
        }
        "Fall" {
            $duration = 1150.0
            $t = [Math]::Min(1.0, $elapsedMs / $duration)
            $fallEase = Ease-InCubic $t
            $sideEase = Ease-InOutCubic $t
            $centerX = $script:interactionTopCenterX + (($script:interactionLandingCenterX - $script:interactionTopCenterX) * $sideEase)
            $centerY = $script:interactionTopCenterY + (($script:interactionOriginCenterY - $script:interactionTopCenterY) * $fallEase)
            $scale = 2.0 - $fallEase
            $angle = 720.0 * $script:interactionSpinDirection * $fallEase
            Set-PetCenter $centerX $centerY
            Set-PetTransform $scale $scale $angle

            if ($t -ge 1.0) {
                $script:interactionPhase = "Land"
                $script:interactionPhaseStarted = [DateTime]::UtcNow
            }
        }
        "Land" {
            $duration = 180.0
            $t = [Math]::Min(1.0, $elapsedMs / $duration)
            $pulse = [Math]::Sin($t * [Math]::PI)
            Set-PetCenter $script:interactionLandingCenterX ($script:interactionOriginCenterY + (7.0 * $pulse))
            Set-PetTransform (1.0 + 0.12 * $pulse) (1.0 - 0.16 * $pulse) (720.0 * $script:interactionSpinDirection)

            if ($t -ge 1.0) {
                $script:interactionPhase = "Roll"
                $script:interactionPhaseStarted = [DateTime]::UtcNow
            }
        }
        "Roll" {
            $rollPixels = [Math]::Abs($script:interactionLandingCenterX - $script:interactionOriginCenterX)
            $duration = [Math]::Max(650.0, $rollPixels * 3.3)
            $t = [Math]::Min(1.0, $elapsedMs / $duration)
            $eased = Ease-InOutCubic $t
            $centerX = $script:interactionLandingCenterX + (($script:interactionOriginCenterX - $script:interactionLandingCenterX) * $eased)
            $radius = 78.0
            $rollDegrees = ($rollPixels / (2 * [Math]::PI * $radius)) * 360.0
            $angle = (720.0 + ($rollDegrees * $eased)) * $script:interactionSpinDirection
            $hop = -5.0 * [Math]::Abs([Math]::Sin($eased * [Math]::PI * 4))
            Set-PetCenter $centerX ($script:interactionOriginCenterY + $hop)
            Set-PetTransform 1 1 $angle

            if ($t -ge 1.0) {
                Set-PetCenter $script:interactionOriginCenterX $script:interactionOriginCenterY
                Set-PetTransform 1 1 0
                $script:interactionActive = $false
                $script:interactionPhase = "Idle"
                Set-StageExpanded $false
                $script:floorTop = Get-PetTop
            }
        }
    }
}

function Show-HourlyPet {
    if ($script:hourlyVisible) { return }
    $script:hourlyVisible = $true
    $script:lastVisibilityCheck = [DateTime]::UtcNow
    $timer.Start()
    $window.Show()
    $window.Activate() | Out-Null
}

function Hide-HourlyPet {
    if (-not $script:hourlyVisible) { return }
    Reset-Interaction
    Reset-OutsidePetSwitch
    Reset-CenterReturn
    $script:hourlyVisible = $false
    $window.Hide()
    $timer.Stop()
}

$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $script:windowSource = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
    $script:windowHook = [System.Windows.Interop.HwndSourceHook]{
        param([IntPtr]$hWnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)

        $WM_POWERBROADCAST = 0x0218
        $PBT_POWERSETTINGCHANGE = 0x8013
        $WM_NCHITTEST = 0x0084
        $HTTRANSPARENT = -1

        if ($message -eq $WM_NCHITTEST) {
            $cursorX = 0
            $cursorY = 0
            if ([PixelPetNative]::TryGetCursorPosition([ref]$cursorX, [ref]$cursorY)) {
                try {
                    $screenPoint = New-Object System.Windows.Point([double]$cursorX, [double]$cursorY)
                    $stagePoint = $stage.PointFromScreen($screenPoint)
                    $hit = [System.Windows.Media.VisualTreeHelper]::HitTest($stage, $stagePoint)
                    if ($null -eq $hit) {
                        $handled.Value = $true
                        return [IntPtr]$HTTRANSPARENT
                    }
                } catch {
                    # Fall through to standard hit testing during window teardown.
                }
            }
        }

        if (($message -eq $WM_POWERBROADCAST) -and ($wParam.ToInt64() -eq $PBT_POWERSETTINGCHANGE)) {
            # POWERBROADCAST_SETTING stores its DWORD/byte data after GUID + length.
            $displayState = [System.Runtime.InteropServices.Marshal]::ReadInt32($lParam, 20)
            $script:displayOn = ($displayState -ne 0)
            $handled.Value = $true
        }
        return [IntPtr]::Zero
    }
    $script:windowSource.AddHook($script:windowHook)

    $displayStatusGuid = [Guid]"2b84c20e-ad23-4ddf-93db-05ffbd7efca5"
    $DEVICE_NOTIFY_WINDOW_HANDLE = 0
    $script:powerNotification = [PixelPetNative]::RegisterPowerSettingNotification(
        $helper.Handle,
        [ref]$displayStatusGuid,
        $DEVICE_NOTIFY_WINDOW_HANDLE
    )
})

$wanderItem.Add_Click({
    $script:wanderEnabled = $wanderItem.IsChecked
})

$topmostItem.Add_Click({
    $window.Topmost = $topmostItem.IsChecked
})

$homeItem.Add_Click({
    Reset-CenterReturn
    Reset-OutsidePetSwitch
    $work = [System.Windows.SystemParameters]::WorkArea
    Set-PetPosition ($work.Right - $petWidth - 28) ($work.Bottom - $petHeight - 8)
    $script:floorTop = Get-PetTop
})

$exitItem.Add_Click({
    $script:closing = $true
    $window.Close()
})

$canvas.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)

    if ($eventArgs.ClickCount -ge 2) {
        Start-SuperJump
        $eventArgs.Handled = $true
        return
    }

    if ($script:interactionActive -or $script:outsideSwitchActive -or $script:centerReturnActive) {
        $eventArgs.Handled = $true
        return
    }

    # Let Windows move one cached compact frame instead of clearing/redrawing a layered window mid-drag.
    $timerWasEnabled = $timer.IsEnabled
    if ($timerWasEnabled) { $timer.Stop() }
    try {
        $window.DragMove()
        $outsideEdge = Get-PetOutsideEdge
        $crossedEdge = Get-PetCrossedEdge
        if (-not [string]::IsNullOrWhiteSpace($outsideEdge)) {
            Start-OutsidePetSwitch $outsideEdge
        } elseif (-not [string]::IsNullOrWhiteSpace($crossedEdge)) {
            Start-CenterReturn $crossedEdge
        } else {
            Clamp-ToWorkArea
            $script:floorTop = Get-PetTop
        }
    } catch {
        # DragMove can be interrupted if the mouse is released immediately.
    } finally {
        if ($timerWasEnabled -and $window.IsVisible) { $timer.Start() }
        $eventArgs.Handled = $true
    }
})

Update-PetIdentityText

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
    if (Test-Path -LiteralPath $stopRequestPath) {
        $window.Close()
        return
    }

    $script:tick++

    if ($script:tick -ge $script:nextBlink) {
        $script:blinkUntil = $script:tick + 2
        $script:nextBlink = $script:tick + (Get-Random -Minimum 35 -Maximum 95)
    }

    if ($script:centerReturnActive) {
        Update-CenterReturn
        $tailFrame = [int](($script:tick / 6) % 2)
        $isBlinking = ($script:tick -le $script:blinkUntil)
        Draw-Pet $tailFrame $isBlinking 0 $false
        return
    }

    if ($script:outsideSwitchActive) {
        Update-OutsidePetSwitch
        $tailFrame = [int](($script:tick / 6) % 2)
        $isBlinking = ($script:tick -le $script:blinkUntil)
        Draw-Pet $tailFrame $isBlinking 0 $false
        return
    }

    if (-not $script:interactionActive -and $script:tick -ge $script:stateUntil) {
        $script:walking = -not $script:walking
        if ($script:walking) {
            $script:stateUntil = $script:tick + (Get-Random -Minimum 45 -Maximum 110)
            if ((Get-Random -Minimum 0 -Maximum 4) -eq 0) { $script:direction *= -1 }
        } else {
            $script:stateUntil = $script:tick + (Get-Random -Minimum 18 -Maximum 55)
        }
    }

    if (-not $script:interactionActive -and $script:wanderEnabled -and $script:walking) {
        $work = [System.Windows.SystemParameters]::WorkArea
        $window.Left += (1.15 * $script:direction)
        if ((Get-PetLeft) -le $work.Left) {
            Set-PetPosition $work.Left (Get-PetTop)
            $script:direction = 1
        } elseif (((Get-PetLeft) + $petWidth) -ge $work.Right) {
            Set-PetPosition ($work.Right - $petWidth) (Get-PetTop)
            $script:direction = -1
        }
    }

    $bounce = 0.0
    if (-not $script:interactionActive -and $script:wanderEnabled -and $script:walking -and (($script:tick % 6) -lt 2)) {
        $bounce = -2.0
    }

    Update-SuperJump

    $tailFrame = [int](($script:tick / 6) % 2)
    $isBlinking = ($script:tick -le $script:blinkUntil)
    $showHeart = ($script:tick -le $script:heartUntil)
    Draw-Pet $tailFrame $isBlinking $bounce $showHeart
})

$window.Add_Closing({
    $timer.Stop()
    if ($null -ne $script:scheduleTimer) { $script:scheduleTimer.Stop() }
    Reset-Interaction
    Reset-OutsidePetSwitch
    Reset-CenterReturn
    if (($null -ne $script:windowSource) -and ($null -ne $script:windowHook)) {
        $script:windowSource.RemoveHook($script:windowHook)
    }
    if ($script:powerNotification -ne [IntPtr]::Zero) {
        [PixelPetNative]::UnregisterPowerSettingNotification($script:powerNotification) | Out-Null
    }
    if (-not $SelfTest -and [string]::IsNullOrWhiteSpace($PreviewPath)) {
        try {
            New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
            @{
                left = [Math]::Round((Get-PetLeft), 1)
                top = [Math]::Round((Get-PetTop), 1)
                wander = $script:wanderEnabled
                topmost = $window.Topmost
                opacity = [Math]::Round($script:petOpacity, 2)
            } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        } catch {
            # Settings persistence is optional; closing must always succeed.
        }
    }
    $app.Shutdown()
})

Draw-Pet 0 $false 0 $false

if ($SelfTest) {
    if ($script:opacityItems.Count -ne $opacityLevels.Count) { throw "Opacity menu is incomplete." }
    if (($script:opacityItems | Where-Object { $_.IsChecked }).Count -ne 1) { throw "Opacity menu must have exactly one selected level." }
    if ([Math]::Abs($window.Opacity - $script:petOpacity) -gt 0.001) { throw "Window opacity does not match the selected level." }

    $originalOpacity = $script:petOpacity
    $testOpacity = if ([Math]::Abs($originalOpacity - 0.4) -lt 0.001) { 0.6 } else { 0.4 }
    $testOpacityItem = $script:opacityItems | Where-Object { [Math]::Abs(([double]$_.Tag) - $testOpacity) -lt 0.001 } | Select-Object -First 1
    $testOpacityItem.RaiseEvent((New-Object System.Windows.RoutedEventArgs -ArgumentList ([System.Windows.Controls.MenuItem]::ClickEvent)))
    if ([Math]::Abs($window.Opacity - $testOpacity) -gt 0.001) { throw "Opacity menu click did not update the window." }
    if (($script:opacityItems | Where-Object { $_.IsChecked }).Count -ne 1) { throw "Opacity menu click left multiple selected levels." }

    $originalOpacityItem = $script:opacityItems | Where-Object { [Math]::Abs(([double]$_.Tag) - $originalOpacity) -lt 0.001 } | Select-Object -First 1
    $originalOpacityItem.RaiseEvent((New-Object System.Windows.RoutedEventArgs -ArgumentList ([System.Windows.Controls.MenuItem]::ClickEvent)))
    if ([Math]::Abs($window.Opacity - $originalOpacity) -gt 0.001) { throw "Opacity self-test did not restore the original level." }

    # A partially hidden pet must roll to screen center instead of switching.
    $outsideTestStyle = $script:petStyle
    $outsideTestLeft = Get-PetLeft
    $outsideTestTop = Get-PetTop
    $outsideTestFloorTop = $script:floorTop
    $work = [System.Windows.SystemParameters]::WorkArea

    # Verify each character's actual eye rectangle against all four screen edges.
    $centeredLeft = $work.Left + (($work.Width - $petWidth) / 2)
    $centeredTop = $work.Top + (($work.Height - $petHeight) / 2)
    foreach ($eyeTestStyle in $petEyeBounds.Keys) {
        $script:petStyle = $eyeTestStyle
        $bounds = Get-CurrentPetEyeBounds
        $eyeEdgeCases = @(
            [pscustomobject]@{ Edge = "Left"; Left = $work.Left - $bounds.Right - 2.0; Top = $centeredTop },
            [pscustomobject]@{ Edge = "Right"; Left = $work.Right - $bounds.Left + 2.0; Top = $centeredTop },
            [pscustomobject]@{ Edge = "Top"; Left = $centeredLeft; Top = $work.Top - $bounds.Bottom - 2.0 },
            [pscustomobject]@{ Edge = "Bottom"; Left = $centeredLeft; Top = $work.Bottom - $bounds.Top + 2.0 }
        )
        foreach ($eyeEdgeCase in $eyeEdgeCases) {
            Set-PetPosition $eyeEdgeCase.Left $eyeEdgeCase.Top
            if ((Get-PetOutsideEdge) -ne $eyeEdgeCase.Edge) {
                throw "$eyeTestStyle eye-bound test failed at $($eyeEdgeCase.Edge)."
            }
        }
    }
    $script:petStyle = $outsideTestStyle

    $safeTestTop = [Math]::Max($work.Top, [Math]::Min($outsideTestTop, $work.Bottom - $petHeight))
    Set-PetPosition ($work.Left - ($petWidth * 0.5)) $safeTestTop
    $testEdge = Get-PetOutsideEdge
    if (-not [string]::IsNullOrWhiteSpace($testEdge)) { throw "Partially visible eyes incorrectly qualified for switching." }
    $partialEdge = Get-PetCrossedEdge
    if ($partialEdge -ne "Left") { throw "Partial edge crossing was not detected." }
    Start-CenterReturn $partialEdge
    if (-not $script:centerReturnActive) { throw "Rejected edge drag did not start the center return." }
    if (-not $script:stageExpanded) { throw "Center return did not expand the animation stage." }
    $script:centerReturnStarted = [DateTime]::UtcNow.AddSeconds(-2)
    Update-CenterReturn
    if ($script:centerReturnActive) { throw "Center return did not finish." }
    if ($script:stageExpanded) { throw "Center return did not restore the compact stage." }
    $expectedCenterX = ($work.Left + $work.Right) / 2
    $expectedCenterY = ($work.Top + $work.Bottom) / 2
    if ([Math]::Abs(((Get-PetLeft) + ($petWidth / 2)) - $expectedCenterX) -gt 0.1) { throw "Center return missed the horizontal screen center." }
    if ([Math]::Abs(((Get-PetTop) + ($petHeight / 2)) - $expectedCenterY) -gt 0.1) { throw "Center return missed the vertical screen center." }

    # Switching requires the complete eye rectangle to be beyond one edge.
    $eyeBounds = Get-CurrentPetEyeBounds
    Set-PetPosition ($work.Left - $eyeBounds.Right - 2.0) $safeTestTop
    $testEdge = Get-PetOutsideEdge
    if ($testEdge -ne "Left") { throw "Fully hidden eyes did not qualify for switching." }
    Start-OutsidePetSwitch $testEdge
    if (-not $script:stageExpanded) { throw "Pet-switch animation did not expand the stage." }
    $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow.AddSeconds(-2)
    Update-OutsidePetSwitch
    if ($script:outsideSwitchPhase -ne "MagicOut") { throw "Magic transition did not start after the 6711 hold." }
    if ($magicCanvas.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Magic overlay was not shown." }
    $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow.AddSeconds(-2)
    Update-OutsidePetSwitch
    if ($script:petStyle -eq $outsideTestStyle) { throw "Magic transition did not switch the pet." }
    if ($script:outsideSwitchPhase -ne "MagicIn") { throw "New-pet magic phase did not start." }
    $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow.AddSeconds(-2)
    Update-OutsidePetSwitch
    if ($script:outsideSwitchPhase -ne "Return") { throw "Magic transition did not finish before the return." }
    if ($magicCanvas.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "Magic overlay did not hide." }
    $script:outsideSwitchPhaseStarted = [DateTime]::UtcNow.AddSeconds(-2)
    Update-OutsidePetSwitch
    if ($script:outsideSwitchActive) { throw "Drag-out transition did not finish." }
    if ($script:stageExpanded) { throw "Pet-switch animation did not restore the compact stage." }
    if ([Math]::Abs($window.Width - $petWidth) -gt 0.1) { throw "Compact drag window width was not restored." }
    if ([Math]::Abs($window.Height - $petHeight) -gt 0.1) { throw "Compact drag window height was not restored." }
    if ((Get-PetLeft) -lt $work.Left) { throw "The next pet did not return inside the screen." }
    $script:petStyle = $outsideTestStyle
    Set-PetPosition $outsideTestLeft $outsideTestTop
    $script:floorTop = $outsideTestFloorTop
    Update-PetIdentityText

    # Exercise every phase instantly and assert an exact transform/position reset.
    $testLeft = Get-PetLeft
    $testTop = Get-PetTop
    Start-SuperJump
    if (-not $script:stageExpanded) { throw "Super-jump did not expand the animation stage." }
    for ($phaseIndex = 0; $phaseIndex -lt 6; $phaseIndex++) {
        $script:interactionPhaseStarted = [DateTime]::UtcNow.AddSeconds(-3)
        Update-SuperJump
    }
    if ($script:interactionActive) { throw "Super-jump self-test did not finish." }
    if ($script:stageExpanded) { throw "Super-jump did not restore the compact stage." }
    if ([Math]::Abs((Get-PetLeft) - $testLeft) -gt 0.1) { throw "Super-jump did not restore the original X position." }
    if ([Math]::Abs((Get-PetTop) - $testTop) -gt 0.1) { throw "Super-jump did not restore the original Y position." }
    if ([Math]::Abs($petScale.ScaleX - 1) -gt 0.001) { throw "Super-jump did not restore the original scale." }
    if ([Math]::Abs($petRotation.Angle) -gt 0.001) { throw "Super-jump did not restore the original rotation." }
}

if ($Hourly -and -not $SelfTest -and [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $script:scheduleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:scheduleTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:scheduleTimer.Add_Tick({
        $now = [DateTime]::UtcNow

        if (Test-Path -LiteralPath $stopRequestPath) {
            $window.Close()
            return
        }

        $interactive = Test-InteractiveDisplay
        if ($script:hourlyVisible) {
            if ($interactive) {
                $elapsed = $now - $script:lastVisibilityCheck
                $script:appearanceRemaining = $script:appearanceRemaining - $elapsed
                if ($script:appearanceRemaining.TotalSeconds -le 0) {
                    Hide-HourlyPet
                    $script:appearancePending = $false
                    $script:nextAppearance = $now.AddMinutes($IntervalMinutes)
                    $script:appearanceRemaining = [TimeSpan]::FromSeconds($ShowSeconds)
                }
            } else {
                Hide-HourlyPet
            }
        } elseif ($script:appearancePending -and $interactive) {
            Show-HourlyPet
        } elseif (($now -ge $script:nextAppearance) -and $interactive) {
            $script:appearancePending = $true
            Show-HourlyPet
        }

        $script:lastVisibilityCheck = $now
    })
}

if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $window.Show()
    $window.UpdateLayout()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        [int]$stage.ActualWidth,
        [int]$stage.ActualHeight,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($stage)
    $cropRect = New-Object System.Windows.Int32Rect(
        [int][Math]::Round($stageOffsetX),
        [int][Math]::Round($stageOffsetY),
        [int]$petWidth,
        [int]$petHeight
    )
    $croppedBitmap = New-Object System.Windows.Media.Imaging.CroppedBitmap($bitmap, $cropRect)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($croppedBitmap))
    $stream = [System.IO.File]::Open($PreviewPath, [System.IO.FileMode]::Create)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $window.Close()
} elseif ($SelfTest) {
    $selfTestTimer = New-Object System.Windows.Threading.DispatcherTimer
    $selfTestTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $selfTestTimer.Add_Tick({
        $selfTestTimer.Stop()
        $window.Close()
    })
    $selfTestTimer.Start()
    $timer.Start()
    $window.ShowDialog() | Out-Null
} elseif ($Hourly) {
    # Create the native window so it can receive display-power events, then wait silently.
    $window.Show()
    $window.Hide()
    $script:scheduleTimer.Start()
    $app.Run() | Out-Null
} else {
    $timer.Start()
    $window.ShowDialog() | Out-Null
}

$mutex.ReleaseMutex()
$mutex.Dispose()
