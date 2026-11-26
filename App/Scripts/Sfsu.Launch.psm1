Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Test-SfsuAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal=New-Object Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Resolve-SfsuLaunchPath([string]$EntryPath) {
    $path=[IO.Path]::GetFullPath($EntryPath)
    if ($path.StartsWith('\\')) { return $path }
    # Local/removable paths need no network provider (including offline hosts).
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($path))
    if ($drive.DriveType -ne [IO.DriveType]::Network) { return $path }
    if (-not ('Sfsu.Launch.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Sfsu.Launch {
 public static class Native {
  [DllImport("mpr.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
  public static extern int WNetGetUniversalNameW(string path, int level, IntPtr buffer, ref int size);
 }
}
'@
    }
    # WNet requires an output buffer; a null sizing probe can return error 87.
    # Start allocated, then honor ERROR_MORE_DATA with bounded growth/retries.
    $size=1024
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $capacity=$size
        $buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal($capacity)
        try {
            $result=[Sfsu.Launch.Native]::WNetGetUniversalNameW($path,1,$buffer,[ref]$size)
            if ($result -eq 0) {
                $universal=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($buffer))
                if ([string]::IsNullOrEmpty($universal) -or -not $universal.StartsWith('\\')) { throw 'The mapped toolkit path did not resolve to a UNC path.' }
                return $universal
            }
            if ($result -eq 234 -and $size -gt $capacity -and $size -le 1048576 -and $attempt -lt 2) { continue }
            throw "Cannot resolve the mapped toolkit path before elevation (Windows error $result). Launch from an accessible UNC or local path."
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    }
}

function ConvertTo-SfsuLaunchArgument([string]$Value) {
    # Windows argv quoting; Start-Process joins ArgumentList without quoting it.
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}

