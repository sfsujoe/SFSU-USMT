# Compatible with Windows PowerShell 5.1. No migration executable is invoked here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-SfsuHtml([object]$Value) {
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Write-SfsuAtomicText([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $script:Utf8)
        if ([System.IO.File]::Exists($Path)) {
            try {
                [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
            } catch [System.IO.IOException], [System.NotSupportedException], [System.UnauthorizedAccessException] {
                # A share can permit writing report.html while denying atomic replacement.
                # Overwrite only this generated report. The durable journal can rebuild it
                # if this non-atomic fallback is interrupted. Never delete the destination.
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    try {
                        [System.IO.File]::Copy($temporary, $Path, $true)
                        break
                    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                        if ($attempt -eq 2) { throw }
                        Start-Sleep -Milliseconds (100 * ($attempt + 1))
                    }
                }
            }
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } catch {
        throw [System.IO.IOException]::new(
            ('Could not update the HTML report at "' + $Path + '". Check write access and file locks in this app session. The events.jsonl journal is preserved; the HTML report may be stale. ' + $_.Exception.Message),
            $_.Exception)
    } finally {
        # Clean up only the temporary file owned by this call, without hiding a write error.
        try { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
        catch { Write-Warning ('Could not remove temporary report file "' + $temporary + '": ' + $_.Exception.Message) }
    }
}

function Get-SfsuRunHandle([string]$RunDirectory) {
    $directory = (Get-Item -LiteralPath $RunDirectory -ErrorAction Stop).FullName
    [pscustomobject]@{
        RunDirectory = $directory
        RunId = Split-Path $directory -Leaf
        EventsPath = Join-Path $directory 'events.jsonl'
        ReportPath = Join-Path $directory 'report.html'
        RawDirectory = Join-Path $directory 'Raw'
    }
}

function Read-SfsuEvents($Run) {
    $events = New-Object System.Collections.Generic.List[object]
    $invalid = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Run.EventsPath, $script:Utf8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $item = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            foreach ($field in @('Sequence','TimeUtc','Type','StepId','Severity','Message','NextAction','Details','Data')) {
                if ($null -eq $item.PSObject.Properties[$field]) { throw "Missing event field: $field" }
            }
            if ($item.Sequence -ne ($events.Count + 1)) { throw 'Event sequence is incomplete.' }
            [void][DateTimeOffset]::Parse($item.TimeUtc)
            if ($item.Type -notin @('RunStarted','StepStarted','Message','Checkpoint','StepFinished','RawLog','RunFinished') -or
                $item.Severity -notin @('INFO','WARNING','ERROR')) { throw 'Unknown event type or severity.' }
            if ($item.Type -eq 'RunFinished' -and $item.Data.Outcome -notin @('Completed','CompletedWithWarnings','Failed','Cancelled')) {
                throw 'Unknown run outcome.'
            }
            if ($item.Type -eq 'StepFinished' -and $item.Data.Status -notin @('Passed','Warning','Failed','Skipped')) {
                throw 'Unknown step result.'
            }
            if ($item.Type -eq 'Checkpoint' -and $item.Data.Status -notin @('Passed','Warning','Failed','NotRun')) {
                throw 'Unknown checkpoint result.'
            }
            $events.Add($item)
        } catch { $invalid++ }
    }
    if ($events.Count -eq 0 -or $events[0].Type -ne 'RunStarted') {
        throw 'The event journal has no readable run header. Preserve it for troubleshooting.'
    }
    [pscustomobject]@{ Events = $events.ToArray(); InvalidLines = $invalid }
}

function Get-SfsuStepState($Events, [string]$StepId) {
    $started = @($Events | Where-Object { $_.StepId -eq $StepId -and $_.Type -eq 'StepStarted' })
    $finished = @($Events | Where-Object { $_.StepId -eq $StepId -and $_.Type -eq 'StepFinished' })
    [pscustomobject]@{ Started = $started; Finished = $finished }
}

function Assert-SfsuWritableRun($Run, [string]$StepId) {
    $journal = Read-SfsuEvents $Run
    if ($journal.InvalidLines -gt 0) { throw 'The journal is damaged. Regenerate the report; do not append to this run.' }
    if (@($journal.Events | Where-Object Type -eq 'RunFinished').Count -gt 0) { throw 'This run has already ended. Start a new run.' }
    if ($StepId -and @($journal.Events[0].Data.Steps | Where-Object Id -eq $StepId).Count -eq 0) {
        throw "Unknown step: $StepId"
    }
    $journal
}

