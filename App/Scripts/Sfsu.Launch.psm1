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
    $size=0
    $result=[Sfsu.Launch.Native]::WNetGetUniversalNameW($path,1,[IntPtr]::Zero,[ref]$size)
    if ($result -ne 234 -or $size -le 0 -or $size -gt 1048576) {
        throw "Cannot resolve the mapped toolkit path before elevation (Windows error $result). Launch from an accessible UNC or local path."
    }
    $buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        $result=[Sfsu.Launch.Native]::WNetGetUniversalNameW($path,1,$buffer,[ref]$size)
        if ($result -ne 0) { throw "Cannot resolve the mapped toolkit path before elevation (Windows error $result)." }
        $universal=[Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($buffer))
        if (-not $universal.StartsWith('\\')) { throw 'The mapped toolkit path did not resolve to a UNC path.' }
        return $universal
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
}

function ConvertTo-SfsuLaunchArgument([string]$Value) {
    # Windows argv quoting; Start-Process joins ArgumentList without quoting it.
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}

function Start-SfsuElevatedGui {
    param([string]$EntryPath,[string]$LdapServer,[string]$Scenario)
    $path=Resolve-SfsuLaunchPath $EntryPath
    $arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(ConvertTo-SfsuLaunchArgument $path)+
        ' -LdapServer '+(ConvertTo-SfsuLaunchArgument $LdapServer)+' -Scenario '+(ConvertTo-SfsuLaunchArgument $Scenario)
    try {
        # Use the OS elevation broker, never an app-collected password. Waiting
        # preserves synchronous CLI startup/exit status; the normal CMD detaches.
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:SystemRoot -Wait -PassThru -ErrorAction Stop
        try { return $process.ExitCode } finally { $process.Dispose() }
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

Export-ModuleMember -Function Test-SfsuAdministrator,Resolve-SfsuLaunchPath,Start-SfsuElevatedGui
