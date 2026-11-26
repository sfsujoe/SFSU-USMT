# Focused review regressions: synthetic paths/logs only. No vendor process,
# real employee profile, directory query, policy change or account operation.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/review-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Engine.psm1') -Force -PassThru
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Policy.psm1') -Force
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert-True $failed $Message }

$profile=[pscustomobject]@{ProfileSid='S-1-5-21-1-2-3-1001';ProfilePath='C:\Users\OldFolder';AccountName='CurrentAccount';PathVariables=@{OneDrive='%USERPROFILE%\Campus Cloud';TEMP='%LOCALAPPDATA%\Temp'}}
$oldCloud=$env:OneDrive; $oldTemp=$env:TEMP
try {
    $env:OneDrive='C:\Users\Technician\Cloud'; $env:TEMP='C:\TechnicianTemp'
    Assert-True ((Expand-SfsuProfileLocation '%OneDrive%\Documents' $profile) -eq 'C:\Users\OldFolder\Campus Cloud\Documents') 'Nested employee variables resolve without technician OneDrive contamination.'
    Assert-True ((Expand-SfsuProfileLocation '%TEMP%\cache' $profile) -eq 'C:\Users\OldFolder\AppData\Local\Temp\cache') 'Employee TEMP resolves from source evidence.'
    Assert-True ((Expand-SfsuProfileLocation 'D:\Browsers\%USERNAME%' $profile) -eq 'D:\Browsers\CurrentAccount') 'USERNAME follows account evidence rather than an old profile-folder name.'
    $profile.PathVariables=@{}
    Assert-Throws { Expand-SfsuProfileLocation '%OneDrive%\Documents' $profile } 'Missing source variables cannot silently use the technician environment.'
    Assert-Throws { Expand-SfsuProfileLocation '%TEMP%\cache' $profile } 'Missing source TEMP remains unresolved even when technician TEMP exists.'
    $profile.AccountName=''
    Assert-Throws { Expand-SfsuProfileLocation 'D:\Browsers\%USERNAME%' $profile } 'Offline identities do not invent USERNAME from folder spelling.'
    $profile.PathVariables=@{OneDrive='%OneDriveCommercial%';OneDriveCommercial='%OneDrive%'}
    Assert-Throws { Expand-SfsuProfileLocation '%OneDrive%\Documents' $profile } 'Cyclic source variables fail safely.'
    Assert-True ((Expand-SfsuProfileLocation '%SystemRoot%\Temp' $profile) -eq (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp')) 'Allowlisted machine paths remain automatic.'
} finally { $env:OneDrive=$oldCloud; $env:TEMP=$oldTemp }

$log=Join-Path $root 'native.log'; $progress=Join-Path $root 'progress.log'
[IO.File]::WriteAllText($log,"2026-11-24 10:00:00, Info [0x000000] Error count: 0; warning processing enabled.`r`n2026-11-24 10:00:01, Warning [0x000000] Duplicate manifest ignored.`r`n")
[IO.File]::WriteAllText($progress,"24 Nov 2026,10:00:00,00:00:01,totalPercentageCompleted,100,numberOfIgnoredErrors,0`r`n",[Text.Encoding]::Unicode)
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True (-not $result.HasWarnings -and $result.ErrorLines -eq 0 -and $result.InformationalWarnings -eq 1) 'Harmless mentions and nonoperational warning entries do not create a WARNING outcome.'
[IO.File]::AppendAllText($log,'2026-11-24 10:00:02, Warning [0x000005] Unable to open source file.')
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True ($result.HasWarnings -and $result.WarningLines -eq 1) 'Operational main-log warnings remain visible even with exit zero.'
[IO.File]::WriteAllText($log,'2026-11-24 10:00:00, Info [0x000000] Finished.')
[IO.File]::WriteAllText($progress,'24 Nov 2026,10:00:00,00:00:01,error,UnableToOpen,objectName,"C:\Data\a,b.txt",action,Ignore,numberOfIgnoredErrors,2')
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True ($result.HasWarnings -and $result.HasOutcomeWarnings -and $result.IgnoredErrors -eq 2 -and $result.NonFatalRecords -eq 1) 'Structured ignored-file counts remain outcome warnings independently of exit code.'
[IO.File]::WriteAllText($progress,'24 Nov 2026,10:00:00,00:00:01,objectName,"C:\Data\name,error,UnableToCopy.txt",numberOfIgnoredErrors,0')
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True (-not $result.HasWarnings) 'Error-like words inside a quoted filename cannot fabricate an operational error field.'
[IO.File]::WriteAllText($log,'2026-11-25 10:00:00, Error [0x0808ff] Printer plug-in failed to load.')
[IO.File]::WriteAllText($progress,'25 Nov 2026,10:00:00,00:00:01,error,UnableToOpen,action,Abort,errorText,"Will retry using Volume Shadow Copy."'+"`r`n"+'25 Nov 2026,10:00:01,00:00:02,errorCode,0,numberOfIgnoredErrors,0,message,"Successful run"')
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True ($result.HasWarnings -and -not $result.HasOutcomeWarnings -and $result.ErrorLines -eq 1 -and $result.NonFatalRecords -eq 1) 'Native success retains printer/VSS diagnostics without downgrading the outcome.'
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 3 } $log $progress
Assert-True ($result.HasOutcomeWarnings) 'Native exit 3 still changes the outcome.'
[IO.File]::WriteAllText($progress,'numberOfIgnoredErrors,invalid')
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log $progress
Assert-True ($result.HasWarnings -and $result.HasOutcomeWarnings -and $result.UnavailableDiagnostics.Count -eq 1) 'Unparseable required error evidence is unknown rather than a clean zero.'
$result=& $module { param($l,$p) Get-SfsuNativeDiagnostics $l $p 0 } $log (Join-Path $root 'absent.log')
Assert-True ($result.HasWarnings -and $result.UnavailableDiagnostics.Count -eq 1) 'Missing required progress diagnostics cannot silently pass.'
$result=& $module { param($l) Get-SfsuNativeDiagnostics $l '' 3 } $log
Assert-True $result.HasWarnings 'Exit code 3 always retains skipped-error status.'

$list=Join-Path $root 'p1-files.txt'
[IO.File]::WriteAllText($list,'C:\Users\OldFolderNeighbor\Documents\file.txt')
Assert-Throws { & $module { param($p,$s) Get-SfsuCaptureInclusion $p $s } $list $profile } 'A neighboring profile cannot satisfy positive inclusion.'
[IO.File]::WriteAllText($list,'C:\Users\OldFolder\..\Neighbor\file.txt')
Assert-Throws { & $module { param($p,$s) Get-SfsuCaptureInclusion $p $s } $list $profile } 'Path traversal spelling cannot satisfy selected-profile inclusion.'
[IO.File]::WriteAllText($list,"c:\users\oldfolder\Documents\file.txt`r`nC:\Shared\other.txt",[Text.Encoding]::Unicode)
$included=& $module { param($p,$s) Get-SfsuCaptureInclusion $p $s } $list $profile
Assert-True ($included.Confirmed -and $included.ProfileFileCount -eq 1 -and $included.SourceSid -eq $profile.ProfileSid) 'UTF-16 native lists confirm exact selected-profile paths while excluding shared paths.'
Assert-Throws { & $module { param($p,$s) Get-SfsuCaptureInclusion $p $s } (Join-Path $root 'absent.txt') $profile } 'A missing file list cannot be accepted as an included employee.'

# Exercise the actual startup restriction function without launching the app or
# changing this machine's execution policy/language mode.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1'),[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SfsuStartupRestriction'},$true)
. ([scriptblock]::Create($function.Extent.Text))
Assert-True (-not (Get-SfsuStartupRestriction FullLanguage Bypass)) 'Normal supported startup remains allowed.'
Assert-True ((Get-SfsuStartupRestriction ConstrainedLanguage Bypass) -match 'FullLanguage') 'Restricted language gets an actionable application-control explanation.'
Assert-True ((Get-SfsuStartupRestriction FullLanguage AllSigned) -match 'Group Policy') 'An unsigned-script policy restriction is explained before native imports.'
Assert-True (-not (Get-SfsuStartupRestriction FullLanguage RemoteSigned)) 'RemoteSigned is not blanket-rejected when the package is allowed to load.'
$entry=Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1'
$command='$ExecutionContext.SessionState.LanguageMode=''ConstrainedLanguage''; & '''+$entry.Replace("'","''")+''' -Headless'
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
$process=[Diagnostics.Process]::Start($start)
try {
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Constrained-language startup fixture timed out.' }
    $failure=$process.StandardError.ReadToEnd()
    Assert-True ($process.ExitCode -eq 1 -and $failure -match 'requires FullLanguage' -and $failure -notmatch 'MethodInvocationNotSupported') 'An actual constrained child session gets the clear startup restriction before any unsupported .NET call or app work.'
} finally { $process.Dispose() }
Write-Output ("PASS: $script:Assertions review-regression assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
