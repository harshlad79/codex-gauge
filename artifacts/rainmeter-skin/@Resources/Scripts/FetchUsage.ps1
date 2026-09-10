#Requires -Version 5.1
<#
.SYNOPSIS
  Reads Codex CLI auth.json and writes Rainmeter Usage.inc (no tokens written).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    [Parameter(Mandatory = $false)]
    [string]$AuthPath
)

$ErrorActionPreference = 'Stop'

function Enter-CollectorLock {
    param([string]$Directory)
    $Directory = [IO.Path]::GetFullPath($Directory)
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    # Keep this file in place: deleting a lock file can split concurrent writers.
    try {
        return [IO.File]::Open((Join-Path $Directory '.FetchUsage.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -in @(32, 33)) { return $null }
        throw
    }
}

function Write-AtomicLines {
    param([string]$Path, [string[]]$Lines)
    $Path = [IO.Path]::GetFullPath($Path)
    $dir = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($tmp, $Lines, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) {
            # PowerShell 5.1 converts $null string arguments to an empty path.
            [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmp, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Get-HistoryTime {
    param($Row)
    if ($null -ne $Row.epoch) {
        $epoch = 0L
        if (-not [int64]::TryParse([string]$Row.epoch, [ref]$epoch) -or $epoch -le 0) {
            throw [IO.InvalidDataException]::new('Invalid history epoch.')
        }
        return [DateTimeOffset]::FromUnixTimeSeconds($epoch)
    }
    # Legacy rows have only an ISO timestamp. Respect its UTC offset.
    $time = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Row.timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$time)) {
        throw [IO.InvalidDataException]::new('Invalid history timestamp.')
    }
    return $time
}

function Add-HistorySnapshot {
    param(
        [string]$Path, [double]$Session, [double]$Weekly,
        [int64]$SessionReset, [int64]$WeeklyReset,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    # Caller holds the output-directory lock through history and Usage.inc writes.
    # Prune by actual UTC age (60 days), at most once per UTC day or at the cap.
    # At 86400 samples, keep 84960 including the new sample: 1440 spare slots.
    # At one sample/minute, cap pruning retains roughly 59-60 days of coverage,
    # not a guaranteed full 60 days; faster sampling reaches the cap sooner.
    $maxSamples = 86400
    $capTarget = 84960
    $Path = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $statePath = "$Path.state.json"
    $day = $Now.UtcDateTime.ToString('yyyy-MM-dd')
    $state = $null
    if ([IO.File]::Exists($Path) -and [IO.File]::Exists($statePath)) {
        try {
            $candidate = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            if ($candidate.version -eq 1 -and $candidate.count -ge 1 -and $candidate.count -le $maxSamples -and
                $candidate.length -eq (Get-Item -LiteralPath $Path).Length -and
                $candidate.prunedDay -match '^\d{4}-\d{2}-\d{2}$' -and
                $candidate.sessionReset -gt 0 -and $candidate.weeklyReset -gt 0) {
                $state = $candidate
            }
        }
        catch { $state = $null }
    }
    # Missing/stale metadata (including an interrupted append) is rebuilt once.
    $prune = $null -eq $state -or $state.prunedDay -ne $day -or $state.count -ge $maxSamples
    $previousSessionReset = if ($state) { [int64]$state.sessionReset } else { 0L }
    $previousWeeklyReset = if ($state) { [int64]$state.weeklyReset } else { 0L }
    if ($prune) {
        $cutoff = $Now.AddDays(-60)
        $lines = New-Object 'System.Collections.Generic.Queue[string]'
        if ([IO.File]::Exists($Path)) {
            foreach ($line in [IO.File]::ReadLines($Path)) {
                try {
                    $row = $line | ConvertFrom-Json
                    $time = Get-HistoryTime -Row $row
                    $sr = [int64]$row.sessionReset
                    $wr = [int64]$row.weeklyReset
                    if ($sr -le 0 -or $wr -le 0 -or $null -eq $row.session -or $null -eq $row.weekly) { continue }
                }
                catch { continue }
                $previousSessionReset = $sr
                $previousWeeklyReset = $wr
                if ($time -lt $cutoff) { continue }
                # Reserve one slot for the new observation; memory stays bounded.
                if ($lines.Count -ge ($maxSamples - 1)) { $null = $lines.Dequeue() }
                $lines.Enqueue($line)
            }
        }
    }
    # Keep the first five fields in their legacy order for existing Lua readers.
    # Epoch changes describe windows, not an observed zero or a synthetic sample.
    $entry = [pscustomobject][ordered]@{
        timestamp = $Now.UtcDateTime.ToString('o')
        session = $Session
        weekly = $Weekly
        sessionReset = $SessionReset
        weeklyReset = $WeeklyReset
        epoch = $Now.ToUnixTimeSeconds()
        sessionResetChanged = ($previousSessionReset -gt 0 -and $previousSessionReset -ne $SessionReset)
        weeklyResetChanged = ($previousWeeklyReset -gt 0 -and $previousWeeklyReset -ne $WeeklyReset)
        sessionObservedZero = ($Session -eq 0)
        weeklyObservedZero = ($Weekly -eq 0)
    } | ConvertTo-Json -Compress
    if ($prune) {
        # Leave a day's headroom instead of rewriting the full history each minute.
        if (($lines.Count + 1) -ge $maxSamples) {
            while ($lines.Count -ge $capTarget) { $null = $lines.Dequeue() }
        }
        $lines.Enqueue($entry)
        Write-AtomicLines -Path $Path -Lines $lines.ToArray()
        $count = $lines.Count
    }
    else {
        [IO.File]::AppendAllText($Path, $entry + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $count = [int]$state.count + 1
    }
    $newState = [ordered]@{
        version = 1; count = $count; length = (Get-Item -LiteralPath $Path).Length
        prunedDay = $day; sessionReset = $SessionReset; weeklyReset = $WeeklyReset
    } | ConvertTo-Json -Compress
    Write-AtomicLines -Path $statePath -Lines @($newState)
}

function Resolve-CodexAuthPath {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            throw "Auth file not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $candidates = @()
    if ($env:CODEX_HOME -and $env:CODEX_HOME.Trim()) {
        $candidates += (Join-Path $env:CODEX_HOME.Trim() 'auth.json')
    }
    $candidates += (Join-Path $env:USERPROFILE '.codex\auth.json')

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw 'auth.json not found. Run `codex login`, then refresh.'
}

function Get-CodexCredentials {
    param([string]$Path)

    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = $null
    $accountId = $null
    $source = $null

    $pat = $null
    if ($json.PSObject.Properties.Name -contains 'personal_access_token') {
        $pat = [string]$json.personal_access_token
    }
    elseif ($json.PSObject.Properties.Name -contains 'personalAccessToken') {
        $pat = [string]$json.personalAccessToken
    }

    if ($pat -and $pat.Trim()) {
        $token = $pat.Trim()
        $source = 'pat'
    }
    elseif ($json.tokens -and $json.tokens.access_token) {
        $token = [string]$json.tokens.access_token
        if ($json.tokens.account_id) {
            $accountId = [string]$json.tokens.account_id
        }
        $source = 'oauth'
    }

    if (-not $token) {
        throw 'No access_token or personal_access_token in auth.json'
    }

    return [pscustomobject]@{
        AccessToken = $token
        AccountId   = $accountId
        Source      = $source
    }
}

function Format-ResetAt {
    param($Window)
    if (-not $Window) { return '-' }
    $resetAt = $Window.reset_at
    if ($null -eq $resetAt -or $resetAt -eq '') { return '-' }
    try {
        $dto = [DateTimeOffset]::FromUnixTimeSeconds([int64]$resetAt).ToLocalTime()
        return $dto.ToString('MM-dd HH:mm')
    }
    catch {
        return '-'
    }
}

function Get-UsedPercent {
    param($Window)
    if ($null -eq $Window) { throw [IO.InvalidDataException]::new('Missing usage window.') }
    $raw = $Window.used_percent
    $value = 0.0
    $text = if ($raw -is [double]) { $raw.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
        else { [Convert]::ToString($raw, [Globalization.CultureInfo]::InvariantCulture) }
    if ($null -eq $raw -or -not [double]::TryParse($text,
            [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or
        [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 100) {
        throw [IO.InvalidDataException]::new('Invalid usage percentage.')
    }
    return $value
}

function Get-ResetEpoch {
    param($Window, [int64]$ExpectedSeconds)
    $reset = 0L
    $raw = [Convert]::ToString($Window.reset_at, [Globalization.CultureInfo]::InvariantCulture)
    if (-not [int64]::TryParse($raw, [ref]$reset) -or $reset -le 0 -or $reset -gt 253402300799L) {
        throw [IO.InvalidDataException]::new('Invalid usage reset.')
    }
    $hasDuration = $Window.PSObject.Properties.Name -contains 'limit_window_seconds'
    if ($Window -is [Collections.IDictionary]) { $hasDuration = $Window.Contains('limit_window_seconds') }
    if ($hasDuration) {
        $duration = 0L
        $raw = [Convert]::ToString($Window.limit_window_seconds, [Globalization.CultureInfo]::InvariantCulture)
        if (-not [int64]::TryParse($raw, [ref]$duration) -or $duration -ne $ExpectedSeconds) {
            throw [IO.InvalidDataException]::new('Unexpected usage window duration.')
        }
    }
    return $reset
}

function Get-UsageValues {
    param($Response)
    if ($null -eq $Response.rate_limit) { throw [IO.InvalidDataException]::new('Missing rate limit.') }
    $primary = $Response.rate_limit.primary_window
    $secondary = $Response.rate_limit.secondary_window
    $primaryPct = Get-UsedPercent -Window $primary
    $secondaryPct = Get-UsedPercent -Window $secondary
    $primaryReset = Get-ResetEpoch -Window $primary -ExpectedSeconds 18000
    $secondaryReset = Get-ResetEpoch -Window $secondary -ExpectedSeconds 604800
    $plan = [string]$Response.plan_type
    if (-not $plan) { $plan = 'unknown' }
    return [pscustomobject]@{
        Plan = $plan; Primary = $primary; Secondary = $secondary
        PrimaryPercent = $primaryPct; SecondaryPercent = $secondaryPct
        PrimaryResetEpoch = $primaryReset; SecondaryResetEpoch = $secondaryReset
    }
}

function Format-Remaining {
    param($Window, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if (-not $Window -or $null -eq $Window.reset_at) { return '-' }
    $seconds = [math]::Max(0, [int64]$Window.reset_at - $Now.ToUnixTimeSeconds())
    $span = [TimeSpan]::FromSeconds($seconds)
    # TimeSpan components truncate whole units; PowerShell's [int] cast rounds.
    if ($span.TotalDays -ge 1) { return ('{0}d {1}h' -f $span.Days, $span.Hours) }
    if ($span.TotalHours -ge 1) { return ('{0}h {1}m' -f $span.Hours, $span.Minutes) }
    return ('{0}m' -f [math]::Max(1, $span.Minutes))
}

function Get-UsageDefaults {
    # Lua owns warnings/forecasts. Keep legacy variables available with neutral defaults.
    return [ordered]@{
        Connected = '0'; HasUsageData = '0'; PlanName = '-'
        PrimaryPercent = '0'; PrimaryReset = '-'; PrimaryResetEpoch = '0'
        SecondaryPercent = '0'; SecondaryReset = '-'; SecondaryResetEpoch = '0'
        SessionRemaining = '-'; WeeklyRemaining = '-'; Warning = ''
        Error1 = ''; Error2 = ''; Error3 = ''
        SessionForecast = '-'; WeeklyForecast = '-'; SessionMargin = '-'; WeeklyMargin = '-'
        Severity = '0'; BgColor = '18,18,20,220'; AuthSource = '-'; Status = 'Error'
        UpdatedAt = '-'; UpdatedEpoch = '0'; Error = ''
    }
}

function Read-UsageInc {
    param([string]$Path)
    $vars = Get-UsageDefaults
    if ([IO.File]::Exists($Path)) {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if ($line -match '^([A-Za-z0-9]+)=(.*)$' -and $vars.Contains($Matches[1])) {
                $vars[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $vars
}

function Write-UsageInc {
    param(
        [string]$Path,
        [Collections.IDictionary]$Vars
    )

    $lines = @(
        '; Auto-generated by FetchUsage.ps1 - do not put secrets here.'
        '[Variables]'
    )
    $defaults = Get-UsageDefaults
    foreach ($key in $defaults.Keys) {
        $value = if ($Vars.Contains($key)) { $Vars[$key] } else { $defaults[$key] }
        $value = if ($value -is [double]) { $value.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
            else { [Convert]::ToString($value, [Globalization.CultureInfo]::InvariantCulture) }
        # Keep values on one INI line, with invariant decimal points.
        $value = $value -replace '"', "'" -replace '[\r\n\x00-\x1f\x7f]', ' '
        $lines += "$key=$value"
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Write-AtomicLines -Path $Path -Lines $lines
}

function Get-SafeErrorMessage {
    param([string]$Message)
    # Only collector-owned categories may be persisted, never exception text/bodies.
    if ($Message -cin @('Authentication unavailable.', 'Usage request failed.',
            'Invalid usage response.', 'Collector storage failure.', 'Collector operation failed.') -or
        $Message -cmatch '^Usage request failed \(HTTP [1-5][0-9]{2}\)\.$') {
        return $Message
    }
    return 'Collector operation failed.'
}

function Format-CollectorError {
    param([string]$Message, [DateTimeOffset]$Now)
    $stamp = $Now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    # Re-sanitize old entries too, including legacy entries containing raw errors.
    if ($Message -cmatch '^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\] (.*)$') {
        $oldStamp = $Matches[1]
        $Message = $Matches[2]
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParseExact($oldStamp, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            $stamp = $oldStamp
        }
    }
    return ('[{0}] {1}' -f $stamp, (Get-SafeErrorMessage -Message $Message))
}

function Write-Failure {
    param(
        [string]$Path,
        [string]$Message,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $vars = Read-UsageInc -Path $Path
    $errors = @((Format-CollectorError -Message (Get-SafeErrorMessage -Message $Message) -Now $Now))
    foreach ($key in @('Error1', 'Error2', 'Error3')) {
        if ($vars[$key] -and $errors.Count -lt 3) {
            $errors += Format-CollectorError -Message $vars[$key] -Now $Now
        }
    }
    while ($errors.Count -lt 3) { $errors += '' }
    # Usage, resets, HasUsageData and successful update time remain untouched.
    $vars.Connected = '0'
    $vars.Status = 'Error'
    $vars.Error = $errors[0]
    $vars.Error1 = $errors[0]
    $vars.Error2 = $errors[1]
    $vars.Error3 = $errors[2]
    Write-UsageInc -Path $Path -Vars $vars
}

function Write-Success {
    param(
        [string]$Path, $Response, [string]$AuthSource,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    # Validate both windows before touching either persisted file.
    $usage = Get-UsageValues -Response $Response
    $historyPath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) 'UsageHistory.jsonl'
    Add-HistorySnapshot -Path $historyPath -Session $usage.PrimaryPercent -Weekly $usage.SecondaryPercent `
        -SessionReset $usage.PrimaryResetEpoch -WeeklyReset $usage.SecondaryResetEpoch -Now $Now
    $vars = Get-UsageDefaults
    $vars.Connected = '1'
    $vars.HasUsageData = '1'
    $vars.PlanName = $usage.Plan
    $vars.PrimaryPercent = $usage.PrimaryPercent
    $vars.PrimaryReset = Format-ResetAt -Window $usage.Primary
    $vars.PrimaryResetEpoch = $usage.PrimaryResetEpoch
    $vars.SecondaryPercent = $usage.SecondaryPercent
    $vars.SecondaryReset = Format-ResetAt -Window $usage.Secondary
    $vars.SecondaryResetEpoch = $usage.SecondaryResetEpoch
    $vars.SessionRemaining = Format-Remaining -Window $usage.Primary -Now $Now
    $vars.WeeklyRemaining = Format-Remaining -Window $usage.Secondary -Now $Now
    $vars.AuthSource = $AuthSource
    $vars.Status = 'OK'
    $vars.UpdatedAt = $Now.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    $vars.UpdatedEpoch = $Now.ToUnixTimeSeconds()
    Write-UsageInc -Path $Path -Vars $vars
    return $usage
}

$collectorLock = $null
$failureMessage = 'Collector storage failure.'
try {
    $OutFile = [IO.Path]::GetFullPath($OutFile)
    $collectorLock = Enter-CollectorLock -Directory ([IO.Path]::GetDirectoryName($OutFile))
    if ($null -eq $collectorLock) {
        Write-Output 'SKIP collector already running'
        return
    }
    $failureMessage = 'Authentication unavailable.'
    $resolvedAuth = Resolve-CodexAuthPath -Explicit $AuthPath
    $creds = Get-CodexCredentials -Path $resolvedAuth

    $headers = @{
        Authorization = "Bearer $($creds.AccessToken)"
        Accept        = 'application/json'
        'User-Agent'  = 'CodexGauge-Rainmeter/0.1'
    }
    if ($creds.AccountId) {
        $headers['ChatGPT-Account-Id'] = $creds.AccountId
    }

    $failureMessage = 'Usage request failed.'
    $response = Invoke-RestMethod -Method Get -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $headers -TimeoutSec 30
    $failureMessage = 'Collector storage failure.'
    $usage = Write-Success -Path $OutFile -Response $response -AuthSource $creds.Source
    Write-Output "OK primary=$($usage.PrimaryPercent) secondary=$($usage.SecondaryPercent)"
}
catch {
    if ($_.Exception -is [IO.InvalidDataException]) { $failureMessage = 'Invalid usage response.' }
    elseif ($_.Exception -is [Net.WebException] -and $null -ne $_.Exception.Response) {
        $failureMessage = 'Usage request failed (HTTP {0}).' -f [int]$_.Exception.Response.StatusCode
    }
    $msg = Get-SafeErrorMessage -Message $failureMessage
    if ($null -ne $collectorLock) {
        try { Write-Failure -Path $OutFile -Message $msg }
        catch { $msg = 'Collector storage failure.' }
    }
    Write-Output "ERR $msg"
    exit 1
}
finally {
    if ($null -ne $collectorLock) { $collectorLock.Dispose() }
}
