# Synthetic inventory/directory fixtures; real isolated filesystem operations. No USMT or live LDAP.
[CmdletBinding()]
param([switch]$IncludeUi)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap { [Console]::Error.WriteLine($_.ScriptStackTrace); break }
$repository=Split-Path $PSScriptRoot -Parent
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
    $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message
}
foreach ($source in Get-ChildItem -LiteralPath (Join-Path $repository 'App/Scripts') -File | Where-Object Extension -in @('.ps1','.psm1','.psd1')) {
    $tokens=$null; $problems=$null
    [void][Management.Automation.Language.Parser]::ParseFile($source.FullName,[ref]$tokens,[ref]$problems)
    if ($problems.Count) { throw ($source.Name+': '+($problems.Message -join '; ')) }
    Assert-True ($problems.Count -eq 0) ('Windows PowerShell parser: '+$source.Name)
}
$engineCalls=@(Get-ChildItem -LiteralPath (Join-Path $repository 'App/Scripts') -Filter Sfsu.Inventory.psm1 -File | ForEach-Object {
    $tokens=$null; $problems=$null
    $tree=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$problems)
    $tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '(?i)(scanstate|loadstate|usmtutils)(\.exe)?$'},$true)
})
Assert-True ($engineCalls.Count -eq 0) 'Inventory/preparation does not directly launch USMT; migration uses the supervised engine adapter.'
$testRoot=Join-Path $PSScriptRoot ('.work/inventory-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
foreach ($name in @('Sfsu.Logging.psm1','Sfsu.Inventory.psm1','Sfsu.Identity.psd1','Sfsu.Identity.psm1')) { Copy-Item -LiteralPath (Join-Path $repository "App/Scripts/$name") -Destination (Join-Path $testRoot "App/Scripts/$name") }
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1') -Force
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Inventory.psm1') -Force
$module=Get-Module Sfsu.Inventory
$credentialFixture=[Management.Automation.PSCredential]::new('000000123@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-password-must-not-be-logged-578').SecurePassword)
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
    $script:LocalAccountFixtures=@([pscustomobject]@{SID=$local;Name='local-tech'})
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        $script:CimCalls++
        if ($ClassName -eq 'Win32_UserAccount') { return $script:LocalAccountFixtures }
        $script:Fixtures
    }
    $script:CimCalls=0
} $fixtures $localSid
$profiles=@(Get-SfsuDomainProfiles)
Assert-True ($profiles.Count -eq 1) 'The compatibility domain-only query retains its domain filter.'
Assert-True ($profiles[0].ProfileSid -eq $domainSid) 'Profile SID is preserved independently of the directory name.'
Assert-True (-not $profiles[0].SfsuId -and $profiles[0].SfsuIdSource -eq 'Unavailable') 'Domain IDs are not inferred from profile folder names.'
$allProfiles=@(Get-SfsuProfiles)
$localProfile=@($allProfiles | Where-Object AccountType -eq 'Local')[0]
Assert-True ($allProfiles.Count -eq 2 -and $localProfile.ProfileSid -eq $localSid) 'General discovery includes local and domain user profiles but excludes system/missing profiles.'
Assert-True (-not $localProfile.SfsuId -and $localProfile.AccountName -eq 'local-tech') 'Local SID classification overrides a numeric folder name and preserves the local SAM username.'
# Setup profiles are excluded by exact folder/account name, without hiding
# similarly named ordinary accounts or altering their contents.
$setupPath=Join-Path $testRoot 'DeFaUlTuSeR0'; $renamedSetupPath=Join-Path $testRoot 'setup-remnant'; $neighborPath=Join-Path $testRoot 'defaultuser01'
foreach ($fixturePath in @($setupPath,$renamedSetupPath,$neighborPath)) { [void][IO.Directory]::CreateDirectory($fixturePath) }
$setupSentinel=Join-Path $setupPath 'preserve.txt'; [IO.File]::WriteAllText($setupSentinel,'Synthetic setup profile contents stay untouched.')
$setupSid='S-1-5-21-444444-555555-666666-1002'; $renamedSetupSid='S-1-5-21-444444-555555-666666-1003'; $neighborSid='S-1-5-21-444444-555555-666666-1004'
try {
    & $module {
        param($folder,$renamed,$neighbor,$folderSid,$renamedSid,$neighborSid)
        $script:Fixtures+=@(
            [pscustomobject]@{SID=$folderSid;LocalPath=$folder;Special=$false;Loaded=$false},
            [pscustomobject]@{SID=$renamedSid;LocalPath=$renamed;Special=$false;Loaded=$false},
            [pscustomobject]@{SID=$neighborSid;LocalPath=$neighbor;Special=$false;Loaded=$false}
        )
        $script:LocalAccountFixtures+=@([pscustomobject]@{SID=$renamedSid;Name='DEFAULTUSER0'},[pscustomobject]@{SID=$neighborSid;Name='defaultuser01'})
    } $setupPath $renamedSetupPath $neighborPath $setupSid $renamedSetupSid $neighborSid
    $filteredSetup=@(Get-SfsuProfiles)
    Assert-True (@($filteredSetup | Where-Object ProfileSid -eq $setupSid).Count -eq 0) 'A defaultuser0 folder is excluded case-insensitively even without a surviving SAM account.'
    Assert-True (@($filteredSetup | Where-Object ProfileSid -eq $renamedSetupSid).Count -eq 0) 'The defaultuser0 SAM account is excluded even with a differently named profile folder.'
    Assert-True ($filteredSetup.Count -eq 3 -and @($filteredSetup | Where-Object ProfileSid -eq $neighborSid).Count -eq 1) 'The exact-name filter preserves regular profiles and defaultuser01.'
    Assert-True ([IO.File]::ReadAllText($setupSentinel) -eq 'Synthetic setup profile contents stay untouched.') 'Filtering never modifies the excluded profile.'
} finally {
    & $module { param($items,$sid) $script:Fixtures=$items; $script:LocalAccountFixtures=@([pscustomobject]@{SID=$sid;Name='local-tech'}) } $fixtures $localSid
}
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
$discovery=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
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
Assert-True ($attempts.Count -eq 1 -and $attempts[0].Details.Contains('Explicit directory credentials')) 'Explicit discovery records one LDAP attempt and its credential source.'
Assert-True ($attempts[0].Details.Contains('SYNTHETIC-LAPTOP\LocalAdmin') -and $attempts[0].Details.Contains('not a directory-confirmed identity')) 'Explicit credentials record execution identity without claiming the outbound account is verified.'
Assert-True ([IO.File]::ReadAllText($discovery.ReportPath).Contains('SYNTHETIC-LAPTOP\LocalAdmin')) 'The HTML report includes the attempted authentication context.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000999' } $domainSid
$folderConflict=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
Assert-True ($folderConflict.Profiles[0].SfsuId -ceq '000000999' -and $folderConflict.Profiles[0].IdentitySource -eq 'LDAP') 'A changed account name on the same SID is independent of the older profile folder name.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000123' } $domainSid
$filter=& $module { param($sid) ConvertTo-SfsuSidFilter $sid } $domainSid
Assert-True ($filter -match '^(\\[0-9a-f]{2})+$') 'SID filter uses binary hex escapes rather than filter text interpolation.'

