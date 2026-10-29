# Synthetic inventory/directory fixtures; real isolated filesystem operations. No USMT or live LDAP.
[CmdletBinding()]
param([switch]$IncludeUi)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message
}
foreach ($source in Get-ChildItem -LiteralPath (Join-Path $repository 'App/Scripts') -File) {
    $tokens=$null; $problems=$null
    [void][Management.Automation.Language.Parser]::ParseFile($source.FullName,[ref]$tokens,[ref]$problems)
    if ($problems.Count) { throw ($source.Name+': '+($problems.Message -join '; ')) }
    Assert-True ($problems.Count -eq 0) ('Windows PowerShell parser: '+$source.Name)
}
$engineCalls=@(Get-ChildItem -LiteralPath (Join-Path $repository 'App/Scripts') -File | ForEach-Object {
    $tokens=$null; $problems=$null
    $tree=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$problems)
    $tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '(?i)(scanstate|loadstate|usmtutils)(\.exe)?$'},$true)
})
Assert-True ($engineCalls.Count -eq 0) 'No shipped script calls the USMT executables.'
$testRoot=Join-Path $PSScriptRoot ('.work/inventory-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
foreach ($name in @('Sfsu.Logging.psm1','Sfsu.Inventory.psm1')) { Copy-Item -LiteralPath (Join-Path $repository "App/Scripts/$name") -Destination (Join-Path $testRoot "App/Scripts/$name") }
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1') -Force
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Inventory.psm1') -Force
$module=Get-Module Sfsu.Inventory
$sourcePath=Join-Path $testRoot '000000123'
[void][IO.Directory]::CreateDirectory($sourcePath)
$sentinel=Join-Path $sourcePath 'untouched.txt'; [IO.File]::WriteAllText($sentinel,'SYNTHETIC source data must never be copied or modified.')
$sourceHash=(Get-FileHash -LiteralPath $sentinel).Hash
$domainSid='S-1-5-21-111111-222222-333333-1101'
$localSid='S-1-5-21-444444-555555-666666-1001'
$localPath=Join-Path $testRoot '555555555'; [void][IO.Directory]::CreateDirectory($localPath)
[IO.File]::WriteAllText((Join-Path $localPath 'local-sentinel.txt'),'Synthetic local profile contents are preserved.')
$fixtures=@(
    [pscustomobject]@{SID=$domainSid;LocalPath=$sourcePath;Special=$false;Loaded=$false},
    [pscustomobject]@{SID=$localSid;LocalPath=$localPath;Special=$false;Loaded=$false},
    [pscustomobject]@{SID='S-1-5-18';LocalPath=$sourcePath;Special=$true;Loaded=$true},
    [pscustomobject]@{SID='S-1-5-21-111111-222222-333333-1102';LocalPath=(Join-Path $testRoot 'missing');Special=$false;Loaded=$false}
)
& $module {
    param($items,$local)
    $script:Fixtures=$items; $script:LocalSid=$local
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        $script:CimCalls++
        if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID=$script:LocalSid;Name='local-tech'} }
        $script:Fixtures
    }
    $script:CimCalls=0
} $fixtures $localSid
$profiles=@(Get-SfsuDomainProfiles)
Assert-True ($profiles.Count -eq 1) 'The compatibility domain-only query retains its domain filter.'
Assert-True ($profiles[0].ProfileSid -eq $domainSid) 'Profile SID is preserved independently of the directory name.'
Assert-True ($profiles[0].SfsuId -ceq '000000123' -and $profiles[0].SfsuIdSource -eq 'ProfileDirectory') 'Domain SFSU ID is inferred from the profile folder, preserving leading zeros.'
$allProfiles=@(Get-SfsuProfiles)
$localProfile=@($allProfiles | Where-Object AccountType -eq 'Local')[0]
Assert-True ($allProfiles.Count -eq 2 -and $localProfile.ProfileSid -eq $localSid) 'General discovery includes local and domain user profiles but excludes system/missing profiles.'
Assert-True (-not $localProfile.SfsuId -and $localProfile.AccountName -eq 'local-tech') 'Local SID classification overrides a numeric folder name and preserves the local SAM username.'
& $module {
    param($sid)
    $script:Records=@{ $sid=@([pscustomobject]@{Sid=$sid;SamAccountName='000000123';DisplayName='Synthetic Person';UserPrincipalName='000000123@example.invalid'}) }
    $script:DirectoryFailure=$false
    $script:DirectoryFailureCode=81
    $script:LastDirectoryAccount=''
    $script:WindowsIdentityFailure=$false
    $script:QueriedSids=@()
    function script:Get-SfsuWindowsIdentityName {
        if ($script:WindowsIdentityFailure) { throw 'Synthetic Windows identity lookup failure.' }
        'SYNTHETIC-LAPTOP\LocalAdmin'
    }
    function script:New-SfsuDirectorySession {
        param($Server,$Credential)
        $script:LastDirectoryAccount='Default'
        if ($null -ne $Credential) { $script:LastDirectoryAccount=$Credential.UserName }
        if ($script:DirectoryFailure) { throw (New-Object DirectoryServices.Protocols.LdapException($script:DirectoryFailureCode)) }
        $connection=New-Object psobject
        $connection | Add-Member ScriptMethod Dispose {}
        [pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid';Server=$Server}
    }
    function script:Get-SfsuDirectoryRecords {
        param($Session,$Sid)
        $script:QueriedSids+= $Sid
        if ($script:Records.ContainsKey($Sid)) { $script:Records[$Sid] }
    }
} $domainSid
$discovery=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
$verified=$discovery.Profiles[0]
Assert-True ($verified.IdentitySource -eq 'LDAP') 'Exact SID lookup resolves identity.'
Assert-True ($verified.SfsuId -ceq '000000123') 'Leading zeros in the SFSU ID are preserved.'
Assert-True ($verified.DisplayName -eq 'Synthetic Person') 'Directory display name is returned.'
Assert-True ($discovery.Profiles.Count -eq 2 -and (@($discovery.Profiles | Where-Object AccountType -eq 'Local')[0].IdentityStatus -match 'Local account')) 'Discovery labels local accounts independently of AD authentication.'
Assert-True ((& $module { $script:QueriedSids -contains $script:LocalSid }) -eq $false) 'Local account SIDs are never sent to LDAP.'
$journal=[IO.File]::ReadAllText((Join-Path $discovery.RunDirectory 'events.jsonl'))
Assert-True (-not ($journal -match 'simulated') -and (ConvertFrom-Json ($journal -split "`n")[0]).Data.Sample -eq $false) 'Discovery journal records actual actions without simulated events.'
Assert-True ($journal -match 'ProfileDiscovery') 'Discovery has its own operation label.'
$attempts=@([IO.File]::ReadAllLines((Join-Path $discovery.RunDirectory 'events.jsonl')) | ForEach-Object { ConvertFrom-Json $_ } | Where-Object Message -Like 'Attempting LDAP connection*')
Assert-True ($attempts.Count -eq 1 -and $attempts[0].Details.Contains('Default Windows credentials')) 'Default discovery records one LDAP attempt and its credential source.'
Assert-True ($attempts[0].Details.Contains('SYNTHETIC-LAPTOP\LocalAdmin') -and $attempts[0].Details.Contains('not independently verified')) 'Default credentials record execution identity without claiming the outbound account is verified.'
Assert-True ([IO.File]::ReadAllText($discovery.ReportPath).Contains('SYNTHETIC-LAPTOP\LocalAdmin')) 'The HTML report includes the attempted authentication context.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000999' } $domainSid
$folderConflict=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
Assert-True ($folderConflict.Profiles[0].SfsuId -ceq '000000123' -and $folderConflict.Profiles[0].IdentityStatus -match 'ID conflict') 'LDAP cannot silently overwrite an inferred folder ID with a different account ID.'
Assert-Throws { Set-SfsuManualIdentity -Profile $folderConflict.Profiles[0] -DisplayName 'Wrong Account' -Confirmed } 'Assign Display Name cannot bypass a folder/directory ID conflict.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000123' } $domainSid
$filter=& $module { param($sid) ConvertTo-SfsuSidFilter $sid } $domainSid
Assert-True ($filter -match '^(\\[0-9a-f]{2})+$') 'SID filter uses binary hex escapes rather than filter text interpolation.'

