param(
    [switch]$Refresh,
    [string]$Target = ''
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $project 'artifacts\rainmeter-skin'
$targetCandidates = @()
if ($Target) {
    $targetCandidates += $Target
}
else {
    if ($env:APPDATA) {
        $targetCandidates += (Join-Path $env:APPDATA 'Rainmeter\Skins\CodexGauge')
    }
    if ($env:USERPROFILE) {
        $targetCandidates += (Join-Path $env:USERPROFILE 'Documents\Rainmeter\Skins\CodexGauge')
    }
}
$target = $targetCandidates |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'CodexGauge.ini') } |
    Select-Object -First 1
$target = if ($target) { [IO.Path]::GetFullPath($target) } else { $null }
$files = @('CodexGauge.ini', '@Resources\Scripts\ApplyUsage.lua',
    '@Resources\Scripts\FetchUsage.ps1', '@Resources\Scripts\GraphModel.lua',
    '@Resources\Scripts\GraphView.lua')
if (-not $target) {
    throw 'Live CodexGauge skin not found. Pass -Target with the exact skin directory.'
}
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $file))) { throw "Missing source: $file" }
}
$backup = Join-Path $project ('backups\pre-deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup | Out-Null
Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'live') -Recurse
# Verify the five existing code files before replacing any. Runtime history is never deployed.
foreach ($file in $files) {
    $live = Join-Path $target $file
    if (Test-Path -LiteralPath $live) {
        if ((Get-FileHash -LiteralPath $live).Hash -ne (Get-FileHash -LiteralPath (Join-Path $backup ('live\' + $file))).Hash) {
            throw "Backup verification failed: $file"
        }
    }
}
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $target $file) -Force
    if ((Get-FileHash -LiteralPath (Join-Path $source $file)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $target $file)).Hash) {
        throw "Deployment verification failed: $file. Backup: $backup"
    }
}
Write-Output "BACKUP $backup"
Write-Output 'DEPLOYED 5 code files; existing Usage.inc and history preserved.'
if ($Refresh) {
    & 'C:\Program Files\Rainmeter\Rainmeter.exe' !Refresh CodexGauge
    Write-Output 'REFRESH requested for CodexGauge only.'
}