function Add-SfsuEvent {
    param($Run, [string]$Type, [string]$StepId = '', [string]$Severity = 'INFO',
        [string]$Message, [string]$NextAction = '', [string]$Details = '', $Data = @{})
    $sequence = 1
    if ([System.IO.File]::Exists($Run.EventsPath)) {
        $sequence = (Read-SfsuEvents $Run).Events.Count + 1
    }
    $event = [ordered]@{
        Sequence = $sequence; TimeUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Type = $Type; StepId = $StepId; Severity = $Severity
        Message = $Message; NextAction = $NextAction; Details = $Details; Data = $Data
    }
    $bytes = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $event -Depth 12 -Compress) + "`n")
    $stream = New-Object System.IO.FileStream($Run.EventsPath, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    # The durable journal is written first. A rendering failure never discards its evidence.
    Update-SfsuLogReport -RunDirectory $Run.RunDirectory | Out-Null
}

function New-SfsuLogRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][ValidateSet('Backup','Restore','ReportPreview','ProfileDiscovery','BackupPreparation','BackupInventory','RestoreReview','DirectoryAuthentication')][string]$Operation,
        [Parameter(Mandatory)][object[]]$Steps,
        [string]$Label = '', [switch]$Sample
    )
    $root = (Get-Item -LiteralPath $PackageRoot -ErrorAction Stop).FullName
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'PackageRoot must be a directory.' }
    if ($Steps.Count -eq 0) { throw 'At least one step is required.' }
    $seen = @{}
    $definitions = foreach ($step in $Steps) {
        if ($step.Id -notmatch '^[a-zA-Z0-9_-]+$' -or [string]::IsNullOrWhiteSpace($step.Title)) {
            throw 'Each step requires a simple Id and a non-empty Title.'
        }
        if ($seen.ContainsKey($step.Id)) { throw 'Step IDs must be unique.' }
        $seen[$step.Id] = $true
        [pscustomobject]@{ Id = [string]$step.Id; Title = [string]$step.Title }
    }
    $logs = Join-Path $root 'Logs'
    [void][System.IO.Directory]::CreateDirectory($logs)
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $directory = Join-Path $logs $id
    [void][System.IO.Directory]::CreateDirectory($directory)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $directory 'Raw'))
    $run = Get-SfsuRunHandle $directory
    $logo = Join-Path $root 'App/Assets/SFSU Logo.png'
    $logoData = ''
    if (Test-Path -LiteralPath $logo -PathType Leaf) {
        try { $logoData = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($logo)) } catch { $logoData = '' }
    }
    Add-SfsuEvent -Run $run -Type RunStarted -Message 'Run started.' -Data @{
        RunId = $id; Operation = $Operation; Label = $Label; Sample = [bool]$Sample
        Steps = @($definitions); PackageRoot = $root; LogoData = $logoData
    }
    $run
}

function Start-SfsuLogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId)
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($state.Started.Count -gt 0 -or $state.Finished.Count -gt 0) { throw 'This step has already started or ended.' }
    Add-SfsuEvent -Run $Run -Type StepStarted -StepId $StepId -Message 'Step started.'
}

function Write-SfsuLogEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [string]$StepId = '',
        [ValidateSet('INFO','WARNING','ERROR')][string]$Severity = 'INFO',
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '', [string]$Details = '')
    [void](Assert-SfsuWritableRun $Run $StepId)
    Add-SfsuEvent -Run $Run -Type Message -StepId $StepId -Severity $Severity -Message $Message -NextAction $NextAction -Details $Details
}

function Write-SfsuCheckpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('Passed','Warning','Failed','NotRun')][string]$Status,
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '', [string]$Details = '')
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($Status -ne 'NotRun' -and ($state.Started.Count -eq 0 -or $state.Finished.Count -gt 0)) {
        throw 'Record checkpoint evidence while its step is active.'
    }
    $severity = 'INFO'
    if ($Status -eq 'Warning') { $severity = 'WARNING' }
    if ($Status -eq 'Failed') { $severity = 'ERROR' }
    Add-SfsuEvent -Run $Run -Type Checkpoint -StepId $StepId -Severity $severity -Message $Message -NextAction $NextAction -Details $Details -Data @{ Status = $Status }
}