# Record an explicitly supplied account before a failed bind, without secrets.
$secretFixture='SYNTHETIC-password-must-not-be-logged-578'
$credentialFixture=New-Object Management.Automation.PSCredential('EXAMPLE\PowerTech',(ConvertTo-SecureString $secretFixture -AsPlainText -Force))
Assert-True ((ConvertTo-SfsuLogin ' 000000123 ') -ceq '000000123@sfsu.edu') 'Bare IDs normalize to SFSU Login while preserving leading zeros.'
Assert-True ((ConvertTo-SfsuLogin '000000123@SFSU.EDU') -ceq '000000123@SFSU.EDU') 'A complete login is accepted without appending or rewriting its suffix.'
foreach ($invalidLogin in @('','person@sfsu.edu','000000123@example.invalid','EXAMPLE\tech','12 34','123@sfsu.edu@sfsu.edu')) {
    Assert-Throws { ConvertTo-SfsuLogin $invalidLogin } ('Invalid/email login is rejected: ' + $invalidLogin)
}
$beforeAuthCim=& $module { $script:CimCalls }
$authenticated=Invoke-SfsuDirectoryAuthentication -PackageRoot $testRoot -Credential $credentialFixture
Assert-True ($authenticated.Success -and [IO.File]::ReadAllText($authenticated.ReportPath).Contains('id="outcome">Completed</h2>')) 'Authentication independently verifies a connection and finalizes a real report.'
Assert-True ((& $module { $script:CimCalls }) -eq $beforeAuthCim) 'Authentication requires no profile inventory, including on machines with no employee profiles.'
& $module { $script:DirectoryFailure=$true; $script:DirectoryFailureCode=49 }
$failedAuthentication=Invoke-SfsuDirectoryAuthentication -PackageRoot $testRoot -Credential $credentialFixture
Assert-True (-not $failedAuthentication.Success -and $failedAuthentication.DirectoryStatus -eq 'Authentication failed') 'Failed authentication returns a retryable result instead of accepting credentials.'
Assert-True ([IO.File]::ReadAllText($failedAuthentication.ReportPath).Contains('id="outcome">Failed</h2>')) 'Authentication failure is finalized as Failed.'
$withoutAd=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -SkipDirectoryLookup
$manualJournal=[IO.File]::ReadAllText((Join-Path $withoutAd.RunDirectory 'events.jsonl'))
Assert-True ($withoutAd.Profiles.Count -eq 2 -and $withoutAd.Profiles[0].IdentitySource -eq 'Unresolved' -and $withoutAd.DirectoryStatus -match 'skipped') 'Manual mode enumerates both account types without claiming AD identity.'
Assert-True (-not $manualJournal.Contains('Attempting LDAP connection')) 'Manual mode never falls back to default LDAP credentials.'
$authFailure=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
$authEvents=@([IO.File]::ReadAllLines((Join-Path $authFailure.RunDirectory 'events.jsonl')) | ForEach-Object { ConvertFrom-Json $_ })
$authAttempt=@($authEvents | Where-Object Message -Like 'Attempting LDAP connection*')[0]
$authWarning=@($authEvents | Where-Object Message -EQ 'Authentication failed')[0]
Assert-True ($authAttempt.Sequence -lt $authWarning.Sequence) 'Attempt context is persisted before a failed LDAP bind.'
Assert-True ($authAttempt.Details.Contains('Attempted LDAP account: EXAMPLE\PowerTech') -and $authAttempt.Details.Contains('Explicit directory credentials')) 'Explicit LDAP account and source are recorded accurately.'
Assert-True ((& $module { $script:LastDirectoryAccount }) -eq $credentialFixture.UserName) 'The recorded explicit account is the credential passed to the connection.'
Assert-True ($authFailure.DirectoryStatus -eq 'Authentication failed') 'Authentication failure retains its original status with account diagnostics.'
$authJournal=[IO.File]::ReadAllText((Join-Path $authFailure.RunDirectory 'events.jsonl'))
$authHtml=[IO.File]::ReadAllText($authFailure.ReportPath)
Assert-True (-not $authJournal.Contains($secretFixture) -and -not $authHtml.Contains($secretFixture) -and -not $authJournal.Contains('System.Security.SecureString')) 'Journals/reports contain account names without passwords or credential objects.'
& $module { $script:DirectoryFailure=$false; $script:WindowsIdentityFailure=$true }
$missingContext=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
Assert-True ($missingContext.DirectoryStatus -eq 'Connected' -and [IO.File]::ReadAllText($missingContext.ReportPath).Contains('Windows execution identity: Unavailable')) 'Unavailable execution-identity diagnostics do not prevent LDAP lookup.'
& $module { $script:WindowsIdentityFailure=$false; $script:DirectoryFailureCode=81 }

