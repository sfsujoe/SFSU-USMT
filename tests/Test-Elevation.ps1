# Offline startup/elevation fixtures. Never requests UAC or runs the live app/USMT.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/elevation & (test)-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Launch.psm1') -Force -PassThru
$entryPath=Join-Path $testRoot 'probe.ps1'
Assert-True ((Resolve-SfsuLaunchPath $entryPath) -eq $entryPath) 'Local paths remain local without network discovery.'
$unc='\\synthetic.invalid\toolkit\space & (folder)\App\Scripts\Start-SfsuUsmt.ps1'
Assert-True ((Resolve-SfsuLaunchPath $unc) -eq $unc) 'UNC paths remain unchanged without connecting to the server.'
Assert-True ((Test-SfsuAdministrator) -is [bool]) 'The real Windows token check returns a Boolean.'

# Exercise argv round-trip with a real harmless child and the actual quoting code.
# This does not request elevation or execute the entered argument as PowerShell.
[IO.File]::WriteAllText($entryPath,@'
param([string]$Value)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'argv.json'),(ConvertTo-Json @{Value=$Value;Admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}))
'@)
$value='literal "quotes" & (text) ''apostrophe'' $() ` backslash\'
$arguments=& $module { param($path,$value) '-NoLogo -NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-SfsuLaunchArgument $path)+' -Value '+(ConvertTo-SfsuLaunchArgument $value) } $entryPath $value
$child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
try { Assert-True ($child.ExitCode -eq 0) 'Quoted launch arguments execute successfully through a path with shell punctuation.' } finally { $child.Dispose() }
$probe=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $testRoot 'argv.json')))
Assert-True ($probe.Value -ceq $value) 'Quotes, shell punctuation and trailing backslashes survive argv literally.'
Assert-True ($probe.Admin -eq (Test-SfsuAdministrator)) 'An ordinary child retains the parent administrator-token state without credentials.'

# Intercept only process creation and mapped-path lookup in the real launch module.
& $module {
    $script:LaunchProbe=$null; $script:Disposed=$false; $script:LaunchFailure=$null
    function script:Resolve-SfsuLaunchPath([string]$EntryPath) { '\\synthetic.invalid\toolkit share\App\Scripts\Start-SfsuUsmt.ps1' }
    function script:Start-Process {
        param($FilePath,$ArgumentList,$Verb,$WindowStyle,$WorkingDirectory,[switch]$Wait,[switch]$PassThru,$ErrorAction)
        $script:LaunchProbe=@{FilePath=$FilePath;Arguments=$ArgumentList;Verb=$Verb;WindowStyle=$WindowStyle;WorkingDirectory=$WorkingDirectory;Wait=[bool]$Wait;PassThru=[bool]$PassThru}
        if ($null -ne $script:LaunchFailure) { throw $script:LaunchFailure }
        $process=[pscustomobject]@{ExitCode=0}
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:Disposed=$true }
        return $process
    }
}
$result=Start-SfsuElevatedGui -EntryPath $entryPath -LdapServer 'dc.example.invalid' -Scenario Warnings
$launch=& $module { $script:LaunchProbe }
Assert-True ($result -eq 0 -and (& $module { $script:Disposed })) 'The elevated-child exit status is returned and its process handle disposed.'
Assert-True ($launch.Verb -eq 'RunAs' -and $launch.Wait -and $launch.PassThru -and $launch.WindowStyle -eq 'Hidden') 'The Windows elevation broker starts a hidden host and preserves synchronous completion.'
Assert-True ($launch.FilePath -eq (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -and $launch.WorkingDirectory -eq $env:SystemRoot) 'The explicit system host uses a local working directory independent of the mapped share.'
Assert-True ($launch.Arguments.Contains('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "\\synthetic.invalid\toolkit share\App\Scripts\Start-SfsuUsmt.ps1"') -and $launch.Arguments.Contains('-LdapServer "dc.example.invalid" -Scenario "Warnings"')) 'UNC entry point and supported GUI options are preserved with process-only Bypass.'
& $module { $script:LaunchFailure=New-Object ComponentModel.Win32Exception(1223) }
$failure=''; try { Start-SfsuElevatedGui -EntryPath $entryPath -LdapServer x -Scenario Completed } catch { $failure=$_.Exception.Message }
Assert-True ($failure -match 'approval was cancelled') 'UAC cancellation has an actionable error without unelevated fallback.'
& $module { $script:LaunchFailure=New-Object ComponentModel.Win32Exception(5) }
$failure=''; try { Start-SfsuElevatedGui -EntryPath $entryPath -LdapServer x -Scenario Completed } catch { $failure=$_.Exception.Message }
Assert-True ($failure -notmatch 'cancelled' -and $failure.Length -gt 0) 'Other broker errors retain their actual cause.'
Remove-Module $module

# Synthetic network-drive/provider results exercise the actual native-buffer
# decoding and failure path without mapping a drive or contacting any server.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Sfsu.Launch {
 public static class Native {
  public static int ErrorCode=0;
  public static int WNetGetUniversalNameW(string path, int level, IntPtr buffer, ref int size) {
   if (ErrorCode!=0) return ErrorCode;
   byte[] data=Encoding.Unicode.GetBytes(@"\\synthetic.invalid\toolkit share\App\Scripts\Start-SfsuUsmt.ps1"+"\0");
   int needed=IntPtr.Size+data.Length;
   if (buffer==IntPtr.Zero || size<needed) { size=needed; return 234; }
   IntPtr text=IntPtr.Add(buffer,IntPtr.Size);
   Marshal.WriteIntPtr(buffer,text); Marshal.Copy(data,0,text,data.Length); size=needed; return 0;
  }
 }
}
'@
$launchSource=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Sfsu.Launch.psm1'))
$driveCall='$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($path))'
if (-not $launchSource.Contains($driveCall)) { throw 'Network-drive fixture seam missing.' }
$mappedModulePath=Join-Path $testRoot 'MappedLaunch.psm1'
[IO.File]::WriteAllText($mappedModulePath,$launchSource.Replace($driveCall,'$drive=[pscustomobject]@{DriveType=[IO.DriveType]::Network}'))
$mappedModule=Import-Module $mappedModulePath -Force -PassThru
Assert-True ((Resolve-SfsuLaunchPath $entryPath) -eq '\\synthetic.invalid\toolkit share\App\Scripts\Start-SfsuUsmt.ps1') 'A mapped entry path decodes the provider UNC result before relaunch.'
[Sfsu.Launch.Native]::ErrorCode=2250
$failure=''; try { Resolve-SfsuLaunchPath $entryPath } catch { $failure=$_.Exception.Message }
Assert-True ($failure -match 'error 2250' -and $failure -match 'UNC or local path') 'An unresolved mapping fails with guidance instead of relaunching against a missing drive letter.'
Remove-Module $mappedModule

