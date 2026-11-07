[CmdletBinding()]
param(
    [switch]$Headless,
    [ValidateSet('Completed','Warnings','Failed','Cancelled','Incomplete')][string]$Scenario = 'Completed',
    [string]$SnapshotBackupPath = '',
    [string]$RebuildReport = '',
    [string]$LdapServer = 'ad.sfsu.edu',
    [switch]$DiscoverProfiles,
    [System.Management.Automation.PSCredential]$DirectoryCredential,
    [switch]$ReviewStorageAccess,
    [ValidateRange(1,3650)][int]$LogRetentionDays=30,
    [switch]$PreviewLogRetention,
    [switch]$ApplyLogRetention,
    [switch]$BuildUiOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:CurrentRun = $null
$guiRequested = -not ($Headless -or $DiscoverProfiles -or $RebuildReport -or $BuildUiOnly -or $ReviewStorageAccess -or $PreviewLogRetention -or $ApplyLogRetention -or $SnapshotBackupPath)

function Show-SfsuStartupError([string]$DetailsPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $message='SFSU USMT could not start.'
    if ($DetailsPath) { $message+="`r`n`r`nStartup details: "+$DetailsPath }
    else { $message+="`r`n`r`nStartup details could not be saved. Check access to the toolkit folder, or run the PowerShell entry script from a console to view the error." }
    [void][Windows.Forms.MessageBox]::Show($message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
}

function New-SfsuSampleReport {
    param([string]$SelectedScenario)
    $steps = @(
        @{ Id='destination'; Title='Check backup destination' },
        @{ Id='capture'; Title='Capture employee files (simulated)' },
        @{ Id='verify'; Title='Verify store (simulated)' }
    )
    $run = New-SfsuLogRun -PackageRoot $packageRoot -Operation ReportPreview -Steps $steps -Sample -Label "$SelectedScenario sample. No employee data was accessed."
    $script:CurrentRun = $run
    try {
        Start-SfsuLogStep -Run $run -StepId destination
        $backups = Join-Path $packageRoot 'Backups'
        [void][System.IO.Directory]::CreateDirectory($backups)
        # Probe only our own uniquely named file; never touch an existing backup.
        $probe = Join-Path $backups ('.sfsu-write-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $probeStream = New-Object System.IO.FileStream($probe, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
        try { $probeStream.WriteByte(0); $probeStream.Flush($true) } finally { $probeStream.Dispose() }
        Write-SfsuCheckpoint -Run $run -StepId destination -Status Passed -Message 'The Backups folder exists and accepted a temporary write test. Existing backups were preserved.'
        Complete-SfsuLogStep -Run $run -StepId destination -Status Passed -Message 'Backup destination access check passed.'
        Start-SfsuLogStep -Run $run -StepId capture
        Write-SfsuLogEvent -Run $run -StepId capture -Message 'Simulation started. ScanState will not be launched.'
        $raw = Get-SfsuRawLogPath -Run $run -Name 'sample-scanstate.log'
        [System.IO.File]::WriteAllText($raw, "SAMPLE ONLY - synthetic diagnostic text, not USMT output.`r`nScenario: $SelectedScenario`r`nNo migration was performed.`r`n")
        Add-SfsuRawLog -Run $run -StepId capture -Name 'sample-scanstate.log'
        if ($SelectedScenario -eq 'Incomplete') {
            Write-SfsuLogEvent -Run $run -StepId capture -Message 'The sample stops here without a completion record, demonstrating interruption recovery.' -NextAction 'Inspect the last recorded step; do not assume the backup completed.'
            return $run.ReportPath
        }
        if ($SelectedScenario -eq 'Cancelled') {
            Write-SfsuLogEvent -Run $run -StepId capture -Message 'The technician cancelled this simulated operation.'
            Complete-SfsuLogStep -Run $run -StepId capture -Status Skipped -Message 'Capture did not finish because the sample was cancelled.'
            Write-SfsuCheckpoint -Run $run -StepId verify -Status NotRun -Message 'Store verification was not performed.'
            Complete-SfsuLogStep -Run $run -StepId verify -Status Skipped -Message 'Not run after cancellation.'
            return (Complete-SfsuLogRun -Run $run -Outcome Cancelled -Message 'The simulated run was cancelled. No backup was created.')
        }
        if ($SelectedScenario -eq 'Failed') {
            Write-SfsuCheckpoint -Run $run -StepId capture -Status Failed -Message 'Simulated connection loss: capture did not complete.' -NextAction 'Check the connection and destination access before retrying.' -Details 'Synthetic error for report review. This is not a USMT return code.'
            Complete-SfsuLogStep -Run $run -StepId capture -Status Failed -Message 'Simulated capture failed.'
            Write-SfsuCheckpoint -Run $run -StepId verify -Status NotRun -Message 'Store verification was not performed because capture failed.'
            Complete-SfsuLogStep -Run $run -StepId verify -Status Skipped -Message 'Not run after capture failure.'
            return (Complete-SfsuLogRun -Run $run -Outcome Failed -Message 'The sample demonstrates a failed capture. No backup was created.')
        }
        if ($SelectedScenario -eq 'Warnings') {
            Write-SfsuLogEvent -Run $run -StepId capture -Severity WARNING -Message 'Simulated warning: one file was unavailable and was not collected.' -NextAction 'Review the original diagnostic log and resolve missing files before accepting the backup.' -Details 'Synthetic file warning; no real file was skipped.'
            Complete-SfsuLogStep -Run $run -StepId capture -Status Warning -Message 'Simulated capture completed with a file warning.'
        } else {
            Complete-SfsuLogStep -Run $run -StepId capture -Status Passed -Message 'Simulated capture stage completed.'
        }
        Start-SfsuLogStep -Run $run -StepId verify
        Write-SfsuCheckpoint -Run $run -StepId verify -Status Passed -Message 'Simulated store verification passed. No real store was verified.'
        Complete-SfsuLogStep -Run $run -StepId verify -Status Passed -Message 'Simulated verification completed; an actual restore test was not performed.'
        Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'The reporting sample finished. This is not evidence of a successful migration.'
    } catch {
        $failure = $_
        try {
            Write-SfsuLogEvent -Run $run -Severity ERROR -Message 'The reporting preview could not finish.' -NextAction 'Check folder access and the technical details.' -Details $failure.Exception.Message
            Complete-SfsuLogRun -Run $run -Outcome Failed -Message 'The reporting preview failed.' | Out-Null
        } catch { Write-Warning 'Could not finish writing the run log. Preserve the existing Logs folder.' }
        throw $failure
    }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'Sfsu.Logging.psm1') -Force
    if ($ReviewStorageAccess -or $PreviewLogRetention -or $ApplyLogRetention) {
        if ($DiscoverProfiles -or $Headless -or $RebuildReport -or $BuildUiOnly -or $DirectoryCredential -or $SnapshotBackupPath) { throw 'Run package maintenance separately from application actions.' }
        Import-Module (Join-Path $PSScriptRoot 'Sfsu.Maintenance.psm1') -Force
        if ($ReviewStorageAccess) { Get-SfsuStorageAccessReview $packageRoot }
        if ($PreviewLogRetention -or $ApplyLogRetention) { Invoke-SfsuLogRetention -PackageRoot $packageRoot -Days $LogRetentionDays -Apply:$ApplyLogRetention }
        exit 0
    }
    if ($RebuildReport) {
        Update-SfsuLogReport -RunDirectory $RebuildReport
        exit 0
    }
    if ($DiscoverProfiles) {
        Import-Module (Join-Path $PSScriptRoot 'Sfsu.Inventory.psm1') -Force
        $discovery = Invoke-SfsuProfileDiscovery -PackageRoot $packageRoot -Server $LdapServer -Credential $DirectoryCredential -SkipDirectoryLookup:($null -eq $DirectoryCredential)
        Write-Output $discovery.ReportPath
        exit 0
    }
    if ($SnapshotBackupPath -and -not $Headless) { throw 'Use -Headless when requesting a sample log snapshot.' }
    if ($Headless) {
        $report = New-SfsuSampleReport -SelectedScenario $Scenario
        Write-Output $report
        if ($SnapshotBackupPath) { Export-SfsuLogSnapshot -Run $script:CurrentRun -BackupPath $SnapshotBackupPath }
        exit 0
    }
    . (Join-Path $PSScriptRoot 'Sfsu.Ui.ps1')
} catch {
    # Startup may fail before the reporting module is available. Keep a plain-text fallback.
    $failureText = $_.Exception.ToString()
    $failurePath = ''
    try {
        $logsPath = Join-Path $packageRoot 'Logs'
        if (Get-Command Assert-SfsuSafePath -ErrorAction SilentlyContinue) { [void](Assert-SfsuSafePath $logsPath -AllowMissing) }
        [void][System.IO.Directory]::CreateDirectory($logsPath)
        $failurePath = Join-Path $logsPath ('startup-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($failurePath, $failureText)
        [Console]::Error.WriteLine('Startup details: ' + $failurePath)
    } catch { $failurePath=''; [Console]::Error.WriteLine('The Logs folder is not writable. Save the error shown below.') }
    [Console]::Error.WriteLine($failureText)
    if ($guiRequested) {
        try { Show-SfsuStartupError -DetailsPath $failurePath }
        catch { [Console]::Error.WriteLine('Could not display the startup error dialog.') }
    }
    exit 1
}