& $module { $script:DirectoryFailure=$true }
$offline=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
Assert-True ($offline.Profiles[0].IdentitySource -eq 'Unresolved') 'Unreachable LDAP does not invent identity.'
Assert-True ($offline.DirectoryStatus -eq 'Directory unreachable or timed out') 'Directory unavailability is reported accurately.'
$unresolved=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($offline.Profiles[0])
Assert-True ($unresolved.Paths.Count -eq 0 -and $unresolved.Errors.Count -eq 1) 'Unresolved identity cannot produce a prepared folder.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'Backups'))) 'Unresolved profile did not create a backup folder.'
Assert-Throws { Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId '000000123' -DisplayName 'Manual Person' } 'Manual identity requires explicit confirmation.'
Assert-Throws { Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId '../unsafe' -DisplayName 'Manual Person' -Confirmed } 'Non-numeric IDs are rejected.'
$manual=Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId '000000123' -DisplayName 'Manual Person' -Confirmed
Assert-True ($manual.IdentitySource -eq 'Manual' -and $manual.ManualConfirmed -and -not $manual.DirectorySid) 'Manual identity is labeled and detached from directory verification.'

& $module { param($sid) $script:DirectoryFailure=$false; $script:Records[$sid]=@($script:Records[$sid][0],$script:Records[$sid][0]) } $domainSid
$conflict=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
Assert-True ($conflict.Profiles[0].IdentityStatus -match 'Conflicting') 'Multiple directory matches are not selected automatically.'
Assert-Throws { Set-SfsuManualIdentity -Profile $conflict.Profiles[0] -SfsuId '000000123' -DisplayName 'Manual Person' -Confirmed } 'Manual entry cannot bypass directory conflicts.'
& $module { param($sid) $script:Records[$sid]=@($script:Records[$sid][0]) } $domainSid

