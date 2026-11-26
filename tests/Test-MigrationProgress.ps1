# Synthetic workflow math and offscreen monitor. No USMT/account/profile/AD work.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/migration-progress-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Progress.psm1') -Force
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function New-Control { [hashtable]::Synchronized(@{CancelRequested=$false;Message='';Percent=-1}) }
function Save-Window($Window,[string]$Name) {
    $bitmap=New-Object Drawing.Bitmap($Window.Width,$Window.Height)
    try { $Window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $root $Name)) } finally { $bitmap.Dispose() }
}
$control=New-Control
Initialize-SfsuWorkflowProgress $control Backup @('Small profile','Large profile') @(10,90)
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 0) 'Preparation does not invent native progress.'
Set-SfsuWorkflowStage $control Transfer 1 'Capturing'
Update-SfsuWorkflowNativeProgress $control Capturing 50
Assert-True ([Math]::Abs($control.ProgressSnapshot.OverallPercent-9.25) -lt .001) 'Ten-percent-size profile at half progress contributes 4.25 points plus preparation.'
$snapshot=$control.ProgressSnapshot
Update-SfsuWorkflowNativeProgress $control Capturing 10
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 9.25 -and $snapshot.Percent -eq 50) 'Regressing native percentages do not rewind overall progress or mutate a published snapshot.'
Update-SfsuWorkflowNativeProgress $control 'Native progress unavailable' -1
Assert-True ($control.ProgressSnapshot.Percent -eq -1 -and $control.ProgressSnapshot.OverallPercent -eq 9.25) 'Missing native percentages remain indeterminate without erasing known overall work.'
Complete-SfsuWorkflowStage $control
Set-SfsuWorkflowStage $control Transfer 2 'Capturing'
Complete-SfsuWorkflowStage $control
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 90) 'Transfer completion reserves verification and finalization work.'
foreach ($i in @(1,2)) { Set-SfsuWorkflowStage $control Verify $i 'Verifying'; Complete-SfsuWorkflowStage $control }
Set-SfsuWorkflowStage $control Finalizing 0 'Finalizing'
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 99) 'Required finalization keeps the overall pie below 100.'
Complete-SfsuWorkflowProgress $control Failed
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 99 -and $control.ProgressSnapshot.Outcome -eq 'Failed') 'Failure retains the actual stopping percentage.'
Complete-SfsuWorkflowProgress $control CompletedWithWarnings
Assert-True ($control.ProgressSnapshot.OverallPercent -eq 100) 'A completed warning result can finish the workflow.'
$restoreControl=New-Control
Initialize-SfsuWorkflowProgress $restoreControl Restore @('One','Two') @(0,0)
Assert-True ($restoreControl.ProgressSnapshot.WeightNote -match 'size is unavailable') 'Unknown sizes use a visibly identified equal-weight fallback.'
foreach ($i in @(1,2)) { Set-SfsuWorkflowStage $restoreControl Verify $i 'Verify'; Complete-SfsuWorkflowStage $restoreControl }
Assert-True ($restoreControl.ProgressSnapshot.OverallPercent -eq 15) 'Restore verifies stores before assigning transfer progress.'
Set-SfsuWorkflowStage $restoreControl Transfer 1 'Restore'; Complete-SfsuWorkflowStage $restoreControl
Assert-True ($restoreControl.ProgressSnapshot.OverallPercent -eq 57) 'Restore transfer uses its explicit workflow allocation.'

