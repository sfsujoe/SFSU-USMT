# Windows PowerShell 5.1. Synthetic reports and fault-injected filesystem calls only.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $PSScriptRoot ('.work/report-writes-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAILED: ' + $Message) }
    $script:Assertions++
}

# Inject only the two filesystem calls in an isolated module copy. All rendering,
# exception handling, retries, cleanup, and journal writes use the shipped code.
# No ACL, share, credential, or production file is changed by this test.
Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class SfsuReportIoFixture {
    public static string ReplacementFailure = "Denied";
    public static int ReplaceCalls;
    public static int CopyCalls;
    public static int CopyFailuresRemaining;
    public static bool BlockCopy;
    public static void Replace(string source, string destination, string backup) {
        ReplaceCalls++;
        if (ReplacementFailure == "Unsupported") throw new NotSupportedException("Synthetic unsupported replacement.");
        if (ReplacementFailure == "IO") throw new IOException("Synthetic replacement IO failure.");
        throw new UnauthorizedAccessException("Synthetic replacement access denied.");
    }
    public static void Copy(string source, string destination, bool overwrite) {
        CopyCalls++;
        if (BlockCopy) throw new UnauthorizedAccessException("Synthetic overwrite access denied.");
        if (CopyFailuresRemaining > 0) {
            CopyFailuresRemaining--;
            throw new IOException("Synthetic temporary report lock.");
        }
        File.Copy(source, destination, overwrite);
    }
}
'@
$source = [IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Sfsu.Logging.psm1'))
foreach ($method in @('Replace','Copy')) {
    $call = '[System.IO.File]::' + $method + '('
    if ([regex]::Matches($source, [regex]::Escape($call)).Count -ne 1) { throw ('Review filesystem injection point: ' + $method) }
    $source = $source.Replace($call, ('[SfsuReportIoFixture]::' + $method + '('))
}
$modulePath = Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1'
[IO.File]::WriteAllText($modulePath, $source)
$module = Import-Module $modulePath -Force -PassThru
$reportPath = Join-Path $testRoot 'report.html'
function Write-TestReport([string]$Text) {
    & $module { param($path,$text) Write-SfsuAtomicText $path $text } $reportPath $Text
}
function Get-TemporaryReports { @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.tmp') }

Write-TestReport 'Initial report'
Assert-True ([IO.File]::ReadAllText($reportPath) -eq 'Initial report') 'New reports are created normally.'
Assert-True ([SfsuReportIoFixture]::ReplaceCalls -eq 0) 'Creating a report does not require replacement.'
foreach ($failure in @('Denied','IO','Unsupported')) {
    [SfsuReportIoFixture]::ReplacementFailure = $failure
    Write-TestReport ('Updated after ' + $failure)
    Assert-True ([IO.File]::ReadAllText($reportPath) -eq ('Updated after ' + $failure)) ('Overwrite recovers from replacement failure: ' + $failure)
}
Assert-True (@(Get-TemporaryReports).Count -eq 0) 'Successful fallback leaves no temporary reports.'
[SfsuReportIoFixture]::CopyCalls = 0
[SfsuReportIoFixture]::CopyFailuresRemaining = 2
Write-TestReport 'Recovered from a temporary lock'
Assert-True ([SfsuReportIoFixture]::CopyCalls -eq 3) 'Temporary overwrite locks are retried with a bounded attempt count.'
Assert-True ([IO.File]::ReadAllText($reportPath) -eq 'Recovered from a temporary lock') 'The final retry publishes the new report.'

# A complete run must proceed beyond the first step when replacement is denied.
[SfsuReportIoFixture]::ReplacementFailure = 'Denied'
$run = New-SfsuLogRun -PackageRoot $testRoot -Operation ReportPreview -Sample -Steps @(@{Id='check';Title='Synthetic check'})
Start-SfsuLogStep -Run $run -StepId check
Complete-SfsuLogStep -Run $run -StepId check -Status Passed -Message 'Synthetic work completed.'
Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Synthetic final result.' | Out-Null
Assert-True ([IO.File]::ReadAllText($run.ReportPath).Contains('id="outcome">Completed</h2>')) 'A denied replacement no longer stops the run or leaves stale HTML.'
Assert-True ((ConvertFrom-Json ([IO.File]::ReadAllLines($run.EventsPath)[-1])).Type -eq 'RunFinished') 'The durable journal records the final result.'

# Genuine overwrite denial must remain an error, retaining both existing HTML
# and the newly appended event so the report can be rebuilt after access returns.
$blocked = New-SfsuLogRun -PackageRoot $testRoot -Operation ReportPreview -Sample -Steps @(@{Id='check';Title='Synthetic check'})
$previousHtml = [IO.File]::ReadAllText($blocked.ReportPath)
[SfsuReportIoFixture]::BlockCopy = $true
[SfsuReportIoFixture]::CopyCalls = 0
$failureText = ''
try { Write-SfsuLogEvent -Run $blocked -Message 'Evidence retained through a report failure.' }
catch { $failureText = $_.Exception.Message }
Assert-True ($failureText.Contains('Could not update the HTML report') -and $failureText.Contains('events.jsonl') -and $failureText.Contains('Synthetic overwrite access denied')) 'Persistent write denial explains the failed report, preserved journal, and original error.'
Assert-True ([SfsuReportIoFixture]::CopyCalls -eq 3) 'Persistent overwrite denial stops after three attempts.'
Assert-True ([IO.File]::ReadAllText($blocked.ReportPath) -eq $previousHtml) 'Denied writes preserve the existing report.'
Assert-True ([IO.File]::ReadAllText($blocked.EventsPath).Contains('Evidence retained through a report failure.')) 'A failed HTML refresh does not discard the new journal event.'
Assert-True (@(Get-TemporaryReports).Count -eq 0) 'Failed fallback cleans up its own temporary reports.'
[SfsuReportIoFixture]::BlockCopy = $false
Update-SfsuLogReport -RunDirectory $blocked.RunDirectory | Out-Null
$recoveredHtml = [IO.File]::ReadAllText($blocked.ReportPath)
Assert-True ($recoveredHtml.Contains('Evidence retained through a report failure.') -and $recoveredHtml.Contains('id="outcome">Incomplete</h2>')) 'Recovery rebuilds retained evidence without inventing a completed result.'
Write-Output ("PASS: $script:Assertions assertions on PowerShell " + $PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: ' + $testRoot)
