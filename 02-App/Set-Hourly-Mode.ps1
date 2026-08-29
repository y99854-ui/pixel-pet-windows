param([switch]$Disable)

$ErrorActionPreference = "Stop"

$petHome = Join-Path $env:LOCALAPPDATA "PixelCatPet"
$appHome = Join-Path $petHome "app"
$startupHome = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupHome "Pixel Cat Hourly.lnk"
$stopRequestPath = Join-Path $petHome "stop.request"

if ($Disable) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }

    New-Item -ItemType Directory -Path $petHome -Force | Out-Null
    Set-Content -LiteralPath $stopRequestPath -Value "stop" -Encoding ASCII
    Start-Sleep -Seconds 2
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
    Write-Host "Hourly Pixel Cat has been stopped."
    exit 0
}

# This mode is intentionally session-only. Remove an older shortcut if present.
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
}

New-Item -ItemType Directory -Path $appHome -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "PixelPet.ps1") -Destination $appHome -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.md") -Destination $appHome -Force

# Ask a running copy from this package to exit before switching into hourly mode.
Set-Content -LiteralPath $stopRequestPath -Value "stop" -Encoding ASCII
Start-Sleep -Seconds 2
Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue

$installedScript = Join-Path $appHome "PixelPet.ps1"
$arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`" -Hourly -IntervalMinutes 60 -ShowSeconds 30"
Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden

Write-Host "Hourly Pixel Cat is running for this login session."
Write-Host "It will first appear in about one hour and will NOT start with Windows."