# Record an explicitly supplied account before a failed bind, without secrets.
$secretFixture='SYNTHETIC-password-must-not-be-logged-578'
$credentialFixture=New-Object Management.Automation.PSCredential('000000123@sfsu.edu',(ConvertTo-SecureString $secretFixture -AsPlainText -Force))
Assert-True ((ConvertTo-SfsuLogin ' 000000123 ') -ceq '000000123@sfsu.edu') 'Bare IDs normalize to SFSU Login while preserving leading zeros.'
Assert-True ((ConvertTo-SfsuLogin '000000123@SFSU.EDU') -ceq '000000123@SFSU.EDU') 'A complete login is accepted without appending or rewriting its suffix.'
Assert-True ((ConvertTo-SfsuLogin ' p000000123 ') -ceq 'p000000123@sfsu.edu') 'Prefixed AD sign-in is accepted.'
Assert-True ((ConvertTo-SfsuLogin 'person@sfsu.edu') -ceq 'person@sfsu.edu') 'Alphabetic full logins are accepted.'
foreach ($invalidLogin in @('','000000123@example.invalid','EXAMPLE\tech','12 34','123@sfsu.edu@sfsu.edu','p000000123@example.invalid','p000000123@sfsu.edu@sfsu.edu','p12 34')) {
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
$withoutAd=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture -SkipDirectoryLookup
$manualJournal=[IO.File]::ReadAllText((Join-Path $withoutAd.RunDirectory 'events.jsonl'))
Assert-True ($withoutAd.Profiles.Count -eq 2 -and $withoutAd.Profiles[0].IdentitySource -eq 'Unresolved' -and $withoutAd.DirectoryStatus -match 'skipped') 'Manual mode enumerates both account types without claiming AD identity.'
Assert-True (-not $manualJournal.Contains('Attempting LDAP connection')) 'Manual mode never falls back to default LDAP credentials.'
$authFailure=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
$authEvents=@([IO.File]::ReadAllLines((Join-Path $authFailure.RunDirectory 'events.jsonl')) | ForEach-Object { ConvertFrom-Json $_ })
$authAttempt=@($authEvents | Where-Object Message -Like 'Attempting LDAP connection*')[0]
$authWarning=@($authEvents | Where-Object Message -EQ 'Authentication failed')[0]
Assert-True ($authAttempt.Sequence -lt $authWarning.Sequence) 'Attempt context is persisted before a failed LDAP bind.'
Assert-True ($authAttempt.Details.Contains('Attempted LDAP account: 000000123@sfsu.edu') -and $authAttempt.Details.Contains('Explicit directory credentials')) 'Explicit LDAP account and source are recorded accurately.'
Assert-True ((& $module { $script:LastDirectoryAccount }) -eq $credentialFixture.UserName) 'The recorded explicit account is the credential passed to the connection.'
Assert-True ($authFailure.DirectoryStatus -eq 'Authentication failed') 'Authentication failure retains its original status with account diagnostics.'
$authJournal=[IO.File]::ReadAllText((Join-Path $authFailure.RunDirectory 'events.jsonl'))
$authHtml=[IO.File]::ReadAllText($authFailure.ReportPath)
Assert-True (-not $authJournal.Contains($secretFixture) -and -not $authHtml.Contains($secretFixture) -and -not $authJournal.Contains('System.Security.SecureString')) 'Journals/reports contain account names without passwords or credential objects.'
& $module { $script:DirectoryFailure=$false; $script:WindowsIdentityFailure=$true }
$missingContext=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
Assert-True ($missingContext.DirectoryStatus -eq 'Connected' -and [IO.File]::ReadAllText($missingContext.ReportPath).Contains('Windows execution identity: Unavailable')) 'Unavailable execution-identity diagnostics do not prevent LDAP lookup.'
& $module { $script:WindowsIdentityFailure=$false; $script:DirectoryFailureCode=81 }

& $module { $script:DirectoryFailure=$true }
$offline=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
Assert-True ($offline.Profiles[0].IdentitySource -eq 'Unresolved') 'Unreachable LDAP does not invent identity.'
Assert-True ($offline.DirectoryStatus -eq 'Directory unreachable or timed out') 'Directory unavailability is reported accurately.'
$unresolved=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($offline.Profiles[0])
Assert-True ($unresolved.Paths.Count -eq 0 -and $unresolved.Errors.Count -eq 1) 'Unresolved identity cannot produce a prepared folder.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'Backups'))) 'Unresolved profile did not create a backup folder.'
Assert-Throws { Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId '000000123' -DisplayName 'Manual Person' } 'Manual identity requires explicit confirmation.'
Assert-Throws { Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId "bad`nID" -DisplayName 'Manual Person' -Confirmed } 'Control characters in IDs are rejected.'
$manual=Set-SfsuManualIdentity -Profile $offline.Profiles[0] -SfsuId '000000123' -DisplayName 'Manual Person' -Confirmed
Assert-True ($manual.IdentitySource -eq 'Manual' -and $manual.ManualConfirmed -and -not $manual.DirectorySid) 'Manual identity is labeled and detached from directory verification.'

& $module { param($sid) $script:DirectoryFailure=$false; $script:Records[$sid]=@($script:Records[$sid][0],$script:Records[$sid][0]) } $domainSid
$conflict=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $credentialFixture
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
$renamed=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames -Credential $credentialFixture
$refreshJournal=[IO.File]::ReadAllText((Join-Path $renamed.RunDirectory 'events.jsonl'))
Assert-True ($refreshJournal.Contains('Explicit directory credentials') -and $refreshJournal.Contains('SYNTHETIC-LAPTOP')) 'Current-name refresh records explicit authentication context.'
$changed=@($renamed.Backups | Where-Object IdentitySource -eq 'LDAP')[0]
Assert-True ($changed.DisplayName -eq 'Synthetic New Name' -and $changed.FormerName -eq 'Synthetic Person') 'Verified rename produces a formerly-known-as label.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $path 'backup.json')).Hash -eq $manifestHash) 'Name refresh preserves saved identity metadata.'
Assert-True (@($renamed.Backups | Where-Object { $_.IdentitySource -eq 'Manual' -and $_.FormerName }).Count -eq 0) 'Manual names are not presented as verified name changes.'
$upnCredential=New-Object Management.Automation.PSCredential('000000456@sfsu.edu',$credentialFixture.Password)
$explicitRefresh=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames -Credential $upnCredential
$explicitJournal=[IO.File]::ReadAllText((Join-Path $explicitRefresh.RunDirectory 'events.jsonl'))
Assert-True ($explicitRefresh.DirectoryStatus -eq 'Connected' -and $explicitJournal.Contains('Attempted LDAP account: 000000456@sfsu.edu')) 'Name refresh records explicit UPN credentials and preserves their format.'
Assert-True (-not $explicitJournal.Contains($secretFixture) -and -not [IO.File]::ReadAllText($explicitRefresh.ReportPath).Contains($secretFixture)) 'Name-refresh diagnostics omit the password.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000999' } $domainSid
$idChanged=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames -Credential $credentialFixture
Assert-True (@($idChanged.Backups | Where-Object FormerName).Count -eq 1) 'The same SID supports name refresh after account renaming.'
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
Set-SfsuManualIdentity -Profile $unknownFolder -SfsuId 'AB00123' -DisplayName 'Confirmed Person' -Confirmed | Out-Null
Assert-True ($unknownFolder.SfsuId -ceq 'AB00123' -and $unknownFolder.ManualConfirmed) 'Manual domain ID confirmation is independent of the folder name.'
Assert-Throws { Set-SfsuManualIdentity -Profile $localProfile -DisplayName '  ' -Confirmed } 'Local accounts also require a nonempty display name.'
$localAssigned=Set-SfsuManualIdentity -Profile $localProfile -DisplayName 'Local Test Person' -Confirmed
Assert-True (-not $localAssigned.SfsuId -and $localAssigned.ManualConfirmed -and -not $localAssigned.DirectorySid) 'Assigning a local display name does not invent domain identity.'
$localPrepared=Invoke-SfsuBackupPreparation -PackageRoot $localRoot -Profiles @($localAssigned)
Assert-True ($localPrepared.Paths.Count -eq 1 -and $localPrepared.Errors.Count -eq 0) 'A local account can prepare its own folder and finalized log snapshot.'
$localBackup=$localPrepared.Paths[0]
Assert-True ((Split-Path $localBackup -Leaf) -match '^Local-local-tech_Local Test Person_.+_\d{8}-\d{6}$') 'Local folder naming includes the actual local account name.'
$localMetadata=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $localBackup 'backup.json')))
Assert-True ($localMetadata.SchemaVersion -eq 3 -and $localMetadata.Identity.AccountType -eq 'Local' -and $localMetadata.SourceProfile.Sid -eq $localSid -and -not $localMetadata.Identity.SfsuId) 'Local metadata records account type, username, and SID separately from SFSU identity.'
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
Assert-True (-not $legacyRow.MetadataValid) 'Earlier development metadata is unsupported.'
Assert-True ((Get-FileHash $legacyFile).Hash -eq $legacyHash) 'Unsupported-version reading preserves the original metadata bytes.'
$badLocalFolder=Join-Path $localRoot 'Backups/invalid-local'; [void][IO.Directory]::CreateDirectory($badLocalFolder)
$localMetadata.Identity.SfsuId='000000123'
[IO.File]::WriteAllText((Join-Path $badLocalFolder 'backup.json'),(ConvertTo-Json $localMetadata -Depth 8))
$badLocal=@(Get-SfsuBackupCatalog $localRoot | Where-Object Path -eq $badLocalFolder)[0]
Assert-True (-not $badLocal.MetadataValid) 'A local-account record with a fabricated SFSU ID is not accepted as valid metadata.'