function Complete-SfsuLogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('Passed','Warning','Failed','Skipped')][string]$Status,
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '')
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($state.Finished.Count -gt 0) { throw 'This step has already ended.' }
    if ($Status -ne 'Skipped' -and $state.Started.Count -eq 0) { throw 'Start the step before completing it.' }
    if ($Status -eq 'Passed') {
        $stepEvents = @($journal.Events | Where-Object StepId -eq $StepId)
        if (@($stepEvents | Where-Object Severity -eq 'ERROR').Count -gt 0) { $Status = 'Failed' }
        elseif (@($stepEvents | Where-Object Severity -eq 'WARNING').Count -gt 0) { $Status = 'Warning' }
    }
    $severity = 'INFO'
    if ($Status -eq 'Warning') { $severity = 'WARNING' }
    if ($Status -eq 'Failed') { $severity = 'ERROR' }
    Add-SfsuEvent -Run $Run -Type StepFinished -StepId $StepId -Severity $severity -Message $Message -NextAction $NextAction -Data @{ Status = $Status }
}

function Complete-SfsuLogRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('Completed','Failed','Cancelled')][string]$Outcome,
        [Parameter(Mandatory)][string]$Message)
    $journal = Assert-SfsuWritableRun $Run ''
    $resolvedOutcome = $Outcome
    if ($Outcome -eq 'Completed') {
        foreach ($step in $journal.Events[0].Data.Steps) {
            $state = Get-SfsuStepState $journal.Events $step.Id
            if ($state.Finished.Count -eq 0 -or $state.Finished[-1].Data.Status -eq 'Skipped') {
                throw 'An unfinished or skipped required step cannot be reported as completed.'
            }
        }
        if (@($journal.Events | Where-Object Severity -eq 'ERROR').Count -gt 0) { $resolvedOutcome = 'Failed' }
        elseif (@($journal.Events | Where-Object Severity -eq 'WARNING').Count -gt 0) { $resolvedOutcome = 'CompletedWithWarnings' }
    }
    $severity = 'INFO'
    if ($resolvedOutcome -eq 'Failed') { $severity = 'ERROR' }
    if ($resolvedOutcome -eq 'CompletedWithWarnings') { $severity = 'WARNING' }
    Add-SfsuEvent -Run $Run -Type RunFinished -Severity $severity -Message $Message -Data @{ Outcome = $resolvedOutcome }
    $Run.ReportPath
}

function Get-SfsuRawLogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Use a simple raw-log filename without directories.' }
    Join-Path $Run.RawDirectory $Name
}

function Add-SfsuRawLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Name, [string]$StepId = '')
    [void](Assert-SfsuWritableRun $Run $StepId)
    $path = Get-SfsuRawLogPath -Run $Run -Name $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Write the raw log before registering it.' }
    Add-SfsuEvent -Run $Run -Type RawLog -StepId $StepId -Message "Original diagnostic log: $Name" -Data @{ Name = $Name }
}

