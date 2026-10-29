# Windows PowerShell 5.1. Inventory and folder preparation only; no migration engine.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.DirectoryServices.Protocols

function Get-SfsuPacificTime([DateTimeOffset]$Time = [DateTimeOffset]::UtcNow) {
    [TimeZoneInfo]::ConvertTime($Time, [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time'))
}

function Get-SfsuProfiles {
    # Query only the local account database. Do not enumerate domain accounts.
    $localPrefixes = @{}
    $localAccounts = @{}
    foreach ($account in @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop)) {
        if ($account.SID -match '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { $localPrefixes[$Matches[1]] = $true; $localAccounts[[string]$account.SID] = [string]$account.Name }
    }
    if ($localPrefixes.Count -eq 0) { throw 'Could not establish the local account SID prefix; profile classification stopped.' }
    foreach ($profile in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)) {
        if ($profile.Special -or $profile.SID -notmatch '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { continue }
        $isLocal = $localPrefixes.ContainsKey($Matches[1])
        if (-not (Test-Path -LiteralPath $profile.LocalPath -PathType Container)) { continue }
        $folder = Get-Item -LiteralPath $profile.LocalPath -Force -ErrorAction Stop
        if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $accountType='Domain'; $id=''; $accountName=$folder.Name; $idSource='Unavailable'
        if ($isLocal) {
            $accountType='Local'; $idSource='NotApplicable'
            if ($localAccounts.ContainsKey([string]$profile.SID) -and $localAccounts[[string]$profile.SID]) { $accountName=$localAccounts[[string]$profile.SID] }
        } elseif ($folder.Name -match '^\d{1,32}$') { $id=$folder.Name; $idSource='ProfileDirectory' }
        [pscustomobject]@{
            ProfileSid = [string]$profile.SID; ProfilePath = $folder.FullName; Loaded = [bool]$profile.Loaded
            AccountType=$accountType; AccountName=$accountName; SfsuIdSource=$idSource
            SfsuId = $id; DisplayName = ''; SamAccountName = ''; UserPrincipalName = ''; DirectorySid = ''
            IdentitySource = 'Unresolved'; IdentityStatus = 'Not looked up'; VerifiedAtUtc = ''; ManualConfirmed = $false
        }
    }
}

# Retained for callers that explicitly request domain candidates only.
function Get-SfsuDomainProfiles { Get-SfsuProfiles | Where-Object AccountType -eq 'Domain' }

function ConvertTo-SfsuSidFilter([string]$Sid) {
    $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    $bytes = New-Object byte[] $identity.BinaryLength
    $identity.GetBinaryForm($bytes, 0)
    ($bytes | ForEach-Object { '\' + $_.ToString('x2') }) -join ''
}

function Get-SfsuWindowsIdentityName {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $identity.Name } finally { $identity.Dispose() }
}

function Open-SfsuLoggedDirectorySession {
    param($Run, [string]$StepId, [string]$Server, [System.Management.Automation.PSCredential]$Credential)
    $windowsAccount = 'Unavailable'
    try { $windowsAccount = Get-SfsuWindowsIdentityName } catch { }
    $source = 'Default Windows credentials'
    $account = 'Windows-selected default account; not independently verified'
    $evidence = 'The Windows execution identity is context only. Outbound credentials can differ, for example with network-only logon or target-specific Windows credentials.'
    if ($null -ne $Credential) {
        $source = 'Explicit directory credentials'
        $account = $Credential.UserName
        $evidence = 'Username supplied for the LDAP bind; not a directory-confirmed identity.'
    }
    # Build diagnostics only from account-name strings. Never serialize the
    # PSCredential, SecureString, NetworkCredential, or password into the journal.
    $details = @(
        ('LDAP endpoint: ' + $Server + ':389'),
        'Authentication: Negotiate; signing and sealing enabled',
        ('Credential source: ' + $source),
        ('Attempted LDAP account: ' + $account),
        ('Windows execution identity: ' + $windowsAccount),
        ('Account evidence: ' + $evidence)
    ) -join "`n"
    $context = $windowsAccount
    if ($null -ne $Credential) { $context = $account }
    Write-SfsuLogEvent -Run $Run -StepId $StepId -Message ('Attempting LDAP connection to ' + $Server + ' using ' + $source + '; account context: ' + $context + '.') -Details $details
    # Persist the attempted context before binding, including when binding fails.
    New-SfsuDirectorySession -Server $Server -Credential $Credential
}

function New-SfsuDirectorySession {
    param([string]$Server = 'ad.sfsu.edu', [System.Management.Automation.PSCredential]$Credential)
    if ($Server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Use an LDAP server DNS name without a path or port.' }
    $identifier = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Server, 389, $false, $false)
    $connection = New-Object System.DirectoryServices.Protocols.LdapConnection($identifier)
    try {
        $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        if ($null -ne $Credential) { $connection.Credential = $Credential.GetNetworkCredential() }
        $connection.Timeout = [TimeSpan]::FromSeconds(8)
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.SessionOptions.Signing = $true
        $connection.SessionOptions.Sealing = $true
        $connection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
        $connection.Bind()
        $request = New-Object System.DirectoryServices.Protocols.SearchRequest
        $request.DistinguishedName = ''
        $request.Filter = '(objectClass=*)'
        $request.Scope = [System.DirectoryServices.Protocols.SearchScope]::Base
        [void]$request.Attributes.Add('defaultNamingContext')
        $request.TimeLimit = [TimeSpan]::FromSeconds(8)
        $request.SizeLimit = 2
        $response = $connection.SendRequest($request)
        if ($response.Entries.Count -ne 1 -or -not $response.Entries[0].Attributes.Contains('defaultNamingContext')) {
            throw 'The server did not return a default naming context.'
        }
        [pscustomobject]@{ Connection = $connection; SearchBase = [string]$response.Entries[0].Attributes['defaultNamingContext'][0]; Server = $Server }
    } catch { $connection.Dispose(); throw }
}

function Get-SfsuDirectoryRecords {
    param($Session, [string]$Sid)
    $request = New-Object System.DirectoryServices.Protocols.SearchRequest
    $request.DistinguishedName = $Session.SearchBase
    $request.Scope = [System.DirectoryServices.Protocols.SearchScope]::Subtree
    $request.Filter = '(&(objectCategory=person)(objectClass=user)(objectSid=' + (ConvertTo-SfsuSidFilter $Sid) + '))'
    foreach ($attribute in @('sAMAccountName','displayName','userPrincipalName','objectSid')) { [void]$request.Attributes.Add($attribute) }
    $request.SizeLimit = 2
    $request.TimeLimit = [TimeSpan]::FromSeconds(8)
    $response = $Session.Connection.SendRequest($request)
    foreach ($entry in $response.Entries) {
        $values = @{ SamAccountName=''; DisplayName=''; UserPrincipalName=''; Sid='' }
        foreach ($pair in @(@('sAMAccountName','SamAccountName'), @('displayName','DisplayName'), @('userPrincipalName','UserPrincipalName'))) {
            if ($entry.Attributes.Contains($pair[0])) { $values[$pair[1]] = [string]$entry.Attributes[$pair[0]][0] }
        }
        if ($entry.Attributes.Contains('objectSid')) {
            $sidObject = New-Object System.Security.Principal.SecurityIdentifier([byte[]]$entry.Attributes['objectSid'][0], 0)
            $values.Sid = $sidObject.Value
        }
        [pscustomobject]$values
    }
}

function Resolve-SfsuProfileIdentity {
    param($Profile, $Session)
    if ($Profile.SfsuId -notmatch '^\d{1,32}$') { $Profile.IdentityStatus='Numeric SFSU ID unavailable in profile directory'; return $Profile }
    $records = @(Get-SfsuDirectoryRecords -Session $Session -Sid $Profile.ProfileSid)
    $Profile.IdentitySource = 'Unresolved'; $Profile.IdentityStatus = 'Account not found'
    if ($records.Count -gt 1) { $Profile.IdentityStatus = 'Conflicting directory matches'; return $Profile }
    if ($records.Count -eq 0) { return $Profile }
    $record = $records[0]
    if ($record.Sid -ne $Profile.ProfileSid) { $Profile.IdentityStatus = 'Directory SID conflict'; return $Profile }
    $Profile.DirectorySid = $record.Sid
    $Profile.SamAccountName = $record.SamAccountName
    $Profile.UserPrincipalName = $record.UserPrincipalName
    # No hard-coded nine-digit rule until account-format exceptions are confirmed.
    if ($record.SamAccountName -notmatch '^\d{1,32}$') { $Profile.IdentityStatus = 'Numeric SFSU ID unavailable'; return $Profile }
    if ($Profile.SfsuId -and $Profile.SfsuId -cne $record.SamAccountName) { $Profile.IdentityStatus='Directory ID conflict with profile directory'; return $Profile }
    $Profile.SfsuId = $record.SamAccountName
    if ([string]::IsNullOrWhiteSpace($record.DisplayName)) { $Profile.IdentityStatus = 'Display name unavailable'; return $Profile }
    $Profile.DisplayName = $record.DisplayName
    $Profile.IdentitySource = 'LDAP'; $Profile.IdentityStatus = 'Directory verified'
    $Profile.VerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $Profile
}

function Get-SfsuLookupFailure($Failure) {
    $exception = $Failure.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    if ($exception -is [System.DirectoryServices.Protocols.LdapException]) {
        if ($exception.ErrorCode -eq 49) { return 'Authentication failed' }
        if ($exception.ErrorCode -in @(81,85,91)) { return 'Directory unreachable or timed out' }
        return ('Directory request failed (LDAP code ' + $exception.ErrorCode + ')')
    }
    'Directory request failed'
}

function ConvertTo-SfsuLogin([string]$UserName) {
    $value = $UserName.Trim()
    if ($value -match '^\d{1,32}$') { return ($value + '@sfsu.edu') }
    if ($value -match '^\d{1,32}@sfsu\.edu$') { return $value }
    if ($value.Contains('@')) { throw 'Enter your SFSU ID, not your email address.' }
    throw 'Enter your numeric SFSU ID or your full SFSU Login (ID@sfsu.edu).'
}

function Invoke-SfsuDirectoryAuthentication {
    param([Parameter(Mandatory)][string]$PackageRoot, [string]$Server='ad.sfsu.edu',
        [Parameter(Mandatory)][Management.Automation.PSCredential]$Credential)
    $run = New-SfsuLogRun -PackageRoot $PackageRoot -Operation DirectoryAuthentication -Steps @(@{Id='authenticate';Title='Authenticate to Active Directory'})
    $session = $null
    try {
        Start-SfsuLogStep -Run $run -StepId authenticate
        $session = Open-SfsuLoggedDirectorySession -Run $run -StepId authenticate -Server $Server -Credential $Credential
        Write-SfsuCheckpoint -Run $run -StepId authenticate -Status Passed -Message 'LDAP authentication and directory naming-context discovery succeeded. No employee profile lookup was required.'
        Complete-SfsuLogStep -Run $run -StepId authenticate -Status Passed -Message 'Active Directory connection verified.'
        Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Active Directory authentication succeeded.' | Out-Null
        [pscustomobject]@{Success=$true;DirectoryStatus='Connected';ReportPath=$run.ReportPath}
    } catch {
        $status = Get-SfsuLookupFailure $_
        Write-SfsuLogEvent -Run $run -StepId authenticate -Severity ERROR -Message $status -NextAction 'Check your SFSU ID/password and connection, retry, or continue without AD.'
        Complete-SfsuLogStep -Run $run -StepId authenticate -Status Failed -Message 'Active Directory authentication did not succeed.'
        Complete-SfsuLogRun -Run $run -Outcome Failed -Message $status | Out-Null
        [pscustomobject]@{Success=$false;DirectoryStatus=$status;ReportPath=$run.ReportPath}
    } finally { if ($null -ne $session) { $session.Connection.Dispose() } }
}

function Set-SfsuManualIdentity {
    param($Profile, [string]$SfsuId, [string]$DisplayName, [switch]$Confirmed)
    if ($Profile.IdentityStatus -match 'conflict') { throw 'Resolve the directory identity conflict before preparing this profile.' }
    $id=''
    if ($Profile.AccountType -eq 'Domain') {
        $id=Split-Path $Profile.ProfilePath -Leaf
        if ($id -notmatch '^\d{1,32}$') { throw 'Cannot infer a numeric SFSU ID from this domain profile directory. Resolve the profile identity before assigning a name.' }
    } elseif ($Profile.AccountType -ne 'Local' -or [string]::IsNullOrWhiteSpace($Profile.AccountName)) { throw 'Profile account type/name is unresolved.' }
    if (-not $Confirmed -or [string]::IsNullOrWhiteSpace($DisplayName)) {
        throw 'Confirm a nonempty display name for the selected profile.'
    }
    if ($PSBoundParameters.ContainsKey('SfsuId') -and $SfsuId -cne $id) { throw 'The inferred profile ID cannot be changed when assigning a display name.' }
    $Profile.SfsuId = $id; $Profile.DisplayName = $DisplayName.Trim()
    $Profile.IdentitySource = 'Manual'; $Profile.IdentityStatus = 'Manually entered (confirmed)'
    $Profile.ManualConfirmed = $true; $Profile.VerifiedAtUtc = ''
    # Never associate a manually substituted ID/name with a previously returned AD identity.
    $Profile.DirectorySid = ''; $Profile.SamAccountName = ''; $Profile.UserPrincipalName = ''
    $Profile
}

function Invoke-SfsuProfileDiscovery {
    param([string]$PackageRoot, [string]$Server = 'ad.sfsu.edu', [System.Management.Automation.PSCredential]$Credential, [switch]$SkipDirectoryLookup)
    $run = New-SfsuLogRun -PackageRoot $PackageRoot -Operation ProfileDiscovery -Steps @(
        @{Id='profiles';Title='Find registered domain and local profiles'}, @{Id='lookup';Title='Resolve domain profile identities; label local accounts'}
    ) -Label 'Live local inventory and directory lookup. No profile files are copied.'
    $session = $null
    try {
        Start-SfsuLogStep -Run $run -StepId profiles
        $profiles = @(Get-SfsuProfiles)
        Write-SfsuCheckpoint -Run $run -StepId profiles -Status Passed -Message ("Found $($profiles.Count) existing domain/local account profile directories using Win32_UserProfile and local account SID prefixes.")
        Complete-SfsuLogStep -Run $run -StepId profiles -Status Passed -Message 'System profiles, missing directories, and directory links were excluded; local accounts were retained.'
        Start-SfsuLogStep -Run $run -StepId lookup
        $directoryStatus = 'No domain profiles to look up'
        if ($SkipDirectoryLookup) {
            $directoryStatus = 'AD lookup skipped; manual identity required'
            Write-SfsuLogEvent -Run $run -StepId lookup -Message 'Continuing without AD. No LDAP connection will be attempted; confirm each selected profile identity manually.'
        } elseif (@($profiles | Where-Object AccountType -eq 'Domain').Count -gt 0) {
            try {
                $session = Open-SfsuLoggedDirectorySession -Run $run -StepId lookup -Server $Server -Credential $Credential
                $directoryStatus = 'Connected'
                Write-SfsuLogEvent -Run $run -StepId lookup -Message "Connected to $Server with signed/sealed Windows LDAP authentication."
            } catch {
                $directoryStatus = Get-SfsuLookupFailure $_
                Write-SfsuLogEvent -Run $run -StepId lookup -Severity WARNING -Message $directoryStatus -NextAction 'Use Directory credentials to retry, or explicitly confirm a manual identity.'
            }
        }
        foreach ($profile in $profiles) {
            if ($profile.AccountType -eq 'Local') {
                $profile.IdentityStatus='Local account; assign display name (no AD lookup)'
            } elseif ($null -ne $session) {
                try { $profile = Resolve-SfsuProfileIdentity -Profile $profile -Session $session }
                catch {
                    $directoryStatus = Get-SfsuLookupFailure $_
                    $session.Connection.Dispose(); $session = $null
                    $profile.IdentityStatus = $directoryStatus
                }
            } else { $profile.IdentityStatus = $directoryStatus }
            $severity = 'INFO'; if ($profile.IdentitySource -ne 'LDAP') { $severity = 'WARNING' }
            Write-SfsuLogEvent -Run $run -StepId lookup -Severity $severity -Message ($profile.ProfilePath + ': ' + $profile.IdentityStatus) -Details ('Source SID: ' + $profile.ProfileSid)
        }
        Complete-SfsuLogStep -Run $run -StepId lookup -Status Passed -Message 'Lookup finished; unresolved rows require confirmed manual identity before folder preparation.'
        Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Profile discovery finished. No backup data was captured.' | Out-Null
        [pscustomobject]@{ Profiles=$profiles; DirectoryStatus=$directoryStatus; ReportPath=$run.ReportPath; RunDirectory=$run.RunDirectory }
    } catch {
        Write-SfsuLogEvent -Run $run -Severity ERROR -Message 'Profile discovery stopped.' -Details $_.Exception.Message
        Complete-SfsuLogRun -Run $run -Outcome Failed -Message 'Discovery failed; no backup folders were prepared.' | Out-Null
        throw
    } finally { if ($null -ne $session) { $session.Connection.Dispose() } }
}

function ConvertTo-SfsuFolderPart([string]$Value, [int]$Limit) {
    $part = [regex]::Replace($Value, '[\x00-\x1f<>:"/\\|?*]', '-')
    $part = [regex]::Replace($part.Trim(), '\s+', ' ').TrimEnd('.', ' ')
    if ($part.Length -gt $Limit) { $part = $part.Substring(0,$Limit).TrimEnd('.', ' ') }
    if (-not $part) { throw 'A backup folder component is empty after sanitization.' }
    if ($part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { $part = '_' + $part }
    $part
}

function Assert-SfsuPlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'A regular directory is required; directory links are not supported.'
    }
    $item.FullName
}

function New-SfsuPreparedBackup {
    param([string]$PackageRoot, $Profile, [string]$RunId, [DateTimeOffset]$Timestamp = [DateTimeOffset]::UtcNow)
    if ($Profile.IdentitySource -notin @('LDAP','Manual') -or $Profile.IdentityStatus -match 'conflict' -or
        [string]::IsNullOrWhiteSpace($Profile.DisplayName)) { throw 'Resolve or confirm this profile identity before preparing a folder.' }
    if ($Profile.AccountType -eq 'Domain') {
        if ($Profile.SfsuId -notmatch '^\d{1,32}$' -or $Profile.SfsuId -cne (Split-Path $Profile.ProfilePath -Leaf)) { throw 'The domain SFSU ID must match the profile directory.' }
    } elseif ($Profile.AccountType -eq 'Local') {
        if ($Profile.SfsuId -or [string]::IsNullOrWhiteSpace($Profile.AccountName) -or $Profile.IdentitySource -ne 'Manual' -or $Profile.DirectorySid) { throw 'Local accounts require a confirmed display name and local account identity, without an SFSU ID or AD identity.' }
    } else { throw 'Unknown profile account type.' }
    if ($Profile.IdentitySource -eq 'Manual' -and -not $Profile.ManualConfirmed) { throw 'Manual identity confirmation is required.' }
    if ($Profile.IdentitySource -eq 'LDAP' -and ($Profile.DirectorySid -ne $Profile.ProfileSid -or -not $Profile.VerifiedAtUtc)) { throw 'Directory identity does not match the source profile SID.' }
    if ($Profile.ProfileSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'A user-account profile SID is required.' }
    [void](Assert-SfsuPlainDirectory $Profile.ProfilePath)
    $root = Join-Path $PackageRoot 'Backups'
    [void][IO.Directory]::CreateDirectory($root)
    $root = Assert-SfsuPlainDirectory $root
    if ($Profile.AccountType -eq 'Local') { $id=ConvertTo-SfsuFolderPart ('Local-'+$Profile.AccountName) 40 }
    else { $id=ConvertTo-SfsuFolderPart $Profile.SfsuId 32 }
    $computer = ConvertTo-SfsuFolderPart $env:COMPUTERNAME 20
    # Leave room for finalized log snapshots on Windows PowerShell's legacy path APIs.
    $nameLimit = [Math]::Min(48, 190 - $root.Length - $id.Length - $computer.Length - 19)
    if ($nameLimit -lt 8) { throw 'The package path is too long for safe backup/log paths. Move it to a shorter path.' }
    $name = ConvertTo-SfsuFolderPart $Profile.DisplayName $nameLimit
    $pacific = Get-SfsuPacificTime $Timestamp
    $folderName = $id + '_' + $name + '_' + $computer + '_' + $pacific.ToString('yyyyMMdd-HHmmss')
    $destination = Join-Path $root $folderName
    if (-not ('Sfsu.DirectoryReservation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Sfsu {
  public static class DirectoryReservation {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CreateDirectory(string path, IntPtr security);
    public static void Reserve(string path) {
      if (!CreateDirectory(path, IntPtr.Zero)) {
        int code = Marshal.GetLastWin32Error();
        if (code == 183) throw new System.IO.IOException("A backup folder with this timestamp already exists. Nothing was overwritten; retry with a new timestamp.");
        throw new System.ComponentModel.Win32Exception(code);
      }
    }
  }
}
'@
    }
    # Atomic mkdir fails on existing paths, including concurrent starts. No overwrite or merge.
    [Sfsu.DirectoryReservation]::Reserve($destination)
    $manifest = [ordered]@{
        SchemaVersion=2; Kind='SfsuUsmtBackup'; Status='PreparedOnly'; HasMigrationData=$false
        CreatedUtc=$Timestamp.ToUniversalTime().ToString('o'); CreatedPacific=$pacific.ToString('o')
        SourceComputer=$env:COMPUTERNAME; PreparationRunId=$RunId
        SourceProfile=@{ Sid=$Profile.ProfileSid; Path=$Profile.ProfilePath; Loaded=$Profile.Loaded }
        Identity=@{ AccountType=$Profile.AccountType; AccountName=$Profile.AccountName; SfsuIdSource=$Profile.SfsuIdSource
            SfsuId=$Profile.SfsuId; DisplayName=$Profile.DisplayName; Source=$Profile.IdentitySource
            VerifiedAtUtc=$Profile.VerifiedAtUtc; ManualConfirmed=[bool]$Profile.ManualConfirmed
            DirectorySid=$Profile.DirectorySid; SamAccountName=$Profile.SamAccountName; UserPrincipalName=$Profile.UserPrincipalName }
    }
    $manifestPath = Join-Path $destination 'backup.json'
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json $manifest -Depth 8))
    $stream = New-Object IO.FileStream($manifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [pscustomobject]@{ Path=$destination; Manifest=$manifest }
}

function Invoke-SfsuBackupPreparation {
    param([string]$PackageRoot, [object[]]$Profiles)
    if (@($Profiles).Count -eq 0) { throw 'Select at least one profile.' }
    $run = New-SfsuLogRun -PackageRoot $PackageRoot -Operation BackupPreparation -Steps @(
        @{Id='prepare';Title='Prepare selected backup directories and identity metadata'}
    ) -Label 'Folder preparation only. No employee files captured; these folders cannot restore data.'
    $prepared = New-Object Collections.Generic.List[string]
    $errors = New-Object Collections.Generic.List[string]
    Start-SfsuLogStep -Run $run -StepId prepare
    foreach ($profile in $Profiles) {
        try {
            $backup = New-SfsuPreparedBackup -PackageRoot $PackageRoot -Profile $profile -RunId $run.RunId
            $prepared.Add($backup.Path)
            Write-SfsuCheckpoint -Run $run -StepId prepare -Status Passed -Message ('Created ' + $backup.Path + ' and backup.json; status PreparedOnly, HasMigrationData=false.') -Details ('Identity source: ' + $profile.IdentitySource + '; source SID: ' + $profile.ProfileSid)
        } catch {
            $errors.Add($profile.ProfilePath + ': ' + $_.Exception.Message)
            Write-SfsuLogEvent -Run $run -StepId prepare -Severity ERROR -Message ('Could not prepare ' + $profile.ProfilePath) -Details $_.Exception.Message -NextAction 'Review identity, folder access, or timestamp collision before retrying.'
        }
    }
    Complete-SfsuLogStep -Run $run -StepId prepare -Status Passed -Message ("Prepared $($prepared.Count) of $($Profiles.Count) selected directories. No USMT executable ran.")
    Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Folder preparation ended. No backup store was created and no employee data was copied.' | Out-Null
    foreach ($path in $prepared) {
        try { Export-SfsuLogSnapshot -Run $run -BackupPath $path | Out-Null }
        catch { $errors.Add('Log snapshot: ' + $_.Exception.Message) }
    }
    [pscustomobject]@{ Paths=$prepared.ToArray(); Errors=$errors.ToArray(); ReportPath=$run.ReportPath; RunDirectory=$run.RunDirectory }
}

function Read-SfsuBackupManifest([string]$Path) {
    [void](Assert-SfsuPlainDirectory $Path)
    $file = Get-Item -LiteralPath (Join-Path $Path 'backup.json') -Force -ErrorAction Stop
    if ($file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe or oversized backup metadata.' }
    $data = ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName)) -ErrorAction Stop
    if ($data.SchemaVersion -notin @(1,2) -or $data.Kind -ne 'SfsuUsmtBackup' -or $data.Status -ne 'PreparedOnly' -or $data.HasMigrationData -ne $false) {
        throw 'Unrecognized backup metadata/version/status.'
    }
    if ($data.SchemaVersion -eq 1) {
        $data.Identity | Add-Member NoteProperty AccountType 'Domain' -Force
        $data.Identity | Add-Member NoteProperty AccountName ([string]$data.Identity.SfsuId) -Force
        $data.Identity | Add-Member NoteProperty SfsuIdSource 'LegacyMetadata' -Force
    }
    if ($data.SchemaVersion -eq 2 -and $data.SourceProfile.Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Missing source account SID.' }
    if ($data.Identity.AccountType -eq 'Local') {
        if ($data.Identity.SfsuId -or [string]::IsNullOrWhiteSpace($data.Identity.AccountName) -or $data.Identity.DirectorySid -or $data.Identity.Source -ne 'Manual' -or $data.Identity.ManualConfirmed -ne $true) { throw 'Invalid local-account identity metadata.' }
    } elseif ($data.Identity.AccountType -ne 'Domain' -or $data.Identity.SfsuId -notmatch '^\d{1,32}$') { throw 'Invalid domain identity metadata.' }
    if ([string]::IsNullOrWhiteSpace($data.Identity.DisplayName) -or
        $data.Identity.Source -notin @('LDAP','Manual') -or [string]::IsNullOrWhiteSpace($data.SourceComputer)) { throw 'Missing identity metadata.' }
    $created = [DateTimeOffset]::Parse($data.CreatedUtc, [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{ Data=$data; Created=$created }
}

function Get-SfsuBackupCatalog {
    param([string]$PackageRoot)
    $root = Join-Path $PackageRoot 'Backups'
    if (-not (Test-Path -LiteralPath $root)) { return }
    [void](Assert-SfsuPlainDirectory $root)
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop)) {
        $row = [ordered]@{ Path=$folder.FullName; AccountType='Unknown'; AccountName=''; SfsuId=''; DisplayName=$folder.Name; SourceComputer=''
            CreatedUtc=[DateTimeOffset]::MinValue; Timestamp=''; Status='Unrecognized / incomplete folder'; IdentitySource='Unknown'
            DirectorySid=''; FormerName=''; MetadataValid=$false }
        try {
            $manifest = Read-SfsuBackupManifest $folder.FullName
            $row.AccountType=$manifest.Data.Identity.AccountType; $row.AccountName=$manifest.Data.Identity.AccountName
            $row.SfsuId = $manifest.Data.Identity.SfsuId; $row.DisplayName = $manifest.Data.Identity.DisplayName
            $row.SourceComputer = $manifest.Data.SourceComputer; $row.CreatedUtc = $manifest.Created
            $row.Timestamp = (Get-SfsuPacificTime $manifest.Created).ToString('yyyy-MM-dd HH:mm:ss zzz')
            $row.Status = 'Prepared only - no data'; $row.IdentitySource = $manifest.Data.Identity.Source
            $row.DirectorySid = $manifest.Data.Identity.DirectorySid; $row.MetadataValid = $true
        } catch { $row.Status = 'Unreadable / unrecognized metadata' }
        [pscustomobject]$row
    }
}

function Invoke-SfsuBackupInventory {
    param([string]$PackageRoot, [switch]$LookupNames, [string]$Server='ad.sfsu.edu', [System.Management.Automation.PSCredential]$Credential)
    $run = New-SfsuLogRun -PackageRoot $PackageRoot -Operation BackupInventory -Steps @(@{Id='list';Title='Read available backup metadata'}) -Label 'Local backup listing. No restore was performed.'
    $session=$null; $directoryStatus='Not requested (saved metadata)'
    try {
        Start-SfsuLogStep -Run $run -StepId list
        $backups = @(Get-SfsuBackupCatalog $PackageRoot | Sort-Object CreatedUtc -Descending)
        if ($LookupNames -and @($backups | Where-Object { $_.MetadataValid -and $_.AccountType -eq 'Domain' -and $_.IdentitySource -eq 'LDAP' -and $_.DirectorySid }).Count -gt 0) {
            try { $session=Open-SfsuLoggedDirectorySession -Run $run -StepId list -Server $Server -Credential $Credential; $directoryStatus='Connected' }
            catch { $directoryStatus=Get-SfsuLookupFailure $_; Write-SfsuLogEvent -Run $run -StepId list -Severity WARNING -Message $directoryStatus -NextAction 'Use Directory credentials or read the saved backup names offline.' }
        } elseif ($LookupNames) { $directoryStatus='No directory-verified backup identities to refresh' }
        $nameCache=@{}
        foreach ($backup in $backups) {
            if ($null -ne $session -and $backup.MetadataValid -and $backup.AccountType -eq 'Domain' -and $backup.IdentitySource -eq 'LDAP' -and $backup.DirectorySid) {
                try {
                    if (-not $nameCache.ContainsKey($backup.DirectorySid)) { $nameCache[$backup.DirectorySid]=@(Get-SfsuDirectoryRecords -Session $session -Sid $backup.DirectorySid) }
                    $records=$nameCache[$backup.DirectorySid]
                    if ($records.Count -eq 1 -and $records[0].Sid -eq $backup.DirectorySid -and $records[0].SamAccountName -eq $backup.SfsuId -and $records[0].DisplayName) {
                        if ($records[0].DisplayName -cne $backup.DisplayName) { $backup.FormerName=$backup.DisplayName; $backup.DisplayName=$records[0].DisplayName }
                        Write-SfsuLogEvent -Run $run -StepId list -Message ('Verified current directory identity for ' + $backup.Path + '; saved metadata was preserved.')
                    } else { Write-SfsuLogEvent -Run $run -StepId list -Severity WARNING -Message ('Current identity could not be verified for ' + $backup.Path + '; kept the saved name.') }
                } catch {
                    $directoryStatus=Get-SfsuLookupFailure $_; $session.Connection.Dispose(); $session=$null
                    Write-SfsuLogEvent -Run $run -StepId list -Severity WARNING -Message $directoryStatus
                }
            }
            $severity='INFO'; if (-not $backup.MetadataValid) { $severity='WARNING' }
            Write-SfsuLogEvent -Run $run -StepId list -Severity $severity -Message ($backup.Path + ': ' + $backup.Status)
        }
        Complete-SfsuLogStep -Run $run -StepId list -Status Passed -Message ("Read $($backups.Count) backup directories; sorted by saved capture/preparation time, newest first.")
        Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Backup listing completed. Prepared folders contain no migration data.' | Out-Null
        [pscustomobject]@{ Backups=$backups; DirectoryStatus=$directoryStatus; ReportPath=$run.ReportPath; RunDirectory=$run.RunDirectory }
    } catch {
        Write-SfsuLogEvent -Run $run -Severity ERROR -Message 'Backup listing failed.' -Details $_.Exception.Message
        Complete-SfsuLogRun -Run $run -Outcome Failed -Message 'Could not read the backup inventory.' | Out-Null
        throw
    } finally { if ($null -ne $session) { $session.Connection.Dispose() } }
}

function Invoke-SfsuRestoreReview {
    param([string]$PackageRoot, [object[]]$Backups)
    if (@($Backups).Count -eq 0) { throw 'Select at least one backup.' }
    $run = New-SfsuLogRun -PackageRoot $PackageRoot -Operation RestoreReview -Steps @(@{Id='review';Title='Review selected backup metadata'}) -Label 'Selection review only. Restore is not connected.'
    Start-SfsuLogStep -Run $run -StepId review
    $root = [IO.Path]::GetFullPath((Join-Path $PackageRoot 'Backups')).TrimEnd('\')
    foreach ($backup in $Backups) {
        try {
            $path = [IO.Path]::GetFullPath($backup.Path)
            if ([IO.Path]::GetDirectoryName($path) -ne $root) { throw 'Selected folder is outside this package Backups directory.' }
            $manifest = Read-SfsuBackupManifest $path
            Write-SfsuCheckpoint -Run $run -StepId review -Status Warning -Message ($path + ': metadata reviewed. Prepared only; no migration data exists to restore.') -NextAction 'A real capture and verified store will be required before restore integration.'
        } catch {
            Write-SfsuLogEvent -Run $run -StepId review -Severity ERROR -Message ('Cannot review ' + $backup.Path) -Details $_.Exception.Message
        }
    }
    Complete-SfsuLogStep -Run $run -StepId review -Status Passed -Message 'Selection review ended. No destination accounts or files were changed.'
    Complete-SfsuLogRun -Run $run -Outcome Completed -Message 'Restore review ended. No restore command ran.' | Out-Null
    [pscustomobject]@{ ReportPath=$run.ReportPath; RunDirectory=$run.RunDirectory }
}

Export-ModuleMember -Function Get-SfsuProfiles, Get-SfsuDomainProfiles, Set-SfsuManualIdentity, Invoke-SfsuProfileDiscovery,
    Invoke-SfsuBackupPreparation, Get-SfsuBackupCatalog, Invoke-SfsuBackupInventory, Invoke-SfsuRestoreReview,
    ConvertTo-SfsuLogin, Invoke-SfsuDirectoryAuthentication
