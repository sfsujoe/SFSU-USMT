# Actual open log writers and harmless supervised PowerShell processes. No
# vendor executable, real profile, directory service or Windows account is used.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/live-native-report-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'App/Reporting'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'Tools'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $root 'App/Reporting/report.template.html')
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Engine.psm1') -Force -PassThru
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Logging.psm1')
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) { $failure=''; try { & $Action | Out-Null } catch { $failure=$_.Exception.Message }; Assert-True ($failure -match $Pattern) ($Message+'; actual: '+$failure) }

$run=New-SfsuLogRun -PackageRoot $root -Operation Backup -Steps @(@{Id='capture';Title='Synthetic active writer'})
Start-SfsuLogStep $run capture
$live=Get-SfsuRawLogPath $run 'live-writer.log'
$writer=[IO.FileStream]::new($live,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try {
    $bytes=[Text.Encoding]::UTF8.GetBytes('synthetic writer'); $writer.Write($bytes,0,$bytes.Length); $writer.Flush()
    Assert-Throws { $file=[Sfsu.SafeFiles]::Open($live,$false,$false); $file.Dispose() } 'being used by another process' 'The old protected read reproduces the VM active-writer conflict.'
    Update-SfsuLogReport -RunDirectory $run.RunDirectory | Out-Null
    Assert-True ([IO.File]::ReadAllText($run.ReportPath).Contains('href="Raw/live-writer.log"')) 'Report refresh safely links an actively written log.'
    $writer.WriteByte(10); $writer.Flush()
    Assert-True ($writer.Length -eq $bytes.Length+1) 'Refreshing the report leaves the native writer usable.'
} finally { $writer.Dispose() }
$exclusive=Get-SfsuRawLogPath $run 'exclusive-writer.log'
$writer=[IO.FileStream]::new($exclusive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    Update-SfsuLogReport -RunDirectory $run.RunDirectory | Out-Null
    Assert-True ([IO.File]::ReadAllText($run.ReportPath).Contains('href="Raw/exclusive-writer.log"')) 'Metadata-only inspection does not need read sharing from an exclusive writer.'
} finally { $writer.Dispose() }
$sentinel=Join-Path $root 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'must remain unchanged')
$hardLink=Join-Path $run.RawDirectory 'unsafe-hardlink.log'
[void](New-Item -ItemType HardLink -Path $hardLink -Target $sentinel)
Update-SfsuLogReport -RunDirectory $run.RunDirectory | Out-Null
$html=[IO.File]::ReadAllText($run.ReportPath)
Assert-True (-not $html.Contains('href="Raw/unsafe-hardlink.log"') -and $html.Contains('Some raw-log links could not be safely inspected')) 'Unsafe raw links are omitted with a visible report warning.'
Assert-Throws { [Sfsu.SafeFiles]::InspectLiveFile($hardLink) } 'one link' 'Metadata inspection still refuses multiple hard links.'
Assert-Throws { $file=[Sfsu.SafeFiles]::OpenSharedRead($hardLink); $file.Dispose() } 'one link' 'The live content reader also refuses multiple hard links.'
Assert-Throws { $file=[Sfsu.SafeFiles]::Open($hardLink,$true,$false); $file.Dispose() } 'one link' 'Protected write guards were not weakened for live reporting.'
Assert-True ([IO.File]::ReadAllText($sentinel) -ceq 'must remain unchanged') 'Raw-link inspection never modifies its target.'
Complete-SfsuLogStep $run capture Passed 'Fixture checks finished.'
Complete-SfsuLogRun $run Completed 'Synthetic fixture only.' | Out-Null