function Update-SfsuLogReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    $run = Get-SfsuRunHandle $RunDirectory
    $journal = Read-SfsuEvents $run
    $events = @($journal.Events)
    $header = $events[0].Data
    $finished = @($events | Where-Object Type -eq 'RunFinished')
    $outcome = 'Incomplete'
    $resultText = 'No final result was recorded. This run may still be active or may have been interrupted.'
    if ($finished.Count -gt 0 -and $journal.InvalidLines -eq 0) {
        $outcome = $finished[-1].Data.Outcome
        $resultText = $finished[-1].Message
    }
    $outcomeLabels = @{ Incomplete='Incomplete'; Completed='Completed'; CompletedWithWarnings='Completed with warnings'; Failed='Failed'; Cancelled='Cancelled' }
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
    $stepTitles = @{}
    $stepsHtml = New-Object System.Text.StringBuilder
    $position = 0
    foreach ($definition in $header.Steps) {
        $position++
        $stepTitles[$definition.Id] = $definition.Title
        $state = Get-SfsuStepState $events $definition.Id
        $status = 'Not run'; $duration = '--'; $message = 'No work recorded.'
        if ($state.Started.Count -gt 0) {
            $status = 'Incomplete'; $message = 'Started; no step result recorded.'
            $endTime = [DateTimeOffset]::Parse($events[-1].TimeUtc)
            if ($state.Finished.Count -gt 0) { $endTime = [DateTimeOffset]::Parse($state.Finished[-1].TimeUtc) }
            $duration = '{0:0.0} s' -f ($endTime - [DateTimeOffset]::Parse($state.Started[0].TimeUtc)).TotalSeconds
        }
        if ($state.Finished.Count -gt 0) { $status = $state.Finished[-1].Data.Status; $message = $state.Finished[-1].Message }
        $class = ConvertTo-SfsuHtml $status.ToLowerInvariant().Replace(' ','-')
        $badge = ConvertTo-SfsuHtml $status
        if ($status -eq 'Failed') { $badge = '! ERROR' }
        if ($status -eq 'Warning') { $badge = '! WARNING' }
        [void]$stepsHtml.Append('<li class="step ' + $class + '"><div class="step-top"><span class="step-number">' + $position + '</span><h3>' + (ConvertTo-SfsuHtml $definition.Title) + '</h3><strong class="badge">' + $badge + '</strong><span class="duration">' + $duration + '</span></div><p>' + (ConvertTo-SfsuHtml $message) + '</p>')
        foreach ($checkpoint in @($events | Where-Object { $_.Type -eq 'Checkpoint' -and $_.StepId -eq $definition.Id })) {
            $checkpointStatus = [string]$checkpoint.Data.Status
            $checkpointLabel = $checkpointStatus
            if ($checkpointStatus -eq 'NotRun') { $checkpointLabel = 'Not run' }
            if ($checkpointStatus -eq 'Failed') { $checkpointLabel = '! ERROR' }
            if ($checkpointStatus -eq 'Warning') { $checkpointLabel = '! WARNING' }
            [void]$stepsHtml.Append('<div class="checkpoint"><strong>Checkpoint: ' + (ConvertTo-SfsuHtml $checkpointLabel) + '</strong> &mdash; ' + (ConvertTo-SfsuHtml $checkpoint.Message))
            if ($checkpoint.NextAction) { [void]$stepsHtml.Append('<br><span>Next action: ' + (ConvertTo-SfsuHtml $checkpoint.NextAction) + '</span>') }
            [void]$stepsHtml.Append('</div>')
        }
        [void]$stepsHtml.Append('</li>')
    }
    $rows = New-Object System.Text.StringBuilder
    foreach ($event in $events) {
        $utcTime = [DateTimeOffset]::Parse($event.TimeUtc)
        $time = [TimeZoneInfo]::ConvertTime($utcTime, $zone).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
        $title = 'Run'
        if ($event.StepId) { $title = $stepTitles[$event.StepId] }
        $severityText = $event.Severity
        if ($event.Severity -in @('ERROR','WARNING')) { $severityText = '! ' + $severityText }
        $severityText = ConvertTo-SfsuHtml $severityText
        $details = ''
        if ($event.Details) { $details = '<details><summary>Technical details</summary><pre>' + (ConvertTo-SfsuHtml $event.Details) + '</pre></details>' }
        $message = ConvertTo-SfsuHtml $event.Message
        if ($event.Type -eq 'Checkpoint') {
            $checkpointLabel = [string]$event.Data.Status
            if ($checkpointLabel -eq 'NotRun') { $checkpointLabel = 'Not run' }
            $message = '<strong>Checkpoint: ' + (ConvertTo-SfsuHtml $checkpointLabel) + '</strong><br>' + $message
        }
        [void]$rows.Append('<tr data-severity="' + (ConvertTo-SfsuHtml $event.Severity) + '"><td>' + $event.Sequence + '</td><td class="time" data-sort="' + $utcTime.ToUnixTimeMilliseconds() + '">' + $time + '</td><td>' + (ConvertTo-SfsuHtml $title) + '</td><td class="severity">' + $severityText + '</td><td>' + $message + $details + '</td><td>' + (ConvertTo-SfsuHtml $event.NextAction) + '</td></tr>')
    }
    $rawLinks = New-Object System.Text.StringBuilder
    # Discover raw files as well as registered events: interrupted engines may leave unregistered logs.
    foreach ($file in @(Get-ChildItem -LiteralPath $run.RawDirectory -File | Sort-Object Name)) {
        [void]$rawLinks.Append('<li><a href="Raw/' + [Uri]::EscapeDataString($file.Name) + '">' + (ConvertTo-SfsuHtml $file.Name) + '</a></li>')
    }
    if ($rawLinks.Length -eq 0) { [void]$rawLinks.Append('<li>No original USMT logs have been recorded.</li>') }
    $notice = ''
    if ($header.Sample) { $notice = '<div class="sample">SAMPLE REPORT &mdash; simulated events only. No migration, store verification, or restore test was performed.</div>' }
    if ($journal.InvalidLines -gt 0) { $notice += '<div class="alert">! ERROR: The event journal contains unreadable or out-of-sequence records. Result is Incomplete. Preserve the original journal.</div>' }
    $snapshotError = Join-Path $run.RunDirectory 'snapshot-error.txt'
    if (Test-Path -LiteralPath $snapshotError -PathType Leaf) {
        $notice += '<div class="alert">! WARNING: A backup log copy could not be completed. These root logs remain available. ' + (ConvertTo-SfsuHtml ([System.IO.File]::ReadAllText($snapshotError))) + '</div>'
    }
    $logoHtml = ''
    if ($header.LogoData) { $logoHtml = '<img class="logo" alt="San Francisco State University" src="data:image/png;base64,' + (ConvertTo-SfsuHtml $header.LogoData) + '">' }
    $operationTitle = [string]$header.Operation
    if ($operationTitle -eq 'ReportPreview') { $operationTitle = 'Reporting preview' }
    $operationLabels = @{ ProfileDiscovery='Profile discovery'; BackupPreparation='Backup folder preparation'; BackupInventory='Backup inventory'; RestoreReview='Restore selection review'; DirectoryAuthentication='Active Directory authentication' }
    if ($operationLabels.ContainsKey($operationTitle)) { $operationTitle = $operationLabels[$operationTitle] }
    $tokens = @{
        TITLE = ConvertTo-SfsuHtml ($operationTitle + ' report')
        LABEL = ConvertTo-SfsuHtml $header.Label
        RUNID = ConvertTo-SfsuHtml $header.RunId
        OUTCOME = ConvertTo-SfsuHtml $outcomeLabels[$outcome]
        OUTCOMECLASS = ConvertTo-SfsuHtml $outcome.ToLowerInvariant()
        RESULT = ConvertTo-SfsuHtml $resultText
        NOTICE = $notice; LOGO = $logoHtml; STEPS = $stepsHtml.ToString(); ROWS = $rows.ToString(); RAWLINKS = $rawLinks.ToString()
        ASOF = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($events[-1].TimeUtc), $zone).ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
    $template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../Reporting/report.template.html'))
    $renderer = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) [string]$tokens[$match.Groups[1].Value] }
    $html = [regex]::Replace($template, '@@([A-Z]+)@@', $renderer)
    Write-SfsuAtomicText $run.ReportPath $html
    $run.ReportPath
}