$main=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
$window=$null
try {
    $main.ShowInTaskbar=$false; $main.StartPosition='Manual'; $main.Location=New-Object Drawing.Point(-30000,-30000); $main.Show(); [Windows.Forms.Application]::DoEvents()
    $window=New-SfsuMigrationProgressWindow 'Capture profiles'; $script:SfsuUi.ProgressWindow=$window
    Assert-True ($window.WindowState -eq 'Maximized' -and $window.Tag.Heading.Font.SizeInPoints -ge 32 -and $window.Tag.Overall.Font.SizeInPoints -ge 60) 'The dedicated monitor defaults to maximized with room-visible text.'
    $window.WindowState='Normal'; $window.StartPosition='Manual'; $window.Location=New-Object Drawing.Point(-30000,-30000); $window.ShowInTaskbar=$false; $window.Show(); [Windows.Forms.Application]::DoEvents()
    $display=[pscustomobject]@{OverallPercent=62.4;Percent=37;ProfileIndex=2;ProfileCount=5;ProfileName='Synthetic Employee';Stage='Capturing profile files and settings';Message='Capturing Synthetic Employee';WeightNote='Estimated overall; weighted by profile size';Outcome='Running'}
    Update-SfsuMigrationProgressWindow $display
    Assert-True ($window.Tag.Overall.Text -eq '62%' -and $window.Tag.Bar.Value -eq 37 -and $window.Tag.Profile.Text -match 'Profile 2 of 5') 'Overall pie, native profile bar and profile position are independent.'
    Assert-True ($window.Tag.Pie.AccessibleName -match 'BACKUP IN PROGRESS.*62%') 'The graphical pie has an equivalent accessible status.'
    Save-Window $window 'running.png'
    $display.Percent=-1; Update-SfsuMigrationProgressWindow $display
    Assert-True ($window.Tag.Bar.Style -eq 'Marquee' -and $window.Tag.Overall.Text -eq '62%') 'Stages without native percentages show an indeterminate current bar.'
    Update-SfsuMigrationProgressWindow $display Failed
    Assert-True ($window.Tag.Heading.Text -eq 'FAILED' -and $window.Tag.Pie.Outcome -eq 'Failed' -and $window.Tag.Overall.Text -eq '62%' -and $window.Tag.Weight.Text -match 'Stopped at 62%' -and -not $window.Tag.Stop.Enabled -and $window.Tag.Close.Enabled) 'Failure fills the pie red and separately preserves the stopping percentage.'
    $bitmap=New-Object Drawing.Bitmap($window.Tag.Pie.Width,$window.Tag.Pie.Height)
    try {
        $window.Tag.Pie.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)))
        $color=$bitmap.GetPixel([int]($bitmap.Width/2),[int]($bitmap.Height/2+60))
        Assert-True ($color.R -gt 150 -and $color.G -lt 70) 'Failed pie is painted red beyond its former partial fill.'
    } finally { $bitmap.Dispose() }
    Save-Window $window 'failed.png'
    $window.Tag.Running=$true; Update-SfsuMigrationProgressWindow $display CompletedWithWarnings
    Assert-True ($window.Tag.Heading.Text -eq 'COMPLETED WITH WARNINGS' -and $window.Tag.Overall.Text -eq '100%') 'Warning completion is explicit and reaches 100 percent.'
    Save-Window $window 'warnings.png'
    $window.ClientSize=New-Object Drawing.Size(760,580); [Windows.Forms.Application]::DoEvents()
    Save-Window $window 'warnings-small.png'
    Assert-True ($window.Tag.Layout.MinimumSize.Height -ge 636 -and $window.VerticalScroll.Visible) 'Smaller windows preserve required content height and expose a working scrollbar.'
    $window.AutoScrollPosition=New-Object Drawing.Point(0,1000); [Windows.Forms.Application]::DoEvents(); Save-Window $window 'warnings-small-scrolled.png'
    Assert-True ($window.AutoScrollPosition.Y -lt 0) 'The footer can be reached by scrolling a smaller monitor.'
    $window.ClientSize=New-Object Drawing.Size(1200,800)
    $window.Tag.Running=$true; Update-SfsuMigrationProgressWindow $display Completed
    Assert-True ($window.Tag.Heading.Text -eq 'COMPLETED' -and $window.Tag.Bar.Value -eq 100 -and -not $window.Tag.Running) 'Success remains visible until dismissed.'
    $script:SfsuUi.ThemeId='Dark'; Update-SfsuAppearance; Save-Window $window 'completed-dark.png'
    $window.Tag.Running=$true; $script:SfsuUi.Action='Capture profiles'; $script:SfsuUi.Worker=[PowerShell]::Create(); $script:SfsuUi.MigrationControl=New-Control
    $original=${function:Confirm-SfsuMigrationCancellation}
    function Confirm-SfsuMigrationCancellation([string]$Action) { $script:FixtureConfirmation }
    try {
        $script:FixtureConfirmation=$false; $window.Close()
        Assert-True ($window.Visible -and -not $window.Tag.CloseAfter -and -not $script:SfsuUi.MigrationControl.CancelRequested) 'Declining monitor-close cancellation leaves migration and monitor running.'
        $script:FixtureConfirmation=$true; $window.Close()
        Assert-True ($window.Tag.CloseAfter -and $script:SfsuUi.MigrationControl.CancelRequested -and $window.Visible) 'Confirmed monitor close requests protected cancellation and waits for worker completion.'
        Update-SfsuMigrationProgressWindow $display Cancelled
        Assert-True ($window.IsDisposed) 'Confirmed monitor close happens only after the operation ends.'
    } finally { ${function:Confirm-SfsuMigrationCancellation}=$original; $script:SfsuUi.Worker.Dispose(); $script:SfsuUi.Worker=$null }

    # Exercise the actual main-task timer and cross-runspace publication, using
    # isolated empty service modules and a synthetic engine result.
    $fixture=Join-Path $root 'fixture'; $scripts=Join-Path $fixture 'App/Scripts'; [void][IO.Directory]::CreateDirectory($scripts)
    foreach ($name in @('Sfsu.Logging.psm1','Sfsu.Inventory.psm1')) { [IO.File]::WriteAllText((Join-Path $scripts $name),'# Empty isolated service fixture.') }
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Engine.psm1'),@'
function Invoke-SfsuCapture {
    param($PackageRoot,$Reviews,$Control)
    $Control.ProgressSnapshot=[pscustomobject]@{Message='Synthetic capture';Percent=40;OverallPercent=25;ProfileIndex=1;ProfileCount=1;ProfileName='Synthetic Timer';Stage='Capturing';Outcome='Running';WeightNote='Synthetic size weighting'}
    Start-Sleep -Milliseconds 500
    [pscustomobject]@{Outcome='CompletedWithWarnings';ReportPath=(Join-Path $PackageRoot 'report.html');Errors=@()}
}
Export-ModuleMember -Function Invoke-SfsuCapture
'@)
    $originalShow=${function:Show-SfsuMigrationProgressWindow}; $originalRoot=$script:SfsuUi.Root
    function Show-SfsuMigrationProgressWindow([string]$Action) {
        $progressWindow=New-SfsuMigrationProgressWindow $Action
        $progressWindow.WindowState='Normal'; $progressWindow.StartPosition='Manual'; $progressWindow.Location=New-Object Drawing.Point(-30000,-30000); $progressWindow.ShowInTaskbar=$false
        $script:SfsuUi.ProgressWindow=$progressWindow; $progressWindow.Show()
    }
    try {
        $script:SfsuUi.Root=$fixture; $script:SfsuUi.Cancelled=$false
        Start-SfsuUiTask 'Capture profiles' @()
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while ($script:SfsuUi.Worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(20) }
        Assert-True ($null -eq $script:SfsuUi.Worker -and $script:SfsuUi.ProgressWindow.Tag.Terminal -eq 'CompletedWithWarnings' -and $script:SfsuUi.ProgressWindow.Tag.Report.Enabled) 'The actual worker/timer lifecycle retains the correct terminal monitor and enables its report.'
        Assert-True ($script:SfsuUi.ProgressWindow.Tag.Overall.Text -eq '100%' -and $script:SfsuUi.ProgressWindow.Visible) 'The completion monitor stays open after worker cleanup.'
        $boundReport=$script:SfsuUi.ProgressWindow.Tag.ReportPath; $script:SfsuUi.LatestReport='unrelated-report.html'
        Assert-True ($script:SfsuUi.ProgressWindow.Tag.ReportPath -eq $boundReport) 'A completed monitor keeps its own report when other main-window tasks change the latest report.'
        $script:SfsuUi.ProgressWindow.Dispose()
        [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Engine.psm1'),"function Invoke-SfsuCapture { throw 'Synthetic worker failure.' }; Export-ModuleMember -Function Invoke-SfsuCapture")
        Start-SfsuUiTask 'Capture profiles' @()
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while ($script:SfsuUi.Worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(20) }
        Assert-True ($null -eq $script:SfsuUi.Worker -and $script:SfsuUi.ProgressWindow.Tag.Terminal -eq 'Failed' -and -not $script:SfsuUi.ProgressWindow.Tag.Report.Enabled) 'An unexpected worker failure produces the failed monitor without linking an unrelated old report.'
        $script:SfsuUi.ProgressWindow.Dispose()
        [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Engine.psm1'),"function Invoke-SfsuCapture { param(`$PackageRoot); [pscustomobject]@{Outcome='Completed';ReportPath=(Join-Path `$PackageRoot 'report.html');Errors=@()} }; Export-ModuleMember -Function Invoke-SfsuCapture")
        $originalUpdate=${function:Update-SfsuMigrationProgressWindow}
        function Update-SfsuMigrationProgressWindow { throw 'Synthetic monitor-render failure.' }
        try {
            Start-SfsuUiTask 'Capture profiles' @()
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while ($script:SfsuUi.Worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(20) }
            Assert-True ($null -eq $script:SfsuUi.Worker -and $script:SfsuUi.Status.Text -match 'result: Completed.*could not update') 'An optional monitor failure cannot prevent worker cleanup or change the authoritative result.'
        } finally { ${function:Update-SfsuMigrationProgressWindow}=$originalUpdate; $script:SfsuUi.ProgressWindow.Tag.Running=$false; $script:SfsuUi.ProgressWindow.Dispose() }
    } finally { ${function:Show-SfsuMigrationProgressWindow}=$originalShow; $script:SfsuUi.Root=$originalRoot }
} finally {
    if ($window -and -not $window.IsDisposed) { $window.Tag.Running=$false; $window.Dispose() }
    $main.Dispose()
}
Write-Output ("PASS: $script:Assertions migration-progress assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