$prepared=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($verified)
foreach ($identitySource in @('LDAP','Manual')) {
    $nameless=$verified.PSObject.Copy(); $nameless.IdentitySource=$identitySource; $nameless.DisplayName='   '; $nameless.ManualConfirmed=$true
    $namelessResult=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($nameless)
    Assert-True ($namelessResult.Paths.Count -eq 0 -and $namelessResult.Errors.Count -eq 1) ('A nonempty name is required for preparation with identity source '+$identitySource)
}
Assert-True ($prepared.Paths.Count -eq 1 -and $prepared.Errors.Count -eq 0) ('Confirmed identity creates one prepared backup directory. '+($prepared.Errors -join '; '))
$path=$prepared.Paths[0]
Assert-True ((Split-Path $path -Leaf) -match '^000000123_Synthetic Person_.+_\d{8}-\d{6}$') 'Folder uses ID, display name, computer, and timestamp without a GUID suffix.'
$metadata=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $path 'backup.json')))
Assert-True ($metadata.Status -eq 'PreparedOnly' -and -not $metadata.HasMigrationData) 'Metadata explicitly says no migration data exists.'
Assert-True ($metadata.SourceProfile.Sid -eq $domainSid -and $metadata.Identity.DirectorySid -eq $domainSid) 'Source and directory identities are saved separately.'
Assert-True (Test-Path -LiteralPath (Join-Path $path ('Logs/'+(Split-Path $prepared.RunDirectory -Leaf)+'/report.html'))) 'Finalized real preparation logs travel with the prepared folder.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $path 'untouched.txt'))) 'Profile files were not copied.'
Assert-True ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sourceHash) 'Source files remain unchanged.'
$manifestHash=(Get-FileHash -LiteralPath (Join-Path $path 'backup.json')).Hash
$fixed=[DateTimeOffset]::Parse('2026-10-27T12:13:14Z')
$reserved=& $module { param($root,$item,$time) New-SfsuPreparedBackup -PackageRoot $root -Profile $item -RunId 'synthetic' -Timestamp $time } $testRoot $manual $fixed
Assert-Throws { & $module { param($root,$item,$time) New-SfsuPreparedBackup -PackageRoot $root -Profile $item -RunId 'synthetic' -Timestamp $time } $testRoot $manual $fixed } 'Same timestamp cannot reuse or overwrite an existing folder.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $path 'backup.json')).Hash -eq $manifestHash) 'Collision attempts preserve earlier backup metadata.'
$manual.DisplayName='A/Name:*?<>|'; $safe=& $module { param($value) ConvertTo-SfsuFolderPart $value 40 } $manual.DisplayName
Assert-True ($safe -notmatch '[<>:"/\\|?*]') 'Invalid Windows filename characters are sanitized.'
$manual.DisplayName='Manual Person'
$catalog=Invoke-SfsuBackupInventory -PackageRoot $testRoot
Assert-True (-not [IO.File]::ReadAllText((Join-Path $catalog.RunDirectory 'events.jsonl')).Contains('Attempting LDAP connection')) 'Offline backup listing does not claim an LDAP attempt.'
Assert-True ($catalog.Backups.Count -eq 2) 'Restore inventory includes prepared directories.'
Assert-True ($catalog.Backups[0].CreatedUtc -ge $catalog.Backups[1].CreatedUtc) 'Restore inventory starts newest first using saved timestamps.'
Assert-True (@($catalog.Backups | Where-Object { $_.Status -ne 'Prepared only - no data' }).Count -eq 0) 'Prepared folders are never described as restorable data.'
$review=Invoke-SfsuRestoreReview -PackageRoot $testRoot -Backups @($catalog.Backups[0])
$reviewText=[IO.File]::ReadAllText($review.ReportPath)
Assert-True ($reviewText.Contains('Completed with warnings') -and $reviewText.Contains('No restore command ran')) 'Restore review warns about absent data without claiming a restore.'
$outside=Invoke-SfsuRestoreReview -PackageRoot $testRoot -Backups @([pscustomobject]@{Path=$sourcePath})
Assert-True ([IO.File]::ReadAllText($outside.ReportPath).Contains('id="outcome">Failed')) 'Restore review refuses a folder outside Backups.'