function Export-SfsuLogSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$BackupPath)
    $journal = Read-SfsuEvents $Run
    if ($journal.InvalidLines -gt 0 -or @($journal.Events | Where-Object Type -eq 'RunFinished').Count -eq 0) {
        throw 'Only an ended, readable run can be copied as a finalized backup log snapshot.'
    }
    $root = [string]$journal.Events[0].Data.PackageRoot
    $backupsRoot = [System.IO.Path]::GetFullPath((Join-Path $root 'Backups')).TrimEnd('\') + '\'
    $backup = (Get-Item -LiteralPath $BackupPath -ErrorAction Stop).FullName
    if (-not (Test-Path -LiteralPath $backup -PathType Container) -or
        -not $backup.StartsWith($backupsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an existing backup directory inside this package Backups folder.'
    }
    $destination = Join-Path (Join-Path $backup 'Logs') $Run.RunId
    if (Test-Path -LiteralPath $destination) { throw 'This snapshot already exists; it will not be overwritten.' }
    try {
        [void][System.IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        $staging = $destination + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        Copy-Item -LiteralPath $Run.RunDirectory -Destination $staging -Recurse -ErrorAction Stop
        # A scanner/indexer or SMB lease can briefly hold the just-copied folder.
        # Retry only the final rename; preserve the original failure/partial copy if it persists.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try { [System.IO.Directory]::Move($staging, $destination); break }
            catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Milliseconds (200 * $attempt)
            }
        }
        Join-Path $destination 'report.html'
    } catch {
        [System.IO.File]::WriteAllText((Join-Path $Run.RunDirectory 'snapshot-error.txt'), $_.Exception.Message, $script:Utf8)
        Update-SfsuLogReport -RunDirectory $Run.RunDirectory | Out-Null
        throw
    }
}

Export-ModuleMember -Function New-SfsuLogRun, Start-SfsuLogStep, Write-SfsuLogEvent, Write-SfsuCheckpoint,
    Complete-SfsuLogStep, Complete-SfsuLogRun, Get-SfsuRawLogPath, Add-SfsuRawLog, Update-SfsuLogReport, Export-SfsuLogSnapshot
