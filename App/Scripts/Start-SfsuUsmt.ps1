[CmdletBinding()]
param(
    [switch]$Headless,
    [ValidateSet('Completed','Warnings','Failed','Cancelled','Incomplete')][string]$Scenario = 'Completed',
    [string]$SnapshotBackupPath = '',
    [string]$RebuildReport = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:CurrentRun = $null

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
    if ($RebuildReport) {
        Update-SfsuLogReport -RunDirectory $RebuildReport
        exit 0
    }
    if ($SnapshotBackupPath -and -not $Headless) { throw 'Use -Headless when requesting a sample log snapshot.' }
    if ($Headless) {
        $report = New-SfsuSampleReport -SelectedScenario $Scenario
        Write-Output $report
        if ($SnapshotBackupPath) { Export-SfsuLogSnapshot -Run $script:CurrentRun -BackupPath $SnapshotBackupPath }
        exit 0
    }
    [void][System.IO.Directory]::CreateDirectory((Join-Path $packageRoot 'Backups'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $packageRoot 'Logs'))
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SFSU USMT - Reporting Preview'
    $form.ClientSize = New-Object System.Drawing.Size(760, 430)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.BackColor = [System.Drawing.Color]::White
    $header = New-Object System.Windows.Forms.Panel
    $header.SetBounds(0, 0, 760, 90)
    $header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#442C8B')
    $form.Controls.Add($header)
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'SFSU USMT - Reporting Preview'
    $title.SetBounds(24, 24, 700, 44)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#FFD24F')
    $header.Controls.Add($title)
    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = 'Generate sample HTML reports. Migration operations are not connected; no employee data is accessed and no backup store is created.'
    $notice.SetBounds(24, 112, 710, 60)
    $form.Controls.Add($notice)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Sample outcome'
    $label.SetBounds(24, 186, 180, 26)
    $form.Controls.Add($label)
    $choice = New-Object System.Windows.Forms.ComboBox
    $choice.SetBounds(24, 216, 260, 32)
    $choice.DropDownStyle = 'DropDownList'
    [void]$choice.Items.AddRange(@('Completed','Warnings','Failed','Cancelled','Incomplete'))
    $choice.SelectedIndex = 0
    $form.Controls.Add($choice)
    $generate = New-Object System.Windows.Forms.Button
    $generate.Text = 'Create sample report'
    $generate.SetBounds(304, 212, 210, 38)
    $generate.BackColor = $header.BackColor
    $generate.ForeColor = [System.Drawing.Color]::White
    $generate.FlatStyle = 'Flat'
    $form.Controls.Add($generate)
    $open = New-Object System.Windows.Forms.Button
    $open.Text = 'Open latest report'
    $open.SetBounds(24, 278, 220, 38)
    $open.Enabled = $false
    $form.Controls.Add($open)
    $logs = New-Object System.Windows.Forms.Button
    $logs.Text = 'Open Logs folder'
    $logs.SetBounds(260, 278, 220, 38)
    $form.Controls.Add($logs)
    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Select an outcome, then create a sample report.'
    $status.SetBounds(24, 340, 710, 70)
    $form.Controls.Add($status)
    $script:LatestReport = ''
    $generate.Add_Click({
        $generate.Enabled = $false
        try {
            $script:LatestReport = New-SfsuSampleReport -SelectedScenario ([string]$choice.SelectedItem)
            $open.Enabled = $true
            $status.Text = 'Sample saved. Use Open latest report to view it in your browser.' + [Environment]::NewLine + $script:LatestReport
        } catch {
            $status.Text = 'Could not create the sample. ' + $_.Exception.Message
            [void][System.Windows.Forms.MessageBox]::Show($form, $status.Text, 'SFSU USMT', 'OK', 'Error')
        } finally { $generate.Enabled = $true }
    })
    $open.Add_Click({
        try { Start-Process -FilePath $script:LatestReport | Out-Null }
        catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not open report') }
    })
    $logs.Add_Click({
        try {
            $logsPath = Join-Path $packageRoot 'Logs'
            [void][System.IO.Directory]::CreateDirectory($logsPath)
            Start-Process -FilePath explorer.exe -ArgumentList ('"' + $logsPath + '"') | Out-Null
        } catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not open Logs') }
    })
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
} catch {
    # Startup may fail before the reporting module is available. Keep a plain-text fallback.
    $failureText = $_.Exception.ToString()
    try {
        $logsPath = Join-Path $packageRoot 'Logs'
        [void][System.IO.Directory]::CreateDirectory($logsPath)
        $failurePath = Join-Path $logsPath ('startup-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($failurePath, $failureText)
        [Console]::Error.WriteLine('Startup details: ' + $failurePath)
    } catch { [Console]::Error.WriteLine('The Logs folder is not writable. Save the error shown below.') }
    [Console]::Error.WriteLine($failureText)
    exit 1
}