# Run the actual entry point in isolated packages. Only native UAC/token results,
# logging import and modal error display are substituted; no app UI is loaded.
$entry=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1'))
$messageCall="[void][Windows.Forms.MessageBox]::Show(`$message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)"
if (-not $entry.Contains($messageCall)) { throw 'Startup error fixture seam missing.' }
$entry=$entry.Replace($messageCall,"[IO.File]::WriteAllText((Join-Path `$packageRoot 'error.txt'),`$message)")
foreach ($case in @('request','already-admin','cancel','child-failed','headless','build-ui')) {
    $root=Join-Path $testRoot $case
    $scripts=Join-Path $root 'App/Scripts'; [void][IO.Directory]::CreateDirectory($scripts)
    [IO.File]::WriteAllText((Join-Path $scripts 'Start-SfsuUsmt.ps1'),$entry)
    $admin=if ($case -eq 'already-admin') { '$true' } else { '$false' }
    $outcome=switch ($case) { 'cancel' { "throw 'Administrator approval was cancelled.'" }; 'child-failed' { 'return 7' }; default { 'return 0' } }
    $launchFixture='function Test-SfsuAdministrator { '+$admin+' }; function Start-SfsuElevatedGui { param($EntryPath,$LdapServer,$Scenario); [IO.File]::WriteAllText((Join-Path $PSScriptRoot ''../../request.json''),(ConvertTo-Json @{EntryPath=$EntryPath;LdapServer=$LdapServer;Scenario=$Scenario})); '+$outcome+' }'
    if ($case -in @('headless','build-ui')) { $launchFixture="throw 'Non-GUI must not import the elevation module.'" }
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Launch.psm1'),$launchFixture)
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Logging.psm1'),"[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '../../logging.txt'),'reached'); throw 'Synthetic import stop before UI/discovery.'")
    $options=switch ($case) { 'headless' { @('-Headless') }; 'build-ui' { @('-BuildUiOnly') }; default { @('-LdapServer','dc.example.invalid','-Scenario','Warnings') } }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments='-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+(Join-Path $scripts 'Start-SfsuUsmt.ps1')+'" '+($options -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Entry-point fixture timed out.' }
        $code=$process.ExitCode
        [IO.File]::WriteAllText((Join-Path $root 'stderr.txt'),$process.StandardError.ReadToEnd())
    } finally { $process.Dispose() }
    $requested=Test-Path -LiteralPath (Join-Path $root 'request.json')
    $logging=Test-Path -LiteralPath (Join-Path $root 'logging.txt')
    if ($case -eq 'request') {
        Assert-True ($code -eq 0 -and $requested -and -not $logging) 'Unelevated GUI relaunches before logging, discovery or credential collection.'
        $request=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'request.json')))
        Assert-True ($request.LdapServer -eq 'dc.example.invalid' -and $request.Scenario -eq 'Warnings' -and $request.EntryPath -eq (Join-Path $scripts 'Start-SfsuUsmt.ps1')) 'Entry-point relaunch preserves the saved script path and GUI options.'
    } elseif ($case -eq 'already-admin') {
        Assert-True ($code -eq 1 -and -not $requested -and $logging) 'Already elevated GUI proceeds without another UAC request (stopped by the synthetic logger).'
    } elseif ($case -in @('headless','build-ui')) {
        Assert-True ($code -eq 1 -and -not $requested -and $logging -and -not (Test-Path -LiteralPath (Join-Path $root 'error.txt'))) 'Non-GUI developer actions bypass elevation and preserve console failure handling.'
    } else {
        $message=[IO.File]::ReadAllText((Join-Path $root 'error.txt'))
        Assert-True ($code -eq 1 -and $requested -and -not $logging -and $message.Contains('Startup details:')) 'Cancelled/failed elevation stops before app work and requests a graphical error with saved details.'
        $startup=Get-ChildItem -LiteralPath (Join-Path $root 'Logs') -Filter 'startup-*.txt'
        $details=[IO.File]::ReadAllText($startup.FullName)
        if ($case -eq 'cancel') { Assert-True ($details -match 'approval was cancelled' -and $message -match 'approval was cancelled') 'Cancellation appears directly in the graphical message and remains available in the startup log.' }
        else { Assert-True ($details -match 'exited with code 7' -and $details -match 'administrator account') 'An inaccessible/failed elevated child yields actionable startup diagnostics.' }
    }
}
Write-Output ("PASS: $script:Assertions elevation assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
