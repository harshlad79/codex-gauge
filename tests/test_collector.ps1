#Requires -Version 5.1
[CmdletBinding()]
param([switch]$LockProbe, [string]$LockDirectory)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run these tests with Windows PowerShell 5.1.'
}

$collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\rainmeter-skin\@Resources\Scripts\FetchUsage.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($definition in $definitions) {
    # Never dot-source the collector: its top level accesses auth and the network.
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Resolve-CodexAuthPath { throw 'TEST BUG: auth must not be accessed.' }
function Get-CodexCredentials { throw 'TEST BUG: credentials must not be accessed.' }
function Invoke-RestMethod { throw 'TEST BUG: network must not be accessed.' }

if ($LockProbe) {
    $probe = Enter-CollectorLock -Directory $LockDirectory
    if ($null -eq $probe) { exit 7 }
    $probe.Dispose()
    exit 0
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Because = '')
    if ($Actual -cne $Expected) { throw "Expected <$Expected>, got <$Actual>. $Because" }
}
function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw $Because }
}
function Assert-Throws {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected an exception.' }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Output "PASS $Name"
}
function New-TestDirectory {
    param([string]$Name)
    $path = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function New-Response {
    return ('{"plan_type":"plus","rate_limit":{"primary_window":' +
        '{"used_percent":12.625,"reset_at":1900000000,"limit_window_seconds":18000},' +
        '"secondary_window":{"used_percent":83.375,"reset_at":1900500000,"limit_window_seconds":604800}}}') | ConvertFrom-Json
}
function New-HistoryRow {
    param([DateTimeOffset]$Time, [int]$Id, [Nullable[int64]]$Epoch)
    $row = [ordered]@{
        timestamp = $Time.ToString('o'); session = 12.625; weekly = 83.375
        sessionReset = 1900000000L; weeklyReset = 1900500000L; id = $Id
    }
    if ($null -ne $Epoch) { $row.epoch = $Epoch }
    return $row | ConvertTo-Json -Compress
}
function Read-History {
    param([string]$Path)
    foreach ($line in [IO.File]::ReadLines($Path)) { $line | ConvertFrom-Json }
}
function Invoke-LockProbe {
    param([string]$Directory)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -LockProbe -LockDirectory "{1}"' -f $PSCommandPath, $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Lock probe timed out.' }
        $errorText = $process.StandardError.ReadToEnd()
        if ($errorText) { throw $errorText }
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

# All fixtures, collector output, locks and sidecars live beneath this TEMP tests directory.
$testsTemp = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'CodexGauge-tests'))
$testRoot = Join-Path $testsTemp ('collector-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$now = [DateTimeOffset]::Parse('2026-09-09T12:34:56Z', [Globalization.CultureInfo]::InvariantCulture)
$utf8 = New-Object Text.UTF8Encoding($false)
$script:passed = 0
Write-Output ('PowerShell {0}; AST-only collector functions; TEMP fixtures: {1}' -f $PSVersionTable.PSVersion, $testRoot)
try {
    Invoke-Test 'remaining time truncates days, hours and minutes without rounding up' {
        $cases = @(
            @{ Seconds = (47 * 3600); Expected = '1d 23h' },
            @{ Seconds = (48 * 3600 - 1); Expected = '1d 23h' },
            @{ Seconds = (24 * 3600); Expected = '1d 0h' },
            @{ Seconds = (24 * 3600 - 1); Expected = '23h 59m' },
            @{ Seconds = (2 * 3600 - 1); Expected = '1h 59m' },
            @{ Seconds = 3600; Expected = '1h 0m' },
            @{ Seconds = 3599; Expected = '59m' },
            @{ Seconds = 119; Expected = '1m' },
            @{ Seconds = 0; Expected = '1m' },
            @{ Seconds = -60; Expected = '1m' }
        )
        foreach ($case in $cases) {
            $window = [pscustomobject]@{ reset_at = $now.ToUnixTimeSeconds() + $case.Seconds }
            Assert-Equal (Format-Remaining -Window $window -Now $now) $case.Expected
        }
        Assert-Equal (Format-Remaining -Window $null -Now $now) '-'
        Assert-Equal (Format-Remaining -Window ([pscustomobject]@{}) -Now $now) '-'
    }

    Invoke-Test 'double percentages, invariant INI, epochs and legacy JSON field order' {
        $dir = New-TestDirectory 'precision'
        $path = Join-Path $dir 'Usage.inc'
        $response = New-Response
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            Assert-True ((Get-UsedPercent $response.rate_limit.primary_window) -is [double]) 'Percentage must be a double.'
            $null = Write-Success -Path $path -Response $response -AuthSource oauth -Now $now
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
        $vars = Read-UsageInc $path
        Assert-Equal $vars.PrimaryPercent '12.625'
        Assert-Equal $vars.SecondaryPercent '83.375'
        Assert-Equal $vars.PrimaryResetEpoch '1900000000'
        Assert-Equal $vars.SecondaryResetEpoch '1900500000'
        Assert-Equal $vars.UpdatedEpoch ([string]$now.ToUnixTimeSeconds())
        $history = Join-Path $dir 'UsageHistory.jsonl'
        $row = @(Read-History $history)[0]
        Assert-Equal $row.session 12.625
        Assert-Equal $row.weekly 83.375
        Assert-Equal $row.epoch $now.ToUnixTimeSeconds()
        Assert-Equal $row.timestamp $now.UtcDateTime.ToString('o')
        Assert-Equal $row.sessionReset 1900000000L
        Assert-Equal $row.weeklyReset 1900500000L
        Assert-True ([IO.File]::ReadAllText($history) -match '^\{"timestamp":"[^"]+","session":12\.625,"weekly":83\.375,"sessionReset":1900000000,"weeklyReset":1900500000,') 'Legacy Lua prefix must remain readable.'
        $precise = [double]12.123456789012345
        $response.rate_limit.primary_window.used_percent = $precise
        Assert-Equal (Get-UsedPercent $response.rate_limit.primary_window) $precise 'Validation must preserve all double precision.'
        $null = Write-Success -Path $path -Response $response -AuthSource oauth -Now $now.AddSeconds(1)
        Assert-Equal (Read-UsageInc $path).PrimaryPercent ($precise.ToString('R', [Globalization.CultureInfo]::InvariantCulture))
        # PS 5.1 decodes long JSON fractions as Decimal; compare their double bits.
        Assert-Equal ([BitConverter]::DoubleToInt64Bits([double]@(Read-History $history)[-1].session)) `
            ([BitConverter]::DoubleToInt64Bits($precise)) 'JSONL must round-trip double precision.'
    }

    Invoke-Test 'missing/invalid rate limits, windows, percentages, resets and durations fail before writes' {
        $dir = New-TestDirectory 'validation'
        $path = Join-Path $dir 'Usage.inc'
        $null = Write-Success -Path $path -Response (New-Response) -AuthSource oauth -Now $now
        $before = [IO.File]::ReadAllText($path)
        $history = Join-Path $dir 'UsageHistory.jsonl'
        $historyBefore = [IO.File]::ReadAllText($history)
        $mutations = @(
            { param($r) $r.PSObject.Properties.Remove('rate_limit') },
            { param($r) $r.rate_limit = $null },
            { param($r) $r.rate_limit.primary_window = $null },
            { param($r) $r.rate_limit.secondary_window = $null }
        )
        foreach ($mutate in $mutations) {
            $response = New-Response
            & $mutate $response
            Assert-Throws { Write-Success -Path $path -Response $response -AuthSource oauth -Now $now.AddMinutes(1) }
        }
        foreach ($windowName in @('primary_window', 'secondary_window')) {
            foreach ($field in @('used_percent', 'reset_at')) {
                $response = New-Response
                $response.rate_limit.$windowName.PSObject.Properties.Remove($field)
                Assert-Throws { Get-UsageValues $response }
                $badValues = if ($field -eq 'used_percent') { @($null, '', ' ', 'bad', 'NaN', 'Infinity', -0.1, 100.01, $true) }
                    else { @($null, '', ' ', 'bad', 0, -1, 1900000000.5, 253402300800L, $true) }
                foreach ($bad in $badValues) {
                    $response = New-Response
                    $response.rate_limit.$windowName.$field = $bad
                    Assert-Throws { Write-Success -Path $path -Response $response -AuthSource oauth -Now $now.AddMinutes(1) }
                }
            }
            foreach ($bad in @($null, '', 0, 18001, 604801, 18000.5, 'bad')) {
                $response = New-Response
                $response.rate_limit.$windowName.limit_window_seconds = $bad
                Assert-Throws { Get-UsageValues $response }
            }
        }
        Assert-Throws { Get-UsageValues $null }
        Assert-Equal ([IO.File]::ReadAllText($path)) $before
        Assert-Equal ([IO.File]::ReadAllText($history)) $historyBefore
        $response = New-Response
        $response.rate_limit.primary_window.PSObject.Properties.Remove('limit_window_seconds')
        $response.rate_limit.secondary_window.PSObject.Properties.Remove('limit_window_seconds')
        $response.rate_limit.primary_window.used_percent = 0
        $response.rate_limit.secondary_window.used_percent = 100
        $usage = Get-UsageValues $response
        Assert-Equal $usage.PrimaryPercent 0.0
        Assert-Equal $usage.SecondaryPercent 100.0
    }

    Invoke-Test '60-day UTC age: legacy offsets, exact boundary, epoch rows and corrupt lines' {
        $dir = New-TestDirectory 'retention'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        $cutoff = $now.AddDays(-60)
        $seed = @(
            (New-HistoryRow -Time $cutoff.AddSeconds(-1) -Id 1),
            (New-HistoryRow -Time $cutoff -Id 2),
            (New-HistoryRow -Time $cutoff.AddSeconds(-1).ToOffset([TimeSpan]::FromHours(14)) -Id 3),
            (New-HistoryRow -Time $cutoff.AddSeconds(1).ToOffset([TimeSpan]::FromHours(-7)) -Id 4),
            (New-HistoryRow -Time $now -Id 5 -Epoch $cutoff.AddSeconds(-1).ToUnixTimeSeconds()),
            (New-HistoryRow -Time $cutoff.AddDays(-10) -Id 6 -Epoch $now.AddSeconds(-20).ToUnixTimeSeconds()),
            '{broken', '', '{"timestamp":"not a time"}'
        )
        [IO.File]::WriteAllLines($path, $seed, $utf8)
        Add-HistorySnapshot $path 13.125 83.875 1900000000L 1900500000L -Now $now
        $rows = @(Read-History $path)
        Assert-Equal $rows.Count 4
        Assert-Equal (($rows | Select-Object -First 3 | ForEach-Object { $_.id }) -join ',') '2,4,6'
        foreach ($row in $rows) { Assert-True ((Get-HistoryTime $row) -ge $cutoff) 'Expired row survived pruning.' }
        Assert-Equal ([IO.File]::ReadAllBytes($path)[0]) 123 'JSONL must have no UTF-8 BOM.'
    }

    Invoke-Test 'normal append without replacement; pruning once per UTC day' {
        $dir = New-TestDirectory 'append'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        [IO.File]::WriteAllLines($path, @((New-HistoryRow $now.AddDays(-60).AddSeconds(30) 1)), $utf8)
        Add-HistorySnapshot $path 13.5 84.5 1900000000L 1900500000L -Now $now
        $prefix = [IO.File]::ReadAllText($path)
        # This reader permits append, but denies delete/replace. Append must still work.
        $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { Add-HistorySnapshot $path 14.5 85.5 1900000000L 1900500000L -Now $now.AddMinutes(1) }
        finally { $reader.Dispose() }
        Assert-True ([IO.File]::ReadAllText($path).StartsWith($prefix)) 'Normal append changed existing bytes.'
        Assert-Equal @(Read-History $path).Count 3
        $nextUtcDay = [DateTimeOffset]::Parse('2026-09-10T00:00:01Z').ToOffset([TimeSpan]::FromHours(-7))
        Add-HistorySnapshot $path 15.5 86.5 1900000000L 1900500000L -Now $nextUtcDay
        $rows = @(Read-History $path)
        Assert-Equal $rows.Count 3
        Assert-True (-not ($rows | Where-Object { $_.id -eq 1 })) 'New UTC day must remove expired samples.'
        Assert-Equal (([IO.File]::ReadAllText("$path.state.json") | ConvertFrom-Json).prunedDay) '2026-09-10'
    }

    Invoke-Test 'reset transitions preserve observed decimals; zero means observed zero only' {
        $dir = New-TestDirectory 'transitions'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        Add-HistorySnapshot $path 70.25 81.5 1900000000L 1900500000L -Now $now
        Add-HistorySnapshot $path 3.75 81.5 1900018000L 1900500000L -Now $now.AddMinutes(1)
        Add-HistorySnapshot $path 0 2.125 1900018000L 1901104800L -Now $now.AddMinutes(2)
        $rows = @(Read-History $path)
        Assert-Equal $rows.Count 3 'No synthetic zero samples.'
        Assert-Equal $rows[0].sessionResetChanged $false
        Assert-Equal $rows[1].sessionResetChanged $true
        Assert-Equal $rows[1].weeklyResetChanged $false
        Assert-Equal $rows[1].sessionObservedZero $false
        Assert-Equal $rows[1].session 3.75
        Assert-Equal $rows[2].sessionResetChanged $false
        Assert-Equal $rows[2].sessionObservedZero $true
        Assert-Equal $rows[2].weeklyResetChanged $true
        Assert-Equal $rows[2].weeklyObservedZero $false
        Assert-Equal $rows[2].weekly 2.125
    }

    Invoke-Test 'stale metadata recovers interrupted append and reset transitions' {
        $dir = New-TestDirectory 'recovery'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        Add-HistorySnapshot $path 10.5 80.5 1900000000L 1900500000L -Now $now
        $extra = New-HistoryRow $now.AddSeconds(10) 2 | ConvertFrom-Json
        $extra.sessionReset = 1900018000L
        [IO.File]::AppendAllText($path, ($extra | ConvertTo-Json -Compress) + [Environment]::NewLine, $utf8)
        Add-HistorySnapshot $path 11.5 81.5 1900018000L 1900500000L -Now $now.AddSeconds(20)
        $rows = @(Read-History $path)
        Assert-Equal $rows.Count 3
        Assert-Equal $rows[2].sessionResetChanged $false 'Rebuild must use the last observation.'
        Assert-Equal (([IO.File]::ReadAllText("$path.state.json") | ConvertFrom-Json).count) 3
        [IO.File]::WriteAllText("$path.state.json", '{corrupt', $utf8)
        Add-HistorySnapshot $path 12.5 82.5 1900018000L 1900500000L -Now $now.AddSeconds(30)
        Assert-Equal @(Read-History $path).Count 4
    }

    Invoke-Test 'failed atomic pruning keeps original history and metadata; cleans staging file' {
        $dir = New-TestDirectory 'atomic'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        Add-HistorySnapshot $path 10.5 80.5 1900000000L 1900500000L -Now $now
        $before = [IO.File]::ReadAllText($path)
        $stateBefore = [IO.File]::ReadAllText("$path.state.json")
        $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { Assert-Throws { Add-HistorySnapshot $path 11.5 81.5 1900000000L 1900500000L -Now $now.AddDays(1) } }
        finally { $reader.Dispose() }
        Assert-Equal ([IO.File]::ReadAllText($path)) $before
        Assert-Equal ([IO.File]::ReadAllText("$path.state.json")) $stateBefore
        Assert-Equal @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -Force).Count 0
        Add-HistorySnapshot $path 11.5 81.5 1900000000L 1900500000L -Now $now.AddDays(1)
        Assert-Equal @(Read-History $path).Count 2
    }

    Invoke-Test 'failure preserves successful data/time and keeps newest three timestamped errors; success clears all' {
        $dir = New-TestDirectory 'errors'
        $path = Join-Path $dir 'Usage.inc'
        $null = Write-Success -Path $path -Response (New-Response) -AuthSource oauth -Now $now
        $before = Read-UsageInc $path
        $history = Join-Path $dir 'UsageHistory.jsonl'
        $historyBefore = [IO.File]::ReadAllText($history)
        $messages = @('Authentication unavailable.', 'Usage request failed (HTTP 503).', 'Invalid usage response.', 'Collector storage failure.')
        for ($i = 0; $i -lt $messages.Count; $i++) {
            Write-Failure -Path $path -Message $messages[$i] -Now $now.AddMinutes($i + 1)
        }
        $after = Read-UsageInc $path
        foreach ($key in $before.Keys) {
            if ($key -notin @('Connected', 'Status', 'Error', 'Error1', 'Error2', 'Error3')) {
                Assert-Equal $after[$key] $before[$key] "Failure changed $key."
            }
        }
        Assert-Equal $after.Connected '0'
        Assert-Equal $after.HasUsageData '1'
        Assert-Equal $after.Status 'Error'
        Assert-Equal $after.Error1 '[2026-09-09T12:38:56.000Z] Collector storage failure.'
        Assert-Equal $after.Error2 '[2026-09-09T12:37:56.000Z] Invalid usage response.'
        Assert-Equal $after.Error3 '[2026-09-09T12:36:56.000Z] Usage request failed (HTTP 503).'
        Assert-Equal $after.Error $after.Error1
        Assert-Equal ([IO.File]::ReadAllText($history)) $historyBefore 'Failure must not append a usage sample.'
        $response = New-Response
        $response.rate_limit.primary_window.used_percent = 14.125
        $null = Write-Success -Path $path -Response $response -AuthSource oauth -Now $now.AddMinutes(5)
        $after = Read-UsageInc $path
        foreach ($key in @('Error', 'Error1', 'Error2', 'Error3')) { Assert-Equal $after[$key] '' }
        Assert-Equal $after.PrimaryPercent '14.125'
        Assert-Equal $after.UpdatedEpoch ([string]$now.AddMinutes(5).ToUnixTimeSeconds())
        Assert-Equal $after.Connected '1'
        Assert-Equal $after.Status 'OK'
    }

    Invoke-Test 'raw errors and legacy secrets are never persisted; cold failure has no fresh timestamp' {
        $dir = New-TestDirectory 'sanitization'
        $path = Join-Path $dir 'Usage.inc'
        $vars = Get-UsageDefaults
        $vars.Error1 = 'Authorization: Bearer secret-token; {"access_token":"secret-body"}'
        $vars.Error2 = '[2026-09-09T12:00:00.000Z] account_id=private-account'
        Write-UsageInc $path $vars
        Write-Failure -Path $path -Message "HTTP 401`r`nPrimaryPercent=0`r`n{`"refresh_token`":`"secret-body`"}" -Now $now
        $text = [IO.File]::ReadAllText($path)
        Assert-True ($text -notmatch 'secret-token|secret-body|private-account|Authorization|access_token|refresh_token|HTTP 401') 'Sensitive error content leaked.'
        $after = Read-UsageInc $path
        Assert-Equal $after.Error1 '[2026-09-09T12:34:56.000Z] Collector operation failed.'
        Assert-Equal $after.Error2 '[2026-09-09T12:34:56.000Z] Collector operation failed.'
        Assert-Equal $after.Error3 '[2026-09-09T12:00:00.000Z] Collector operation failed.'
        $cold = Join-Path $dir 'Cold.inc'
        Write-Failure -Path $cold -Message 'Authentication unavailable.' -Now $now
        $coldVars = Read-UsageInc $cold
        Assert-Equal $coldVars.UpdatedEpoch '0'
        Assert-Equal $coldVars.UpdatedAt '-'
        Assert-Equal $coldVars.HasUsageData '0'
        Assert-Equal $coldVars.Status 'Error'
        Assert-True (-not [IO.File]::Exists((Join-Path $dir 'UsageHistory.jsonl'))) 'Failure created history.'
    }

    Invoke-Test 'legacy warning/forecast defaults remain neutral and PowerShell forecast is removed' {
        Assert-True (-not ($definitions | Where-Object { $_.Name -eq 'Get-Forecast' })) 'Obsolete forecast function remains.'
        $defaults = Get-UsageDefaults
        foreach ($key in @('SessionForecast', 'WeeklyForecast', 'SessionMargin', 'WeeklyMargin')) {
            Assert-Equal $defaults[$key] '-'
        }
        Assert-Equal $defaults.Warning ''
        Assert-Equal $defaults.Severity '0'
        Assert-Equal $defaults.BgColor '18,18,20,220'
    }

    Invoke-Test 'single writer across processes, directory aliases, independent outputs and release' {
        $dir = New-TestDirectory 'lock'
        $other = New-TestDirectory 'other-output'
        $held = Enter-CollectorLock $dir
        Assert-True ($null -ne $held) 'First writer did not acquire the lock.'
        try {
            Assert-Equal (Invoke-LockProbe (Join-Path $dir '.')) 7 'Same output directory must be locked.'
            Assert-Equal (Invoke-LockProbe $other) 0 'Other output directory must remain independent.'
        }
        finally { $held.Dispose() }
        Assert-Equal (Invoke-LockProbe $dir) 0 'OS lock must be released on disposal/process exit.'
        Assert-Equal @(Get-ChildItem -LiteralPath $dir -File -Force).Count 1 'Contention must not write Usage.inc or history.'
    }

    Invoke-Test 'cap retains 84960-86400 samples; full day appends without history reads/replacement' {
        $dir = New-TestDirectory 'cap'
        $path = Join-Path $dir 'UsageHistory.jsonl'
        $capNow = [DateTimeOffset]::Parse('2026-09-09T00:00:00Z')
        $writer = New-Object IO.StreamWriter($path, $false, $utf8)
        try {
            for ($i = 1; $i -le 86400; $i++) {
                $sampleTime = $capNow.AddMinutes($i - 86401)
                $writer.WriteLine('{{"timestamp":"{0}","session":12.625,"weekly":83.375,"sessionReset":1900000000,"weeklyReset":1900500000,"epoch":{1},"id":{2}}}',
                    $sampleTime.UtcDateTime.ToString('o'), $sampleTime.ToUnixTimeSeconds(), $i)
            }
        }
        finally { $writer.Dispose() }
        Add-HistorySnapshot $path 13.625 84.375 1900000000L 1900500000L -Now $capNow
        $lines = [IO.File]::ReadAllLines($path)
        Assert-True ($lines.Length -ge 84960 -and $lines.Length -le 86400) 'Cap pruning must retain at least 59 days of samples.'
        Assert-Equal $lines.Length 84960 'Cap pruning must leave 1440 spare slots.'
        Assert-Equal (($lines[0] | ConvertFrom-Json).id) 1442
        Assert-Equal (($lines[-1] | ConvertFrom-Json).session) 13.625
        Assert-Equal (($lines[-1] | ConvertFrom-Json).epoch) $capNow.ToUnixTimeSeconds()
        $prefix = [IO.File]::ReadAllText($path)
        # Permit append but deny both history reads and replacement for the entire day.
        $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Write)
        try {
            for ($minute = 1; $minute -lt 1440; $minute++) {
                Add-HistorySnapshot $path 14.625 85.375 1900000000L 1900500000L -Now $capNow.AddMinutes($minute)
            }
        }
        finally { $reader.Dispose() }
        Assert-True ([IO.File]::ReadAllText($path).StartsWith($prefix)) 'Appends changed existing history.'
        $lines = [IO.File]::ReadAllLines($path)
        Assert-True ($lines.Length -ge 84960 -and $lines.Length -le 86400) 'Append exceeded retention bounds.'
        Assert-Equal $lines.Length 86399
        Assert-Equal (($lines[-1] | ConvertFrom-Json).session) 14.625
        Assert-Equal (($lines[-1] | ConvertFrom-Json).epoch) $capNow.AddMinutes(1439).ToUnixTimeSeconds()
        Assert-Equal (([IO.File]::ReadAllText("$path.state.json") | ConvertFrom-Json).count) $lines.Length
        # The next UTC day's scheduled prune reaches the cap and creates fresh headroom.
        Add-HistorySnapshot $path 15.625 86.375 1900000000L 1900500000L -Now $capNow.AddDays(1)
        $lines = [IO.File]::ReadAllLines($path)
        Assert-True ($lines.Length -ge 84960 -and $lines.Length -le 86400) 'Daily pruning exceeded retention bounds.'
        Assert-Equal $lines.Length 84960
        Assert-Equal (($lines[-1] | ConvertFrom-Json).session) 15.625
        Assert-Equal (($lines[-1] | ConvertFrom-Json).epoch) $capNow.AddDays(1).ToUnixTimeSeconds()
        $state = [IO.File]::ReadAllText("$path.state.json") | ConvertFrom-Json
        Assert-Equal $state.count $lines.Length
        Assert-Equal $state.prunedDay '2026-09-10'
    }
    Write-Output ("PASS: {0} collector test groups; no auth/network calls." -f $script:passed)
}
finally {
    # Delete only this run's validated, generated TEMP fixture directory.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedPrefix = $testsTemp.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedRoot) -notmatch '^collector-[a-f0-9]{32}$') {
        throw 'Unsafe test cleanup path.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
