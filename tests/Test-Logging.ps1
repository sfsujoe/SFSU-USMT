# Run with Windows PowerShell 5.1. Only synthetic data is used; USMT is never launched.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $PSScriptRoot ('.work/portable package & spaces (' + [guid]::NewGuid().ToString('N').Substring(0,8) + ')')
[void][System.IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][System.IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
foreach ($name in @('Sfsu.Logging.psm1','Start-SfsuUsmt.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repository "App/Scripts/$name") -Destination (Join-Path $testRoot "App/Scripts/$name")
}
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
Copy-Item -LiteralPath (Join-Path $repository 'sfsu-usmt.cmd') -Destination (Join-Path $testRoot 'sfsu-usmt.cmd')
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1') -Force
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true }
    Assert-True $caught $Message
}
function New-TestRun {
    New-SfsuLogRun -PackageRoot $testRoot -Operation ReportPreview -Sample -Steps @(
        @{ Id='access'; Title='Check destination' }, @{ Id='capture'; Title='Capture (sample)' }
    ) -Label 'Synthetic validation only'
}
function Finish-TestSteps($Run) {
    foreach ($id in @('access','capture')) {
        Start-SfsuLogStep -Run $Run -StepId $id
        Write-SfsuCheckpoint -Run $Run -StepId $id -Status Passed -Message "Synthetic evidence: $id"
        Complete-SfsuLogStep -Run $Run -StepId $id -Status Passed -Message "Sample $id completed."
    }
}
function Read-Report($Run) { [System.IO.File]::ReadAllText($Run.ReportPath) }

# A success-looking completion cannot be emitted for work that did not run.
$initial = New-TestRun
Assert-True ((Read-Report $initial).Contains('id="outcome">Incomplete</h2>')) 'New runs start Incomplete.'
Assert-Throws { Complete-SfsuLogRun -Run $initial -Outcome Completed -Message 'Done' } 'Unfinished required steps reject completion.'
Assert-Throws { Write-SfsuCheckpoint -Run $initial -StepId access -Status Passed -Message 'Claim' } 'Checkpoint evidence needs an active step.'
Assert-Throws { Start-SfsuLogStep -Run $initial -StepId missing } 'Unknown steps are rejected.'
Start-SfsuLogStep -Run $initial -StepId access
Assert-Throws { Start-SfsuLogStep -Run $initial -StepId access } 'Duplicate starts are rejected.'
Write-SfsuCheckpoint -Run $initial -StepId access -Status Passed -Message 'Folder is writable (sample).'
Complete-SfsuLogStep -Run $initial -StepId access -Status Passed -Message 'Access checked.'
Assert-Throws { Write-SfsuCheckpoint -Run $initial -StepId access -Status Passed -Message 'Late claim' } 'Completed steps reject late checkpoints.'
Start-SfsuLogStep -Run $initial -StepId capture
$unsafe = '<script>window.injected=true</script> & "quoted" @@ROWS@@'
Write-SfsuLogEvent -Run $initial -StepId capture -Message $unsafe -Details $unsafe -NextAction $unsafe
$rawPath = Get-SfsuRawLogPath -Run $initial -Name 'scanstate.log'
[System.IO.File]::WriteAllText($rawPath, 'SYNTHETIC original diagnostic bytes <not HTML>')
$originalHash = (Get-FileHash -LiteralPath $rawPath).Hash
Add-SfsuRawLog -Run $initial -Name 'scanstate.log' -StepId capture
Complete-SfsuLogStep -Run $initial -StepId capture -Status Passed -Message 'Sample capture completed.'
Complete-SfsuLogRun -Run $initial -Outcome Completed -Message 'Synthetic reporting checks completed.' | Out-Null
$successHtml = Read-Report $initial
Assert-True ($successHtml.Contains('id="outcome">Completed</h2>')) 'Completed steps produce Completed.'
Assert-True (-not $successHtml.Contains('<script>window.injected=true</script>')) 'Messages cannot inject script markup.'
Assert-True ($successHtml.Contains('&lt;script&gt;window.injected=true&lt;/script&gt;')) 'Messages and details are HTML-escaped.'
Assert-True ($successHtml.Contains('@@ROWS@@')) 'User text is not interpreted as template tokens.'
Assert-True ($successHtml.Contains('href="Raw/scanstate.log"')) 'Original diagnostics use portable relative links.'
Assert-True (-not ($successHtml -match '(src|href)="https?://')) 'Report has no remote resource dependencies.'
Assert-Throws { Write-SfsuLogEvent -Run $initial -Message 'Late event' } 'Finalized journals are immutable.'
Assert-Throws { Get-SfsuRawLogPath -Run $initial -Name '../escape.log' } 'Raw log paths cannot escape Raw.'