# A fake executable file is only used for the existing protected-file lease.
# Replace the private process factory so real supervision runs a harmless writer.
$tools=Join-Path $root 'Tools'; [IO.File]::WriteAllText((Join-Path $tools 'scanstate.exe'),'NOT AN EXECUTABLE - fixture lease only')
$helper=Join-Path $root 'writer.ps1'
[IO.File]::WriteAllText($helper,@'
param([string]$Log,[string]$Progress,[string]$Report,[string]$Marker,[string]$Mode,[int]$Code)
$ErrorActionPreference='Stop'
$logWriter=$null; $progressWriter=$null; $reportReader=$null
try {
 $logWriter=[IO.FileStream]::new($Log,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
 $sharing=[IO.FileShare]::ReadWrite; if ($Mode -eq 'exclusive') { $sharing=[IO.FileShare]::None }
 $progressWriter=[IO.FileStream]::new($Progress,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,$sharing)
 if ($Mode -eq 'report-blocked') { $reportReader=[IO.FileStream]::new($Report,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read) }
 $preamble=[Text.Encoding]::Unicode.GetPreamble(); $progressWriter.Write($preamble,0,$preamble.Length)
 for ($index=1; $index -le 8; $index++) {
  $line='08 Nov 2026, 14:27:00 -08:00, 00:00:01, totalPercentageCompleted, '+($index*10)+"`r`n"
  $bytes=[Text.Encoding]::Unicode.GetBytes($line); $progressWriter.Write($bytes,0,$bytes.Length); $progressWriter.Flush()
  $logWriter.WriteByte(65); $logWriter.Flush(); Start-Sleep -Milliseconds 500
 }
 [IO.File]::WriteAllText($Marker,'finished naturally')
} finally { if ($reportReader) { $reportReader.Dispose() }; if ($progressWriter) { $progressWriter.Dispose() }; if ($logWriter) { $logWriter.Dispose() } }
exit $Code
'@)
& $module {
    param($helper)
    $script:FixtureHelper=$helper; $script:FixtureCase=$null; $script:FixturePid=0
    $script:PersistentReportReader=$null
    $script:OriginalTail=${function:Read-SfsuNativeTail}
    function script:Read-SfsuNativeTail([string]$Path) {
        $value=& $script:OriginalTail $Path
        if ($script:FixtureCase.Mode -eq 'cancel' -and $value) { $script:FixtureCase.Control.CancelRequested=$true }
        $value
    }
    function script:Start-SfsuNativeProcess([string]$Path,[string]$Arguments,[string]$Directory) {
        $case=$script:FixtureCase
        $fixtureArguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script:FixtureHelper,'-Log',$case.Log,'-Progress',$case.Progress,'-Report',$case.Report,'-Marker',$case.Marker,'-Mode',$case.Mode,'-Code',[string]$case.Code)
        $text=($fixtureArguments | ForEach-Object { ConvertTo-SfsuNativeArgument $_ }) -join ' '
        $process=[Sfsu.Engine.NativeRun]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'),$text,$Directory)
        if ($case.Mode -eq 'persistent-report') { $script:PersistentReportReader=[IO.FileStream]::new($case.Report,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read) }
        $script:FixturePid=$process.Pid
        $process
    }
} $helper
foreach ($mode in @('normal','exclusive','report-blocked','persistent-report','fatal','cancel')) {
    $run=New-SfsuLogRun -PackageRoot $root -Operation Backup -Steps @(@{Id='capture';Title=('Supervised '+$mode+' writer')})
    Start-SfsuLogStep $run capture
    $control=[hashtable]::Synchronized(@{CancelRequested=$false;Message='';Percent=-1})
    $case=[pscustomobject]@{Mode=$mode;Log=(Join-Path $run.RawDirectory 'native.log');Progress=(Join-Path $run.RawDirectory 'progress.log');Report=$run.ReportPath;Marker=(Join-Path $run.RunDirectory 'natural-finish.txt');Code=0;Control=$control}
    if ($mode -eq 'fatal') { $case.Code=27 }
    & $module { param($case) $script:FixtureCase=$case } $case
    $failure=''; $result=$null
    try {
        $result=& $module {
            param($directory,$run,$case)
            Invoke-SfsuNativeTool -Tools ([pscustomobject]@{Directory=$directory}) -Name scanstate.exe -Arguments @('fixture-only') -Run $run -StepId capture -Label 'Harmless supervised writer' -Log $case.Log -Progress $case.Progress -Control $case.Control
        } $tools $run $case
    } catch { $failure=$_.Exception.Message }
    finally { & $module { if ($script:PersistentReportReader) { $script:PersistentReportReader.Dispose(); $script:PersistentReportReader=$null } } }
    $pidValue=& $module { $script:FixturePid }
    Assert-True ($null -eq (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) 'The supervised fixture process is closed after every result.'
    if ($mode -eq 'cancel') {
        Assert-True ($failure -match 'technician cancelled' -and -not (Test-Path -LiteralPath $case.Marker)) 'Cancellation still terminates native work rather than being swallowed as an observation error.'
        Complete-SfsuLogRun $run Cancelled 'Synthetic cancellation.' | Out-Null
    } elseif ($mode -eq 'persistent-report') {
        Assert-True ($failure -match 'Could not update the HTML report' -and (Test-Path -LiteralPath $case.Marker)) 'Persistent required reporting failure stops later stages only after native work finishes naturally.'
        Assert-True ([IO.File]::ReadAllText($run.EventsPath).Contains('Harmless supervised writer exited with code 0.')) 'The real native exit is durable even when its HTML refresh remains denied.'
        Complete-SfsuLogRun $run Failed 'Required result recording failed after the synthetic native writer ended.' | Out-Null
    } elseif ($mode -eq 'fatal') {
        Assert-True ($failure -match 'exit code 27' -and (Test-Path -LiteralPath $case.Marker)) 'A real nonzero native exit still fails after the child finishes.'
        Complete-SfsuLogRun $run Failed 'Synthetic native failure.' | Out-Null
    } else {
        Assert-True (-not $failure -and $result.ExitCode -eq 0 -and (Test-Path -LiteralPath $case.Marker)) ('Live observation/rendering does not terminate a successful native writer. '+$mode+': '+$failure)
        if ($mode -eq 'normal') { Assert-True (-not $result.HasWarnings) 'Compatible log writers do not introduce spurious observation warnings.' }
        else {
            Assert-True ($result.HasWarnings) 'An unavailable progress read or HTML refresh propagates a truthful warning.'
            Assert-True ([IO.File]::ReadAllText($run.EventsPath).Contains('Progress/report observation failed while the native process continued')) 'Observation failure is durably recorded once result recording is available.'
        }
        Complete-SfsuLogStep $run capture Passed 'Synthetic writer finished.'
        Complete-SfsuLogRun $run Completed 'Synthetic writer only.' | Out-Null
        $html=[IO.File]::ReadAllText($run.ReportPath)
        Assert-True ($html.Contains('href="Raw/native.log"') -and $html.Contains('href="Raw/progress.log"')) 'Final reports retain original native/progress links after writers close.'
        if ($mode -ne 'normal') { Assert-True ($html.Contains('Completed with warnings')) 'Reporting limitations cannot produce a clean-success result.' }
    }
}
Write-Output ("PASS: $script:Assertions live-native-reporting assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