# Same stable directory identity: show a live current name without rewriting historical metadata.
& $module { param($sid) $script:Records[$sid][0].DisplayName='Synthetic New Name' } $domainSid
$renamed=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames
$refreshJournal=[IO.File]::ReadAllText((Join-Path $renamed.RunDirectory 'events.jsonl'))
Assert-True ($refreshJournal.Contains('Default Windows credentials') -and $refreshJournal.Contains('SYNTHETIC-LAPTOP')) 'Current-name refresh also records default authentication context.'
$changed=@($renamed.Backups | Where-Object IdentitySource -eq 'LDAP')[0]
Assert-True ($changed.DisplayName -eq 'Synthetic New Name' -and $changed.FormerName -eq 'Synthetic Person') 'Verified rename produces a formerly-known-as label.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $path 'backup.json')).Hash -eq $manifestHash) 'Name refresh preserves saved identity metadata.'
Assert-True (@($renamed.Backups | Where-Object { $_.IdentitySource -eq 'Manual' -and $_.FormerName }).Count -eq 0) 'Manual names are not presented as verified name changes.'
$upnCredential=New-Object Management.Automation.PSCredential('powertech@example.invalid',$credentialFixture.Password)
$explicitRefresh=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames -Credential $upnCredential
$explicitJournal=[IO.File]::ReadAllText((Join-Path $explicitRefresh.RunDirectory 'events.jsonl'))
Assert-True ($explicitRefresh.DirectoryStatus -eq 'Connected' -and $explicitJournal.Contains('Attempted LDAP account: powertech@example.invalid')) 'Name refresh records explicit UPN credentials and preserves their format.'
Assert-True (-not $explicitJournal.Contains($secretFixture) -and -not [IO.File]::ReadAllText($explicitRefresh.ReportPath).Contains($secretFixture)) 'Name-refresh diagnostics omit the password.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000999' } $domainSid
$idChanged=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames
Assert-True (@($idChanged.Backups | Where-Object FormerName).Count -eq 0) 'An account ID conflict does not produce a name-change claim.'
$broken=Join-Path $testRoot 'Backups/broken-metadata'; [void][IO.Directory]::CreateDirectory($broken); [IO.File]::WriteAllText((Join-Path $broken 'backup.json'),'{truncated')
$invalid=@(Get-SfsuBackupCatalog $testRoot | Where-Object Path -eq $broken)[0]
Assert-True (-not $invalid.MetadataValid -and $invalid.Status -match 'Unreadable') 'Damaged metadata is visible but never trusted.'

# Local accounts participate in preparation/review without ever receiving an SFSU ID.
$localRoot=Join-Path $testRoot 'local-package'; [void][IO.Directory]::CreateDirectory($localRoot)
$onlyLocal=& $module {
    param($root)
    $savedFixtures=$script:Fixtures
    try { $script:Fixtures=@($savedFixtures | Where-Object SID -eq $script:LocalSid); Invoke-SfsuProfileDiscovery -PackageRoot $root }
    finally { $script:Fixtures=$savedFixtures }
} $localRoot
Assert-True ($onlyLocal.Profiles.Count -eq 1 -and -not [IO.File]::ReadAllText((Join-Path $onlyLocal.RunDirectory 'events.jsonl')).Contains('Attempting LDAP connection')) 'A local-only computer requires no LDAP connection during discovery.'
$unknownFolder=$verified.PSObject.Copy(); $unknownFolder.ProfilePath=Join-Path $testRoot 'unexpected-folder-name'
Assert-Throws { Set-SfsuManualIdentity -Profile $unknownFolder -DisplayName 'Cannot Guess' -Confirmed } 'Unexpected nonnumeric domain folders are flagged rather than guessed or manually reidentified.'
Assert-Throws { Set-SfsuManualIdentity -Profile $localProfile -DisplayName '  ' -Confirmed } 'Local accounts also require a nonempty display name.'
$localAssigned=Set-SfsuManualIdentity -Profile $localProfile -DisplayName 'Local Test Person' -Confirmed
Assert-True (-not $localAssigned.SfsuId -and $localAssigned.ManualConfirmed -and -not $localAssigned.DirectorySid) 'Assigning a local display name does not invent domain identity.'
$localPrepared=Invoke-SfsuBackupPreparation -PackageRoot $localRoot -Profiles @($localAssigned)
Assert-True ($localPrepared.Paths.Count -eq 1 -and $localPrepared.Errors.Count -eq 0) 'A local account can prepare its own folder and finalized log snapshot.'
$localBackup=$localPrepared.Paths[0]
Assert-True ((Split-Path $localBackup -Leaf) -match '^Local-local-tech_Local Test Person_.+_\d{8}-\d{6}$') 'Local folder naming includes the actual local account name.'
$localMetadata=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $localBackup 'backup.json')))
Assert-True ($localMetadata.SchemaVersion -eq 2 -and $localMetadata.Identity.AccountType -eq 'Local' -and $localMetadata.SourceProfile.Sid -eq $localSid -and -not $localMetadata.Identity.SfsuId) 'Local metadata records account type, username, and SID separately from SFSU identity.'
$localCatalog=Invoke-SfsuBackupInventory -PackageRoot $localRoot -LookupNames
Assert-True ($localCatalog.Backups[0].MetadataValid -and $localCatalog.Backups[0].AccountName -eq 'local-tech' -and -not [IO.File]::ReadAllText((Join-Path $localCatalog.RunDirectory 'events.jsonl')).Contains('Attempting LDAP connection')) 'Local backups list and refresh offline without LDAP.'
$localReview=Invoke-SfsuRestoreReview -PackageRoot $localRoot -Backups @($localCatalog.Backups[0])
Assert-True ([IO.File]::ReadAllText($localReview.ReportPath).Contains('no migration data exists to restore')) 'Local backups use the same metadata-only restore review safeguards.'
Assert-True (Test-Path -LiteralPath (Join-Path $localPath 'local-sentinel.txt')) 'Local profile content is preserved.'
$legacyFolder=Join-Path $localRoot 'Backups/legacy-domain'; [void][IO.Directory]::CreateDirectory($legacyFolder)
$legacyData=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $path 'backup.json')))
$legacyData.SchemaVersion=1
foreach ($property in @('AccountType','AccountName','SfsuIdSource')) { $legacyData.Identity.PSObject.Properties.Remove($property) }
$legacyFile=Join-Path $legacyFolder 'backup.json'; [IO.File]::WriteAllText($legacyFile,(ConvertTo-Json $legacyData -Depth 8))
$legacyHash=(Get-FileHash $legacyFile).Hash
$legacyRow=@(Get-SfsuBackupCatalog $localRoot | Where-Object Path -eq $legacyFolder)[0]
Assert-True ($legacyRow.MetadataValid -and $legacyRow.AccountType -eq 'Domain' -and $legacyRow.SfsuId -ceq '000000123') 'Version-one domain metadata remains readable without rewriting existing backups.'
Assert-True ((Get-FileHash $legacyFile).Hash -eq $legacyHash) 'Backward-compatible reading preserves original metadata bytes.'
$badLocalFolder=Join-Path $localRoot 'Backups/invalid-local'; [void][IO.Directory]::CreateDirectory($badLocalFolder)
$localMetadata.Identity.SfsuId='000000123'
[IO.File]::WriteAllText((Join-Path $badLocalFolder 'backup.json'),(ConvertTo-Json $localMetadata -Depth 8))
$badLocal=@(Get-SfsuBackupCatalog $localRoot | Where-Object Path -eq $badLocalFolder)[0]
Assert-True (-not $badLocal.MetadataValid) 'A local-account record with a fabricated SFSU ID is not accepted as valid metadata.'