# Severity must carry through to step and run results, even if a caller asks for Passed.
$warning = New-TestRun
Start-SfsuLogStep -Run $warning -StepId access
Write-SfsuLogEvent -Run $warning -StepId access -Severity WARNING -Message 'Synthetic warning.'
Complete-SfsuLogStep -Run $warning -StepId access -Status Passed -Message 'Access check finished.'
Start-SfsuLogStep -Run $warning -StepId capture
Complete-SfsuLogStep -Run $warning -StepId capture -Status Passed -Message 'Sample capture finished.'
Complete-SfsuLogRun -Run $warning -Outcome Completed -Message 'Finished with a warning.' | Out-Null
Assert-True ((Read-Report $warning).Contains('id="outcome">Completed with warnings</h2>')) 'Warnings propagate to the overall result.'
Assert-True ((Read-Report $warning).Contains('class="step warning"')) 'Warnings cannot be hidden by a Passed step.'
$failed = New-TestRun
Start-SfsuLogStep -Run $failed -StepId access
Write-SfsuCheckpoint -Run $failed -StepId access -Status Failed -Message 'Synthetic access failure.' -NextAction 'Check the destination.'
Complete-SfsuLogStep -Run $failed -StepId access -Status Passed -Message 'Check finished.'
Start-SfsuLogStep -Run $failed -StepId capture
Complete-SfsuLogStep -Run $failed -StepId capture -Status Passed -Message 'Sample only.'
Complete-SfsuLogRun -Run $failed -Outcome Completed -Message 'Caller asked for completion.' | Out-Null
Assert-True ((Read-Report $failed).Contains('id="outcome">Failed</h2>')) 'Errors cannot become a successful overall result.'
Assert-True ((Read-Report $failed).Contains('class="step failed"')) 'Errors cannot be hidden by a Passed step.'
Assert-True ((Read-Report $failed).Contains('! ERROR')) 'Errors include an exclamation mark and text.'

$cancelled = New-TestRun
Complete-SfsuLogStep -Run $cancelled -StepId access -Status Skipped -Message 'Cancelled before starting.'
Assert-Throws { Complete-SfsuLogRun -Run $cancelled -Outcome Completed -Message 'Done' } 'Skipped required steps cannot produce Completed.'
Complete-SfsuLogRun -Run $cancelled -Outcome Cancelled -Message 'Technician cancelled (sample).' | Out-Null
Assert-True ((Read-Report $cancelled).Contains('id="outcome">Cancelled</h2>')) 'Cancellation is separate from failure and success.'

# Regenerate from durable evidence after a missing/stale report or truncated final write.
$interrupted = New-TestRun
Start-SfsuLogStep -Run $interrupted -StepId access
[System.IO.File]::WriteAllText((Get-SfsuRawLogPath -Run $interrupted -Name 'unregistered.log'), 'Synthetic partial engine output')
[System.IO.File]::WriteAllText($interrupted.ReportPath, 'stale report')
Update-SfsuLogReport -RunDirectory $interrupted.RunDirectory | Out-Null
Assert-True ((Read-Report $interrupted).Contains('id="outcome">Incomplete</h2>')) 'Interrupted runs rebuild as Incomplete.'
Assert-True ((Read-Report $interrupted).Contains('href="Raw/unregistered.log"')) 'Interrupted runs retain unregistered raw diagnostics.'
[System.IO.File]::AppendAllText($interrupted.EventsPath, '{"truncated":')
Update-SfsuLogReport -RunDirectory $interrupted.RunDirectory | Out-Null
Assert-True ((Read-Report $interrupted).Contains('unreadable or out-of-sequence records')) 'Truncated journals produce a visible diagnostic.'
Assert-Throws { Write-SfsuLogEvent -Run $interrupted -Message 'Append' } 'Damaged journals cannot be silently extended.'
$tampered = New-TestRun
Finish-TestSteps $tampered
Complete-SfsuLogRun -Run $tampered -Outcome Completed -Message 'Synthetic completion.' | Out-Null
$lines = [System.IO.File]::ReadAllLines($tampered.EventsPath)
$last = ConvertFrom-Json -InputObject $lines[-1]
$last.Severity = '<script>window.injected=true</script>'
$lines[-1] = ConvertTo-Json -InputObject $last -Depth 12 -Compress
[System.IO.File]::WriteAllLines($tampered.EventsPath, $lines)
Update-SfsuLogReport -RunDirectory $tampered.RunDirectory | Out-Null
Assert-True ((Read-Report $tampered).Contains('id="outcome">Incomplete</h2>')) 'Malformed result fields cannot claim success.'
Assert-True (-not (Read-Report $tampered).Contains('<script>window.injected=true</script>')) 'Malformed journal fields cannot inject HTML.'