# These small functions are also carried into the elevated host. They must not
# depend on this module being readable until that host has share access.
function Test-SfsuBootstrapEntryRead([string]$EntryPath) {
    $stream=[IO.File]::Open($EntryPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { [void]$stream.ReadByte() } finally { $stream.Dispose() }
}

function Test-SfsuBootstrapShareRead([string]$SharePath) {
    [void][IO.File]::GetAttributes($SharePath)
}

function Initialize-SfsuSignInAssets {
    if (-not (Get-Variable IdentityPolicy -Scope Script -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Sfsu.Identity.psm1') -Force
        $script:IdentityPolicy=Get-SfsuIdentityPolicy
    }
    if (-not ('Sfsu.SignIn.Native' -as [type])) {
        if (-not (Get-Variable CredentialNativeSource -Scope Script -ErrorAction SilentlyContinue)) {
            $script:CredentialNativeSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Sfsu.Credentials.Native.cs'))
        }
        Add-Type -TypeDefinition $script:CredentialNativeSource
    }
}

function Read-SfsuWindowsCredential([string]$SharePath) {
    $purpose='Sign in to Active Directory'
    if ($SharePath) { $purpose='Connect to '+$SharePath+' and sign in to Active Directory' }
    $native=[Sfsu.SignIn.Native]::Prompt($purpose+". Use your university UPN (account@"+$script:IdentityPolicy.DefaultLoginSuffix+"). Cancel continues without AD only if toolkit access is already available.")
    if ($null -eq $native) { return $null }
    try {
        $login=ConvertTo-SfsuLogin $native.UserName
        $password=$native.TakePassword()
        try { return [Management.Automation.PSCredential]::new($login,$password) }
        catch { $password.Dispose(); throw }
    } finally { $native.Dispose() }
}

function Connect-SfsuBootstrapShare([string]$SharePath,[Management.Automation.PSCredential]$Credential) {
    $result=[Sfsu.SignIn.Native]::Connect($SharePath,$Credential.UserName,$Credential.Password)
    if ($result -eq 1219) { throw 'Windows already has a connection to this server using a different account (Windows error 1219). No existing connection was removed. Resolve that connection in this elevated session, then relaunch SFSU USMT.' }
    if ($result -ne 0) { throw "Windows could not connect to the toolkit share (Windows error $result). Check the network, share permissions and the supplied account." }
}

function Confirm-SfsuSignInRetry([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($Message+"`r`n`r`nRetry to enter credentials again, or Cancel to continue without AD if toolkit access is already available.",'SFSU USMT sign-in',[Windows.Forms.MessageBoxButtons]::RetryCancel,[Windows.Forms.MessageBoxIcon]::Warning) -eq 'Retry'
}

function Wait-SfsuSignInRetry([int]$Failures) {
    [Threading.Thread]::Sleep([int](1000*[Math]::Min(30,2*[Math]::Pow(2,[Math]::Min(4,$Failures-1)))))
}

function Clear-SfsuStartupSignIn($State) {
    if ($null -ne $State -and $null -ne $State.Credential) { $State.Credential.Password.Dispose(); $State.Credential=$null }
}

function Get-SfsuStartupSignIn([string]$EntryPath) {
    Initialize-SfsuSignInAssets
    $share=''
    if ($EntryPath.StartsWith('\\')) {
        $match=[regex]::Match($EntryPath,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)')
        if (-not $match.Success -or $match.Groups[1].Value -in @('?','.')) { throw 'Use an ordinary UNC or local toolkit path.' }
        $share='\\'+$match.Groups[1].Value+'\'+$match.Groups[2].Value
    }
    # Missing local files or missing files on an accessible share are package
    # failures. Do not collect a credential unnecessarily in those cases.
    $entryReadable=$false
    try { Test-SfsuBootstrapEntryRead $EntryPath; $entryReadable=$true }
    catch {
        $denied=$_.Exception.GetBaseException() -is [UnauthorizedAccessException]
        if (-not $share) { throw 'Cannot read the toolkit entry script. Check the complete App package and file permissions.' }
        $readable=$false; try { Test-SfsuBootstrapShareRead $share; $readable=$true } catch { }
        if ($readable -and -not $denied) { throw 'The toolkit share is accessible, but the entry script is missing or unreadable. Check the complete App package and file permissions.' }
    }
    $failures=0
    while ($true) {
        $candidate=$null
        try {
            $candidate=Read-SfsuWindowsCredential $share
            if ($null -eq $candidate) {
                try { Test-SfsuBootstrapEntryRead $EntryPath } catch { throw 'Sign-in was cancelled and toolkit access is unavailable. SFSU USMT did not open.' }
                return @{Credential=$null;UseDirectory=$false;ReportPath=''}
            }
            if ($share -and -not $entryReadable) { Connect-SfsuBootstrapShare $share $candidate }
            Test-SfsuBootstrapEntryRead $EntryPath
            $state=@{Credential=$candidate;UseDirectory=$false;ReportPath=''}; $candidate=$null
            return $state
        } catch {
            if ($null -ne $candidate) { $candidate.Password.Dispose(); $candidate=$null }
            if ($_.Exception.Message -like 'Sign-in was cancelled*') { throw }
            if (-not (Confirm-SfsuSignInRetry $_.Exception.Message)) {
                try { Test-SfsuBootstrapEntryRead $EntryPath } catch { throw 'Sign-in did not complete and toolkit access is unavailable. SFSU USMT did not open.' }
                return @{Credential=$null;UseDirectory=$false;ReportPath=''}
            }
            $failures++; Wait-SfsuSignInRetry $failures
        }
    }
}

function Invoke-SfsuStartupDirectoryAuthentication([string]$PackageRoot,[string]$LdapServer,[Management.Automation.PSCredential]$Credential) {
    Import-Module (Join-Path $PSScriptRoot 'Sfsu.Inventory.psm1')
    Invoke-SfsuDirectoryAuthentication -PackageRoot $PackageRoot -Server $LdapServer -Credential $Credential
}

function Complete-SfsuStartupSignIn([hashtable]$State,[string]$EntryPath,[string]$PackageRoot,[string]$LdapServer) {
    $failures=0
    while ($null -ne $State.Credential) {
        try { $authentication=Invoke-SfsuStartupDirectoryAuthentication $PackageRoot $LdapServer $State.Credential }
        catch { Clear-SfsuStartupSignIn $State; throw 'AD authentication could not complete. Review Logs before retrying.' }
        $State.ReportPath=$authentication.ReportPath
        if ($authentication.Success) { $State.UseDirectory=$true; return $State }
        Clear-SfsuStartupSignIn $State
        if (-not (Confirm-SfsuSignInRetry ('Active Directory: '+$authentication.DirectoryStatus))) { break }
        $failures++; Wait-SfsuSignInRetry $failures
        $previousReport=$State.ReportPath; $State=Get-SfsuStartupSignIn $EntryPath
        if (-not $State.ReportPath) { $State.ReportPath=$previousReport }
    }
    $State.UseDirectory=$false
    return $State
}

function Show-SfsuBootstrapFailure([string]$EntryPath,[string]$Reason) {
    $details=''
    try {
        $packageRoot=Split-Path (Split-Path (Split-Path $EntryPath -Parent) -Parent) -Parent
        $logs=Join-Path $packageRoot 'Logs'
        [void][IO.Directory]::CreateDirectory($logs)
        $details=Join-Path $logs ('startup-'+[guid]::NewGuid().ToString('N')+'.txt')
        [IO.File]::WriteAllText($details,('Elevated toolkit bootstrap: '+$Reason+"`r`nEntry script: "+$EntryPath))
    } catch { $details='' }
    $message="SFSU USMT could not start.`r`n`r`n"+$Reason
    if ($details) { $message+="`r`n`r`nStartup details: "+$details }
    else { $message+="`r`n`r`nStartup details could not be saved because the toolkit Logs folder is unavailable." }
    [Console]::Error.WriteLine($message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
    } catch { [Console]::Error.WriteLine('Could not display the startup error dialog.') }
}

function Invoke-SfsuBootstrapEntry([string]$EntryPath,[string]$LdapServer,[string]$Scenario,[hashtable]$SignIn) {
    $global:LASTEXITCODE=0
    & $EntryPath -LdapServer $LdapServer -Scenario $Scenario -StartupSignIn $SignIn | Out-Host
    return [int]$global:LASTEXITCODE
}

function Invoke-SfsuGuiBootstrap([string]$EntryPath,[string]$LdapServer,[string]$Scenario) {
    $state=$null
    try {
        $state=Get-SfsuStartupSignIn $EntryPath
        return (Invoke-SfsuBootstrapEntry $EntryPath $LdapServer $Scenario $state)
    } catch {
        Show-SfsuBootstrapFailure $EntryPath $_.Exception.Message
        # The waiting entry point must preserve failure without displaying a
        # second, less-specific error after this bootstrap already reported it.
        return 79
    } finally { Clear-SfsuStartupSignIn $state }
}

function New-SfsuGuiBootstrapArguments([string]$EntryPath,[string]$LdapServer,[string]$Scenario) {
    Import-Module (Join-Path $PSScriptRoot 'Sfsu.Identity.psm1') -Force
    $nativeSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Sfsu.Credentials.Native.cs'))
    $options=@{EntryPath=$EntryPath;LdapServer=$LdapServer;Scenario=$Scenario;IdentityPolicy=(Get-SfsuIdentityPolicy)} | ConvertTo-Json -Depth 5 -Compress
    $data=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($options))
    $code=@'
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { Write-Error 'SFSU USMT requires FullLanguage PowerShell in the elevated session.' -ErrorAction Continue; exit 77 }
if ((Get-ExecutionPolicy) -in @('Restricted','AllSigned')) { Write-Error 'Group Policy prevents loading the unsigned SFSU USMT package in the elevated session.' -ErrorAction Continue; exit 78 }
'@
    foreach ($name in @('Test-SfsuIdentityText','ConvertTo-SfsuLogin','Test-SfsuBootstrapEntryRead','Test-SfsuBootstrapShareRead','Initialize-SfsuSignInAssets','Read-SfsuWindowsCredential','Connect-SfsuBootstrapShare','Confirm-SfsuSignInRetry','Wait-SfsuSignInRetry','Clear-SfsuStartupSignIn','Get-SfsuStartupSignIn','Show-SfsuBootstrapFailure','Invoke-SfsuBootstrapEntry','Invoke-SfsuGuiBootstrap')) {
        $body=(Get-Item ('Function:\'+$name)).ScriptBlock.ToString()
        $code+="`r`nfunction "+$name+" {`r`n"+$body+"`r`n}`r`n"
    }
    $code+="`r`n`$options=ConvertFrom-Json ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('"+$data+"')))`r`n"
    $code+='$script:IdentityPolicy=$options.IdentityPolicy; $script:CredentialNativeSource='''+$nativeSource.Replace("'","''")+"';`r`n"
    $code+='$result=Invoke-SfsuGuiBootstrap -EntryPath $options.EntryPath -LdapServer $options.LdapServer -Scenario $options.Scenario; exit $result'
    # Carry public code/configuration before share access without a temporary
    # script file. Compression keeps the Windows command line within its limit.
    $bytes=[Text.Encoding]::UTF8.GetBytes($code); $memory=[IO.MemoryStream]::new()
    try { $zip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Compress,$true); try { $zip.Write($bytes,0,$bytes.Length) } finally { $zip.Dispose() }; $packed=[Convert]::ToBase64String($memory.ToArray()) } finally { $memory.Dispose() }
    $loader=$code.Substring(0,$code.IndexOf('function '))+"`r`n"+
        "`$memory=[IO.MemoryStream]::new([Convert]::FromBase64String('"+$packed+"')); "+
        '$zip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Decompress); $reader=[IO.StreamReader]::new($zip,[Text.Encoding]::UTF8); try { $code=$reader.ReadToEnd() } finally { $reader.Dispose(); $zip.Dispose(); $memory.Dispose() }; & ([scriptblock]::Create($code))'
    $arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
    if ($arguments.Length -gt 30000) { throw 'The toolkit startup command is too long. Use a shorter toolkit path.' }
    return $arguments
}

function Start-SfsuElevatedGui {
    param([string]$EntryPath,[string]$LdapServer,[string]$Scenario)
    $path=Resolve-SfsuLaunchPath $EntryPath
    $arguments=New-SfsuGuiBootstrapArguments $path $LdapServer $Scenario
    try {
        # Use the OS elevation broker, never an app-collected password. Waiting
        # preserves synchronous CLI startup/exit status; the normal CMD detaches.
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:SystemRoot -Wait -PassThru -ErrorAction Stop
        try {
            if ($process.ExitCode -eq 77) { throw 'SFSU USMT requires FullLanguage PowerShell in the elevated session. Application control blocked startup before share authentication.' }
            if ($process.ExitCode -eq 78) { throw 'Group Policy prevents loading the unsigned SFSU USMT package in the elevated session. Use an IT-approved package or policy; no saved policy was changed.' }
            return $process.ExitCode
        } finally { $process.Dispose() }
    } catch {
        $exception=$_.Exception
        while ($null -ne $exception) {
            if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) {
                throw 'Administrator approval was cancelled. SFSU USMT did not open. Relaunch the app and approve the Windows elevation request.'
            }
            $exception=$exception.InnerException
        }
        throw
    }
}

Export-ModuleMember -Function Test-SfsuAdministrator,Resolve-SfsuLaunchPath,Start-SfsuElevatedGui,Get-SfsuStartupSignIn,Complete-SfsuStartupSignIn,Clear-SfsuStartupSignIn
