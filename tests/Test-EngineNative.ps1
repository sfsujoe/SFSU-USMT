# Real harmless child-process supervision and XML validation. No vendor EXE,
# source profile, AD query, Windows account provisioning or migration is executed.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/native-engine-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Engine.psm1') -Force -PassThru
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
$probe=Join-Path $root 'process.ps1'
[IO.File]::WriteAllText($probe,@'
param([switch]$Child,[string]$Value)
if ($Child) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'child.pid'),[string]$PID); Start-Sleep -Seconds 120; exit }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'parent.pid'),[string]$PID)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'value.txt'),$Value)
$arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Child'
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Seconds 120
'@)
$value='literal & (path) "quoted" $() ''apostrophe'' tail\'
$arguments=& $module { param($path,$value) '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(ConvertTo-SfsuNativeArgument $path)+' -Value '+(ConvertTo-SfsuNativeArgument $value) } $probe $value
$executable=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$numericVersion=& $module { param($path) Get-SfsuExecutableVersion $path } $executable
Assert-True ($numericVersion -match '^\d+\.\d+\.\d+\.\d+$') 'Numeric executable version metadata excludes optional WinBuild display suffixes.'
$run=[Sfsu.Engine.NativeRun]::new($executable,$arguments,$root)
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath (Join-Path $root 'child.pid')) -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(100) }
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'child.pid')) 'A supervised harmless process can create a child inside its job.'
    $parentPid=[int][IO.File]::ReadAllText((Join-Path $root 'parent.pid'))
    $childPid=[int][IO.File]::ReadAllText((Join-Path $root 'child.pid'))
    Assert-True (-not $run.Poll(10) -and $run.Pid -eq $parentPid) 'The native adapter polls a running process without blocking the GUI worker.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'value.txt')) -ceq $value) 'Real CreateProcess argv round-trip preserves literal punctuation, quotes and backslashes.'
} finally { $run.Dispose() }
Assert-True ($null -eq (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) -and $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Disposing the job terminates the parent and its child together.'
$quick=Join-Path $root 'exit.ps1'; [IO.File]::WriteAllText($quick,'exit 37')
$arguments=& $module { param($path) '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(ConvertTo-SfsuNativeArgument $path) } $quick
$run=[Sfsu.Engine.NativeRun]::new($executable,$arguments,$root)
try { $deadline=[DateTime]::UtcNow.AddSeconds(15); while (-not $run.Poll(100) -and [DateTime]::UtcNow -lt $deadline) { }; Assert-True ($run.ExitCode -eq 37) 'The supervised process preserves a real nonzero exit code.' } finally { $run.Dispose() }
Assert-True ([Sfsu.Engine.Locations]::FreeBytes($root) -gt 0) 'Native free-space measurement works on the fixture volume.'
Assert-True ([Sfsu.Engine.Locations]::FinalDirectory($root).TrimEnd('\') -ieq $root.TrimEnd('\')) 'Final-directory resolution preserves the literal local fixture path.'
$progress=Join-Path $root 'progress.log'; $log=Join-Path $root 'native.log'
[IO.File]::WriteAllText($progress,"date,time,duration,totalPercentageCompleted,42`r`nnonFatalError,5`r`n",[Text.Encoding]::Unicode)
[IO.File]::WriteAllText($log,'Error MIG synthetic failure detail')
$diagnostics=& $module { param($log,$progress) Get-SfsuNativeDiagnostics $log $progress 0 } $log $progress
Assert-True ($diagnostics.HasWarnings -and $diagnostics.ErrorLines -eq 1 -and $diagnostics.NonFatalRecords -eq 1) 'Native diagnostics retain error/nonfatal evidence even when the executable returns zero.'
$tail=& $module { param($path) Read-SfsuNativeTail $path } $progress
Assert-True ($tail.Contains('totalPercentageCompleted,42')) 'Progress polling decodes UTF-16 native logs.'
$estimate=Join-Path $root 'estimate.xml'; [IO.File]::WriteAllText($estimate,'<PreMigration><storeSize><size clusterSize="512">1024</size><size clusterSize="4096">8192</size></storeSize></PreMigration>')
Assert-True ((& $module { param($path) Read-SfsuStoreEstimate $path } $estimate) -eq 8192) 'Space preflight takes the conservative maximum native store-size estimate.'
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Policy.psm1')
$profile=[pscustomobject]@{ProfilePath=(Join-Path $root 'Source');ProfileSid='S-1-5-21-1-2-3-1001'}
$review=[pscustomobject]@{Profile=$profile;CloudRoots=@([pscustomobject]@{Path='D:\Cloud & Files';Source='fixture'});AdditionalCloudRoots=@();BrowserRoots=@();AdditionalBrowserRoots=@();Reviewed=$true}
$policyPath=Join-Path $root 'policy.xml'
New-SfsuMigrationPolicy -Path $policyPath -Review $review -PackageRoot $repository | Out-Null
$xsd=Join-Path $repository 'App/User State Migration Tool/amd64/MigXML.xsd'
if (Test-Path -LiteralPath $xsd) {
    $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing='Prohibit'; $settings.XmlResolver=$null; $settings.ValidationType='Schema'
    [void]$settings.Schemas.Add('',$xsd)
    $reader=[Xml.XmlReader]::Create($policyPath,$settings)
    try { while ($reader.Read()) { } } finally { $reader.Dispose() }
    Assert-True $true 'Generated campus migration XML passes the supplied Microsoft MigXML schema.'
} else { Write-Output 'SKIP: vendor MigXML.xsd is absent; XML schema check requires the separately supplied payload.' }
Write-Output ("PASS: $script:Assertions native-engine assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