# Logs travel with a backup without altering the backup or replacing previous snapshots.
$backup = Join-Path $testRoot 'Backups/existing-backup'
[void][System.IO.Directory]::CreateDirectory($backup)
$sentinel = Join-Path $backup 'existing-data.bin'
[System.IO.File]::WriteAllBytes($sentinel, [byte[]](1,2,3,4,5))
$sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash
$snapshot = Export-SfsuLogSnapshot -Run $initial -BackupPath $backup
Assert-True (Test-Path -LiteralPath $snapshot -PathType Leaf) 'Finalized reports can be copied into a backup.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path (Split-Path $snapshot -Parent) 'Raw/scanstate.log')).Hash -eq $originalHash) 'Original logs are copied byte-for-byte.'
Assert-True ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sentinelHash) 'Existing backup data is unchanged.'
Assert-Throws { Export-SfsuLogSnapshot -Run $initial -BackupPath $backup } 'Existing snapshots cannot be overwritten.'
Assert-Throws { Export-SfsuLogSnapshot -Run $interrupted -BackupPath $backup } 'Interrupted/damaged runs are not finalized snapshots.'
Assert-Throws { Export-SfsuLogSnapshot -Run $initial -BackupPath $testRoot } 'Snapshot destinations must be inside Backups.'
$blockedBackup = Join-Path $testRoot 'Backups/blocked-log-copy'
[void][System.IO.Directory]::CreateDirectory($blockedBackup)
[System.IO.File]::WriteAllText((Join-Path $blockedBackup 'Logs'), 'A file blocks directory creation (synthetic test).')
Assert-Throws { Export-SfsuLogSnapshot -Run $warning -BackupPath $blockedBackup } 'Copy failures are surfaced.'
Assert-True ((Read-Report $warning).Contains('A backup log copy could not be completed')) 'Copy failures are visible in the root report.'

# Run the actual CMD from a different working directory, through paths containing spaces and &.
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = $env:ComSpec
$start.Arguments = '/d /c ""' + (Join-Path $testRoot 'sfsu-usmt.cmd') + '" -Headless -Scenario Completed"'
$start.WorkingDirectory = $PSScriptRoot
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [System.Diagnostics.Process]::Start($start)
$output = $process.StandardOutput.ReadToEnd()
$errors = $process.StandardError.ReadToEnd()
$process.WaitForExit()
Assert-True ($process.ExitCode -eq 0) ('Portable CMD launch succeeds. ' + $errors)
$launchedReport = $output.Trim()
Assert-True (Test-Path -LiteralPath $launchedReport -PathType Leaf) 'Launcher prints the generated report path.'
Assert-True ($launchedReport.StartsWith((Join-Path $testRoot 'Logs'))) 'Logs follow the package location, not the working directory.'
Assert-True ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sentinelHash) 'Startup preserves existing Backups content.'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Backups') -Filter '.sfsu-write-check-*' -File).Count -eq 0) 'Write probes leave no files behind.'

foreach ($scenario in @('Warnings','Failed','Cancelled','Incomplete')) {
    $sampleOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1') -Headless -Scenario $scenario
    Assert-True ($LASTEXITCODE -eq 0) ("Headless $scenario sample generates successfully.")
    $sampleHtml = [System.IO.File]::ReadAllText(([string]$sampleOutput).Trim())
    $expected = $scenario
    if ($scenario -eq 'Warnings') { $expected = 'Completed with warnings' }
    Assert-True ($sampleHtml.Contains('id="outcome">' + $expected + '</h2>')) ("Headless $scenario sample records the correct result.")
}

# Parse all shipped PowerShell sources under the actual 5.1 parser.
foreach ($source in Get-ChildItem -LiteralPath (Join-Path $repository 'App/Scripts') -File) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) ('PowerShell syntax: ' + $source.Name)
}
Write-Output ("PASS: $script:Assertions assertions on PowerShell " + $PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: ' + $testRoot)