# Power-user identity is distinct from the regular account with the same numeric suffix.
$powerRoot=Join-Path $testRoot 'power-package'; [void][IO.Directory]::CreateDirectory($powerRoot)
$powerPath=Join-Path $testRoot 'p000000123'; [void][IO.Directory]::CreateDirectory($powerPath)
$powerSid='S-1-5-21-111111-222222-333333-1201'
$powerFixture=[pscustomobject]@{SID=$powerSid;LocalPath=$powerPath;Special=$false;Loaded=$false}
$savedFixtures=& $module { $script:Fixtures }
try {
    & $module {
        param($item,$sid)
        $script:Fixtures=@($item)
        $script:Records[$sid]=@([pscustomobject]@{Sid=$sid;SamAccountName='p000000123';DisplayName='Synthetic Power User';UserPrincipalName='p000000123@sfsu.edu'})
    } $powerFixture $powerSid
    $powerDiscovery=Invoke-SfsuProfileDiscovery -PackageRoot $powerRoot -Credential $credentialFixture
    $powerVerified=$powerDiscovery.Profiles[0]
    Assert-True ($powerVerified.SfsuId -ceq 'p000000123' -and $powerVerified.SfsuIdSource -eq 'LDAP') 'Profile discovery retains the full directory account ID.'
    Assert-True ($powerVerified.IdentitySource -eq 'LDAP' -and $powerVerified.DirectorySid -eq $powerSid -and $powerVerified.DisplayName -eq 'Synthetic Power User') 'Exact-SID LDAP verification accepts a matching power-user account and name.'
    foreach ($mismatch in @('sid','name')) {
        & $module {
            param($sid,$kind,$otherSid)
            $record=$script:Records[$sid][0]
            $record.SamAccountName='p000000123'; $record.Sid=$sid; $record.DisplayName='Synthetic Power User'
            switch ($kind) {
                'id' { $record.SamAccountName='000000123' }
                'sid' { $record.Sid=$otherSid }
                'name' { $record.DisplayName=' ' }
            }
        } $powerSid $mismatch $domainSid
        $powerRejected=(Invoke-SfsuProfileDiscovery -PackageRoot $powerRoot -Credential $credentialFixture).Profiles[0]
        Assert-True ($powerRejected.IdentitySource -ne 'LDAP' -and -not $powerRejected.VerifiedAtUtc) ('Power-user verification refuses a mismatching '+$mismatch)
        if ($mismatch -ne 'name') {
            Assert-Throws { Set-SfsuManualIdentity -Profile $powerRejected -DisplayName 'Cannot Bypass' -Confirmed } ('Manual assignment cannot bypass a power-user '+$mismatch+' conflict.')
        }
    }
    & $module { param($sid) $script:Records[$sid][0].Sid=$sid; $script:Records[$sid][0].DisplayName='Synthetic Power User' } $powerSid
    $powerPrepared=Invoke-SfsuBackupPreparation -PackageRoot $powerRoot -Profiles @($powerVerified)
    Assert-True ($powerPrepared.Paths.Count -eq 1 -and $powerPrepared.Errors.Count -eq 0) 'A verified power-user profile can prepare a folder.'
    Assert-True ((Split-Path $powerPrepared.Paths[0] -Leaf) -match '^p000000123_Synthetic Power User_') 'Power-user backup naming preserves the p prefix.'
    $powerManifest=Join-Path $powerPrepared.Paths[0] 'backup.json'
    $powerMetadata=ConvertFrom-Json ([IO.File]::ReadAllText($powerManifest))
    Assert-True ($powerMetadata.Identity.SfsuId -ceq 'p000000123' -and $powerMetadata.Identity.SamAccountName -ceq 'p000000123' -and $powerMetadata.Identity.AccountType -eq 'Domain') 'Saved power-user metadata retains the complete domain account ID.'
    $powerCatalog=Invoke-SfsuBackupInventory -PackageRoot $powerRoot
    Assert-True ($powerCatalog.Backups[0].MetadataValid -and $powerCatalog.Backups[0].SfsuId -ceq 'p000000123') 'Power-user metadata lists offline without losing its prefix.'
    $powerReview=Invoke-SfsuRestoreReview -PackageRoot $powerRoot -Backups @($powerCatalog.Backups[0])
    Assert-True ([IO.File]::ReadAllText($powerReview.ReportPath).Contains('no migration data exists to restore')) 'Power-user restore review retains the preparation-only warning.'
    $powerHash=(Get-FileHash $powerManifest).Hash
    & $module { param($sid) $script:Records[$sid][0].DisplayName='Renamed Power User' } $powerSid
    $powerRenamed=Invoke-SfsuBackupInventory -PackageRoot $powerRoot -LookupNames -Credential $credentialFixture
    Assert-True ($powerRenamed.Backups[0].FormerName -eq 'Synthetic Power User' -and $powerRenamed.Backups[0].DisplayName -eq 'Renamed Power User') 'Current-name refresh verifies a prefixed account ID.'
    & $module { param($sid) $script:Records[$sid][0].SamAccountName='000000123' } $powerSid
    $powerWrongAccount=Invoke-SfsuBackupInventory -PackageRoot $powerRoot -LookupNames -Credential $credentialFixture
    Assert-True ($powerWrongAccount.Backups[0].FormerName -eq 'Synthetic Power User' -and $powerWrongAccount.Backups[0].DisplayName -eq 'Renamed Power User') 'A renamed account with the same SID can supply the current display name.'
    Assert-True ((Get-FileHash $powerManifest).Hash -eq $powerHash) 'Power-user refresh preserves historical metadata.'
    $powerForged=$powerVerified.PSObject.Copy(); $powerForged.SamAccountName='000000123'
    $powerBlocked=Invoke-SfsuBackupPreparation -PackageRoot $powerRoot -Profiles @($powerForged)
    Assert-True ($powerBlocked.Paths.Count -eq 0 -and $powerBlocked.Errors.Count -eq 1) 'Preparation rejects an LDAP identity that drops the power-user prefix.'
    $powerManual=$powerVerified.PSObject.Copy()
    Set-SfsuManualIdentity -Profile $powerManual -DisplayName 'Assigned Power User' -Confirmed | Out-Null
    Assert-True ($powerManual.SfsuId -ceq 'p000000123' -and $powerManual.IdentitySource -eq 'Manual' -and -not $powerManual.DirectorySid) 'Manual name assignment preserves the power-user ID without claiming AD verification.'
    $powerManualPrepared=Invoke-SfsuBackupPreparation -PackageRoot $powerRoot -Profiles @($powerManual)
    Assert-True ($powerManualPrepared.Paths.Count -eq 1 -and $powerManualPrepared.Errors.Count -eq 0) 'Confirmed manual power-user identity can prepare a folder.'
    # A p-prefixed local folder must still be classified by its local SID.
    & $module { param($item,$sid) $script:Fixtures=@([pscustomobject]@{SID=$sid;LocalPath=$item.LocalPath;Special=$false;Loaded=$false}) } $powerFixture $localSid
    $powerLocal=@(Get-SfsuProfiles)[0]
    Assert-True ($powerLocal.AccountType -eq 'Local' -and -not $powerLocal.SfsuId) 'A p-prefixed local profile folder does not imply a domain account.'
} finally { & $module { param($items) $script:Fixtures=$items } $savedFixtures }