if ($IncludeUi) {
    $uiManualFixture=$manual
    $uiForm=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
    try {
        $uiForm.ShowInTaskbar=$false; $uiForm.StartPosition='Manual'; $uiForm.Location=New-Object Drawing.Point(-30000,-30000)
        $uiForm.Show(); [Windows.Forms.Application]::DoEvents()
        Assert-True ($null -ne $script:SfsuUi.Logo) 'UI header loads the supplied SFSU logo.'
        Set-SfsuProfileRows @($verified,$uiManualFixture)
        Assert-True ($script:SfsuUi.Profiles.Columns['Verified'].Index -eq 2 -and $script:SfsuUi.Profiles.Columns['DisplayName'].Index -eq 3) 'Verified appears between SFSU ID and Name.'
        Assert-True ($script:SfsuUi.Profiles.Columns['Sid'].Index -eq $script:SfsuUi.Profiles.Columns.Count-1 -and $script:SfsuUi.Profiles.Rows[0].Cells['Sid'].Value -eq $domainSid) 'The final column contains the actual profile SID.'
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -ceq ([string][char]0x2705) -and -not $script:SfsuUi.Profiles.Rows[1].Cells['Verified'].Value) 'Only the AD-verified profile receives a check mark; manual identity stays unmarked.'
        foreach ($case in @('sid','id','name','time','conflict')) {
            $notVerified=$verified.PSObject.Copy()
            switch ($case) {
                'sid' { $notVerified.DirectorySid=$localSid }
                'id' { $notVerified.SamAccountName='000000999' }
                'name' { $notVerified.DisplayName=' ' }
                'time' { $notVerified.VerifiedAtUtc='' }
                'conflict' { $notVerified.IdentityStatus='Directory ID conflict' }
            }
            Assert-True (-not (Test-SfsuProfileVerified $notVerified)) ('The check mark requires complete AD verification: '+$case)
        }
        $script:SfsuUi.Profiles.Rows[1].Cells['Selected'].Value=$true
        $script:SfsuUi.Profiles.Sort($script:SfsuUi.Profiles.Columns['DisplayName'],[ComponentModel.ListSortDirection]::Ascending)
        Assert-True (@(Get-SfsuCheckedRows $script:SfsuUi.Profiles)[0].IdentitySource -eq 'Manual') 'Checkbox selections remain attached to the correct profile after sorting.'
        Set-SfsuBackupRows @($catalog.Backups)
        Assert-True ($script:SfsuUi.Backups.Rows[0].Tag.CreatedUtc -ge $script:SfsuUi.Backups.Rows[1].Tag.CreatedUtc) 'UI starts with newest backup first.'
        $script:SfsuUi.Backups.Sort($script:SfsuUi.Backups.Columns['SfsuId'],[ComponentModel.ListSortDirection]::Ascending)
        Assert-True ($script:SfsuUi.Backups.Rows.Count -eq 2) 'Restore columns support sorting without dropping rows.'
        $uiForm.PerformLayout(); [Windows.Forms.Application]::DoEvents()
        Assert-True ($script:SfsuUi.Profiles.Top -ge $backupBar.Bottom -and $prepare.Visible) 'Backup actions remain visible above the profile grid.'
        $bitmap=New-Object Drawing.Bitmap($uiForm.Width,$uiForm.Height)
        try { $uiForm.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot 'app-backup.png')) } finally { $bitmap.Dispose() }
        $script:SfsuUi.Profiles.FirstDisplayedScrollingColumnIndex=$script:SfsuUi.Profiles.Columns['Sid'].Index
        [Windows.Forms.Application]::DoEvents()
        Assert-True ($script:SfsuUi.Profiles.Columns['Sid'].Displayed -and $script:SfsuUi.Profiles.Columns['DisplayName'].Displayed -and $script:SfsuUi.Profiles.Columns['Selected'].Displayed) 'Horizontal scrolling reveals SID while keeping selection and identity columns visible.'
        Assert-True (@($script:SfsuUi.Profiles.Controls | Where-Object { $_ -is [Windows.Forms.HScrollBar] -and $_.Visible }).Count -eq 1) 'The profile grid provides a horizontal scrollbar instead of squeezing the SID.'
        $bitmap=New-Object Drawing.Bitmap($uiForm.Width,$uiForm.Height)
        try { $uiForm.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot 'app-backup-sid.png')) } finally { $bitmap.Dispose() }
        # Switch tabs without firing a live background inventory during fixture rendering.
        $script:SfsuUi.Worker=[PowerShell]::Create()
        $script:SfsuUi.Tabs.SelectedIndex=1
        $script:SfsuUi.Worker.Dispose(); $script:SfsuUi.Worker=$null
        [Windows.Forms.Application]::DoEvents()
        Assert-True ($script:SfsuUi.Backups.Top -ge $restoreBar.Bottom -and $review.Visible) 'Restore actions remain visible above the backup grid.'
        $bitmap=New-Object Drawing.Bitmap($uiForm.Width,$uiForm.Height)
        try { $uiForm.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot 'app-restore.png')) } finally { $bitmap.Dispose() }
        $script:SfsuUi.Root=$testRoot
        function Wait-UiTask {
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            while ($null -ne $script:SfsuUi.Worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(30) }
            if ($null -ne $script:SfsuUi.Worker) { throw 'Background UI task timed out.' }
        }
        Start-SfsuUiTask 'List backups'
        Assert-True (-not $script:SfsuUi.Tabs.Enabled) 'Mutating controls are disabled during asynchronous work.'
        Wait-UiTask
        Assert-True ($script:SfsuUi.Backups.Rows.Count -eq 3 -and $script:SfsuUi.Open.Enabled) 'Asynchronous inventory populates the UI and enables the actual report.'
        $uiProfile=$verified.PSObject.Copy(); $uiProfile.DisplayName='Synthetic UI Person'
        Start-SfsuUiTask 'Prepare folders' @($uiProfile)
        Wait-UiTask
        Assert-True ($script:SfsuUi.Status.Text -match '^1 folders prepared; 0 errors') 'Asynchronous preparation returns a real successful result to the UI.'
        Assert-True ($script:SfsuUi.Tabs.Enabled -and -not $script:SfsuUi.Cancel.Enabled) 'Controls are restored after task completion.'
        # Stop a real unfinished journal in a worker without any live inventory/network access.
        $cancelWorker=[PowerShell]::Create()
        [void]$cancelWorker.AddScript({param($root)
            Import-Module (Join-Path $root 'App/Scripts/Sfsu.Logging.psm1')
            $run=New-SfsuLogRun -PackageRoot $root -Operation RestoreReview -Steps @(@{Id='waiting';Title='Synthetic cancellation validation'})
            Start-SfsuLogStep -Run $run -StepId waiting
            Start-Sleep -Seconds 20
        }.ToString()).AddArgument($testRoot)
        $before=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Logs') -Directory).Count
        $script:SfsuUi.Worker=$cancelWorker; $script:SfsuUi.Pending=$cancelWorker.BeginInvoke(); $script:SfsuUi.Cancelled=$false
        $script:SfsuUi.Cancel.Enabled=$true; $script:SfsuUi.Timer.Start()
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Logs') -Directory).Count -eq $before -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(30) }
        [Threading.Thread]::Sleep(300)
        $script:SfsuUi.Cancel.PerformClick(); Wait-UiTask
        Assert-True ($script:SfsuUi.Status.Text -match 'cancelled') 'UI cancellation stops its worker and releases controls.'
        Assert-True ([IO.File]::ReadAllText($script:SfsuUi.LatestReport).Contains('id="outcome">Incomplete')) 'Cancelled unfinished work retains an Incomplete report.'
        # Exercise modal dialog wiring using synthetic identities and a cancelled credential prompt.
        $manualUiProfile=$verified.PSObject.Copy()
        Set-SfsuProfileRows @($manualUiProfile)
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -ceq ([string][char]0x2705)) 'The manual reassignment fixture starts with a real AD verification mark.'
        $manualTimer=New-Object Windows.Forms.Timer; $manualTimer.Interval=100
        $manualTimer.Add_Tick({
            $testDialogWindow=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assign Display Name')
            if ($testDialogWindow.Count -eq 0) { return }; $manualTimer.Stop()
            $fields=@($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] } | Sort-Object Top)
            if ($fields.Count -ne 1) { throw 'Assign Display Name must ask only for a name.' }
            $fields[0].Text='Synthetic Manual UI'
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }).Checked=$true
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Assign Display Name' }).PerformClick()
        })
        $manualTimer.Start()
        try { Show-SfsuManualIdentity } finally { $manualTimer.Dispose() }
        Assert-True ($manualUiProfile.IdentitySource -eq 'Manual' -and $manualUiProfile.SfsuId -ceq '000000123') 'Assign Display Name preserves the inferred ID and confirms only the name.'
        Assert-True (-not $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value) 'Assigning a name manually clears any AD verification mark.'
        Set-SfsuProfileRows @($localAssigned)
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['SfsuId'].Value -eq 'Local Account') 'Local profiles display Local Account in the SFSU ID column.'
        Assert-True (-not $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -and $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].ToolTipText -match 'does not apply') 'Local classification is not presented as AD verification.'
        $localNameTimer=New-Object Windows.Forms.Timer; $localNameTimer.Interval=100
        $localNameTimer.Add_Tick({
            $window=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assign Display Name')
            if (-not $window.Count) { return }; $localNameTimer.Stop()
            $field=@($window[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })
            $script:LocalNameOnly=($field.Count -eq 1 -and @($window[0].Controls | Where-Object Text -eq 'local-tech').Count -eq 1)
            $field[0].Text='Synthetic Local UI'
            ($window[0].Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }).Checked=$true
            $bitmap=New-Object Drawing.Bitmap($window[0].Width,$window[0].Height)
            try { $window[0].DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot 'assign-local-name.png')) } finally { $bitmap.Dispose() }
            ($window[0].Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Assign Display Name' }).PerformClick()
        })
        $localNameTimer.Start()
        try { Show-SfsuManualIdentity } finally { $localNameTimer.Dispose() }
        Assert-True ($script:LocalNameOnly -and $localAssigned.DisplayName -eq 'Synthetic Local UI' -and -not $localAssigned.SfsuId) 'Local display-name assignment asks only for a name and preserves the local account identity.'
        Set-SfsuBackupRows @($localCatalog.Backups[0])
        Assert-True ($script:SfsuUi.Backups.Rows[0].Cells['SfsuId'].Value -eq 'Local Account' -and $script:SfsuUi.Backups.Rows[0].Cells['AccountName'].Value -eq 'local-tech') 'Restore displays the local-account label and actual username.'
        $script:PasswordMasked=$false
        $credentialTimer=New-Object Windows.Forms.Timer; $credentialTimer.Interval=100
        $credentialTimer.Add_Tick({
            $testCredentialWindow=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Authenticate to Active Directory')
            if ($testCredentialWindow.Count -eq 0) { return }; $credentialTimer.Stop()
            $script:PasswordMasked=@($testCredentialWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.UseSystemPasswordChar }).Count -eq 1
            $testCredentialWindow[0].DialogResult='Cancel'; $testCredentialWindow[0].Close()
        })
        $savedTaskFunction=${function:Start-SfsuUiTask}
        function Start-SfsuUiTask { param($Action,$Items) $script:ManualChoiceAction=$Action }
        $credentialTimer.Start()
        try { Show-SfsuDirectoryCredentials } finally { $credentialTimer.Dispose(); Set-Item function:Start-SfsuUiTask $savedTaskFunction }
        Assert-True $script:PasswordMasked 'Directory credential dialog masks the password field.'
        Assert-True ($null -eq $script:SfsuUi.Credential -and $null -eq $script:SfsuUi.Worker) 'Cancelling credentials neither caches a password nor starts directory access.'
        Assert-True (-not $script:SfsuUi.UseDirectory -and $script:ManualChoiceAction -eq 'Discover profiles') 'Closing startup authentication explicitly chooses manual profile discovery.'
    } finally { $uiForm.Dispose() }
}
Write-Output ("PASS: $script:Assertions assertions on PowerShell " + $PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