# Generalized identities: arbitrary folder names, longer IDs, letters and
# independent directory attributes. Every directory response is synthetic.
$generalFixtures=& $module { $script:Fixtures }
$generalRecords=& $module { $script:Records }
$generalPolicy=& $module { $script:IdentityPolicy.Clone() }
try {
    $caseIndex=0
    foreach ($textId in @('0000000123',(('0'*40)+'123'),('x'*256),'AB00123','pAlpha42','AB.SFSU.000',('ID'+[char]0x03A9+'001'))) {
        $caseIndex++
        $caseRoot=Join-Path $testRoot ('generalized-'+$caseIndex)
        $oldProfilePath=Join-Path $caseRoot 'old-unrelated-folder'
        [void][IO.Directory]::CreateDirectory($oldProfilePath)
        & $module {
            param($sid,$path,$id)
            $script:Fixtures=@([pscustomobject]@{SID=$sid;LocalPath=$path;Special=$false;Loaded=$false})
            $script:Records=@{$sid=@([pscustomobject]@{Sid=$sid;SamAccountName=$id;UserPrincipalName='separate.login@sfsu.edu';DisplayName='Generalized Person'})}
        } $domainSid $oldProfilePath $textId
        $result=Invoke-SfsuProfileDiscovery -PackageRoot $caseRoot -Credential $credentialFixture
        $generalProfile=$result.Profiles[0]
        Assert-True (Test-SfsuProfileVerified $generalProfile) 'Exact-SID verification accepts the generalized ID regardless of the folder name.'
        Assert-True ($generalProfile.SfsuId -ceq $textId -and $generalProfile.UserPrincipalName -eq 'separate.login@sfsu.edu') 'ID text is preserved separately from the full login name.'
        Assert-True ((ConvertTo-SfsuLogin $textId) -ceq ($textId+'@sfsu.edu')) 'Long, alphabetic, dotted and Unicode bare account logins preserve their text.'
        $generalPrepared=Invoke-SfsuBackupPreparation -PackageRoot $caseRoot -Profiles @($generalProfile)
        Assert-True ($generalPrepared.Paths.Count -eq 1 -and $generalPrepared.Errors.Count -eq 0) ('Generalized identities prepare successfully: '+($generalPrepared.Errors -join '; '))
        $generalCatalog=@(Get-SfsuBackupCatalog $caseRoot)
        Assert-True ($generalCatalog.Count -eq 1 -and $generalCatalog[0].MetadataValid -and $generalCatalog[0].SfsuId -ceq $textId) 'Version-three metadata round-trips the full ID even when the folder label is shortened.'
    }
    # Change the configured ID mapping without changing either login attribute.
    & $module { $script:IdentityPolicy.IdAttribute='employeeID' }
    $customId='A/001:alpha'
    & $module {
        param($sid,$id)
        $script:Records[$sid]=@([pscustomobject]@{Sid=$sid;SamAccountName='campus.login';UserPrincipalName='different.login@sfsu.edu';DisplayName='Custom Attribute Person';SfsuId=$id})
    } $domainSid $customId
    $customRoot=Join-Path $testRoot 'custom-attribute'
    [void][IO.Directory]::CreateDirectory($customRoot)
    $customProfile=(Invoke-SfsuProfileDiscovery -PackageRoot $customRoot -Credential $credentialFixture).Profiles[0]
    Assert-True ((Test-SfsuProfileVerified $customProfile) -and $customProfile.SfsuIdAttribute -eq 'employeeID' -and $customProfile.AccountName -eq 'campus.login') 'Configured university ID and Windows account name are independent.'
    $customPrepared=Invoke-SfsuBackupPreparation -PackageRoot $customRoot -Profiles @($customProfile)
    Assert-True ($customPrepared.Paths.Count -eq 1 -and (Split-Path $customPrepared.Paths[0] -Leaf).StartsWith('A-001-alpha_')) 'Only the filesystem label is sanitized.'
    $customManifestPath=Join-Path $customPrepared.Paths[0] 'backup.json'
    $customManifest=[IO.File]::ReadAllText($customManifestPath)
    $customData=ConvertFrom-Json $customManifest
    Assert-True ($customData.Identity.SfsuId -ceq $customId -and $customData.Identity.SamAccountName -eq 'campus.login' -and $customData.Identity.UserPrincipalName -eq 'different.login@sfsu.edu') 'Metadata retains exact separate ID, SAM account and UPN values.'
    & $module { $script:IdentityPolicy.IdAttribute='sAMAccountName' }
    Assert-True (@(Get-SfsuBackupCatalog $customRoot)[0].MetadataValid) 'Saved attribute provenance remains readable after a configuration change.'
    foreach ($oldVersion in @(1,2)) {
        $customData.SchemaVersion=$oldVersion
        [IO.File]::WriteAllText($customManifestPath,(ConvertTo-Json $customData -Depth 8))
        Assert-True (-not @(Get-SfsuBackupCatalog $customRoot)[0].MetadataValid) 'Earlier development versions are refused without conversion or deletion.'
    }
    [IO.File]::WriteAllText($customManifestPath,$customManifest)
    # Exercise the actual LDAP reader, rather than only a resolver mock.
    $tokens=$null; $problems=$null
    $inventoryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'App/Scripts/Sfsu.Inventory.psm1'),[ref]$tokens,[ref]$problems)
    $readerDefinition=$inventoryAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SfsuDirectoryRecords'},$false).Extent.Text
    $sidObject=New-Object Security.Principal.SecurityIdentifier($domainSid)
    $sidBytes=New-Object byte[] $sidObject.BinaryLength; $sidObject.GetBinaryForm($sidBytes,0)
    $attributes=@{sAMAccountName=@('campus.login');userPrincipalName=@('different.login@sfsu.edu');displayName=@('Custom Attribute Person');employeeID=@($customId);objectSid=@(,$sidBytes)}
    $fakeLdap=[pscustomobject]@{Request=$null;Response=[pscustomobject]@{Entries=@([pscustomobject]@{Attributes=$attributes})}}
    $fakeLdap | Add-Member ScriptMethod SendRequest { param($request) $this.Request=$request; $this.Response }
    & $module { $script:IdentityPolicy.IdAttribute='employeeID' }
    $actualRecords=@(& $module {
        param($definition,$connection,$sid)
        . ([scriptblock]::Create($definition))
        Get-SfsuDirectoryRecords -Session ([pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid'}) -Sid $sid
    } $readerDefinition $fakeLdap $domainSid)
    Assert-True ($actualRecords.Count -eq 1 -and $actualRecords[0].SfsuId -ceq $customId -and $actualRecords[0].Sid -eq $domainSid) 'The real LDAP reader reads the configured single-valued attribute and binary SID.'
    Assert-True ($fakeLdap.Request.Attributes.Contains('employeeID') -and $fakeLdap.Request.Filter -notlike '*A/001*' -and $fakeLdap.Request.Filter -match 'objectSid=\\[0-9a-f]') 'Only binary SID enters the search filter; configured ID attributes are requested explicitly.'
    $attributes.employeeID=@('one','two')
    $ambiguousRecords=@(& $module {
        param($definition,$connection,$sid)
        . ([scriptblock]::Create($definition))
        Get-SfsuDirectoryRecords -Session ([pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid'}) -Sid $sid
    } $readerDefinition $fakeLdap $domainSid)
    Assert-True (-not $ambiguousRecords[0].SfsuId) 'A multivalued ID attribute is not guessed.'
    $attributes.Remove('employeeID')
    $missingRecords=@(& $module {
        param($definition,$connection,$sid)
        . ([scriptblock]::Create($definition))
        Get-SfsuDirectoryRecords -Session ([pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid'}) -Sid $sid
    } $readerDefinition $fakeLdap $domainSid)
    Assert-True (-not $missingRecords[0].SfsuId) 'A missing configured attribute is not replaced with an account-name guess.'
    foreach ($badId in @('',('x'*257),"has space","bad`nID",('bad'+[char]0x202E+'ID'))) {
        Assert-True (-not (Test-SfsuIdentityText $badId)) 'Blank, oversized, whitespace and control/format IDs are rejected.'
    }
    Assert-True (Test-SfsuIdentityText ('x'*256)) 'The documented ID text boundary is accepted.'
    Assert-Throws { ConvertTo-SfsuLogin ('x'*257) } 'Oversized account logins are rejected.'
    # Read the real shared policy file with alternate suffixes and malformed data.
    $policyPath=Join-Path $testRoot 'App/Scripts/Sfsu.Identity.psd1'
    $savedPolicy=[IO.File]::ReadAllText($policyPath)
    try {
        [IO.File]::WriteAllText($policyPath,"@{IdAttribute='employeeID';DefaultLoginSuffix='new.example.edu';AllowedLoginSuffixes=@('new.example.edu','sfsu.edu')}")
        $newPolicy=& $module { Get-SfsuIdentityPolicy }
        Assert-True ($newPolicy.IdAttribute -eq 'employeeID' -and $newPolicy.DefaultLoginSuffix -eq 'new.example.edu') 'The shared configuration accepts an alternate ID mapping and login suffix.'
        $identityModule=& $module { Get-Module Sfsu.Identity }
        $savedLoginPolicy=& $identityModule { $script:IdentityPolicy }
        try {
            & $identityModule { param($policy) $script:IdentityPolicy=$policy } $newPolicy
            Assert-True ((ConvertTo-SfsuLogin 'pAlpha') -eq 'pAlpha@new.example.edu' -and (ConvertTo-SfsuLogin 'AB001@sfsu.edu') -eq 'AB001@sfsu.edu') 'Default and alternate allowed suffixes share the centralized normalization.'
        } finally { & $identityModule { param($policy) $script:IdentityPolicy=$policy } $savedLoginPolicy }
        foreach ($invalidPolicy in @("@{IdAttribute='employeeID)(x=*';DefaultLoginSuffix='sfsu.edu';AllowedLoginSuffixes=@('sfsu.edu')}","@{IdAttribute='employeeID';DefaultLoginSuffix='other.invalid';AllowedLoginSuffixes=@('sfsu.edu')}",'@{ broken')) {
            [IO.File]::WriteAllText($policyPath,$invalidPolicy)
            Assert-Throws { & $module { Get-SfsuIdentityPolicy } } 'Malformed or inconsistent identity configuration fails closed.'
        }
    } finally { [IO.File]::WriteAllText($policyPath,$savedPolicy) }
} finally {
    & $module { param($items,$records,$policy) $script:Fixtures=$items; $script:Records=$records; $script:IdentityPolicy=$policy } $generalFixtures $generalRecords $generalPolicy
}

if ($IncludeUi) {
    $uiManualFixture=$manual
    $uiForm=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
    try {
        $uiForm.ShowInTaskbar=$false; $uiForm.StartPosition='Manual'; $uiForm.Location=New-Object Drawing.Point(-30000,-30000)
        $uiForm.Show(); [Windows.Forms.Application]::DoEvents()
        Assert-True ($null -ne $script:SfsuUi.Logo) 'UI header loads the supplied SFSU logo.'
        Set-SfsuProfileRows @($powerVerified,$powerManual)
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['SfsuId'].Value -ceq 'p000000123' -and $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -ceq (([string][char]0x2705)+' AD verified')) 'The grid shows the full power-user ID and AD verification text/mark.'
        Assert-True (-not $script:SfsuUi.Profiles.Rows[1].Cells['Verified'].Value -and -not (Test-SfsuProfileVerified $powerForged)) 'Manual or prefix-mismatched power-user identities stay unverified in the UI.'
        Set-SfsuProfileRows @($verified,$uiManualFixture)
        Assert-True ($script:SfsuUi.Profiles.Columns['Verified'].Index -eq 2 -and $script:SfsuUi.Profiles.Columns['DisplayName'].Index -eq 3) 'Verified appears between SFSU ID and Name.'
        Assert-True ($script:SfsuUi.Profiles.Columns['Sid'].Index -eq $script:SfsuUi.Profiles.Columns.Count-1 -and $script:SfsuUi.Profiles.Rows[0].Cells['Sid'].Value -eq $domainSid) 'The final column contains the actual profile SID.'
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -ceq (([string][char]0x2705)+' AD verified') -and -not $script:SfsuUi.Profiles.Rows[1].Cells['Verified'].Value) 'Only the AD-verified profile receives text/check mark; manual identity stays unmarked.'
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
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -ceq (([string][char]0x2705)+' AD verified')) 'The manual reassignment fixture starts with AD verification text/mark.'
        $manualTimer=New-Object Windows.Forms.Timer; $manualTimer.Interval=100
        $manualTimer.Add_Tick({
            $testDialogWindow=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assign Display Name')
            if ($testDialogWindow.Count -eq 0) { return }; $manualTimer.Stop()
            $fields=@($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] } | Sort-Object Top)
            if ($fields.Count -ne 2) { throw 'Manual domain identity requires ID and name fields.' }
            $fields[0].Text='AB00123'; $fields[1].Text='Synthetic Manual UI'
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }).Checked=$true
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Assign Display Name' }).PerformClick()
        })
        $manualTimer.Start()
        try { Show-SfsuManualIdentity } finally { $manualTimer.Dispose() }
        Assert-True ($manualUiProfile.IdentitySource -eq 'Manual' -and $manualUiProfile.SfsuId -ceq 'AB00123') 'Manual identity accepts an explicitly confirmed alphabetic ID and display name in the actual dialog.'
        Assert-True (-not $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value) 'Assigning a name manually clears any AD verification mark.'
        Set-SfsuProfileRows @($localAssigned)
        Assert-True ($script:SfsuUi.Profiles.Rows[0].Cells['SfsuId'].Value -eq 'Local Account') 'Local profiles display Local Account in the SFSU ID column.'
        Assert-True (-not $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].Value -and $script:SfsuUi.Profiles.Rows[0].Cells['Verified'].ToolTipText -match 'does not apply') 'Local classification is not presented as AD verification.'
        $localNameTimer=New-Object Windows.Forms.Timer; $localNameTimer.Interval=100
        $localNameTimer.Add_Tick({
            $window=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assign Display Name')
            if (-not $window.Count) { return }; $localNameTimer.Stop()
            $field=@($window[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })
            $script:LocalNameOnly=(@($field | Where-Object { -not $_.ReadOnly }).Count -eq 1 -and @($field | Where-Object Text -eq 'local-tech').Count -eq 1)
            ($field | Where-Object { -not $_.ReadOnly }).Text='Synthetic Local UI'
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
