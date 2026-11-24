# Native-engine integration fixtures. Never executes vendor binaries, inspects
# real profiles, binds AD, or creates/modifies a Windows account.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap { [Console]::Error.WriteLine($_.ScriptStackTrace); break }
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/engine-'+[guid]::NewGuid().ToString('N').Substring(0,8))
foreach ($directory in @('App/Reporting','App/Assets','Toolset','Profiles','Destination')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $directory)) }
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $root 'App/Reporting/report.template.html')
foreach ($name in @('MigApp.xml','MigDocs.xml')) { [IO.File]::WriteAllText((Join-Path $root ('Toolset/'+$name)),'<migration urlid="https://example.invalid/test"><component type="Documents" context="User"><displayName>Fixture</displayName><role role="Data"><rules /></role></component></migration>') }
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Engine.psm1') -Force -PassThru
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Inventory.psm1') -Force
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Logging.psm1')
Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Policy.psm1')
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Pattern,[string]$Message) { $failure=''; try { & $Action | Out-Null } catch { $failure=$_.Exception.Message }; Assert-True ($failure -match $Pattern) ($Message+'; actual: '+$failure) }
function New-Profile([string]$Name,[int]$Rid,[string]$Type='Local') {
    $path=Join-Path $root ('Profiles/'+$Name); [void][IO.Directory]::CreateDirectory($path)
    $profile=[pscustomobject]@{ProfileSid=('S-1-5-21-11-22-33-'+$Rid);ProfilePath=$path;Loaded=$false;AccountType=$Type;AccountName=$Name;SfsuId='';DisplayName=('Synthetic '+$Name);SfsuIdSource='NotApplicable';SfsuIdAttribute='';DirectorySid='';SamAccountName='';UserPrincipalName='';IdentitySource='Manual';IdentityStatus='Manually entered';VerifiedAtUtc='';ManualConfirmed=$true}
    if ($Type -eq 'Domain') { $profile.AccountName=''; $profile.SfsuId='Alpha-'+$Name; $profile.SfsuIdSource='Manual' }
    $profile
}
function New-Review($Profile) { [pscustomobject]@{Profile=$Profile;CloudRoots=@([pscustomobject]@{Path=(Join-Path $Profile.ProfilePath 'OneDrive');Source='fixture'});BrowserRoots=@();RedirectedFolders=@();Issues=@();Reviewed=$true;AdditionalCloudRoots=@();AdditionalBrowserRoots=@()} }
$local=New-Profile LocalOne 1001; $domain=New-Profile DomainOne 2001 Domain
$reviews=@((New-Review $local),(New-Review $domain))
& $module {
    param($root,$profiles)
    $script:FixtureRoot=$root; $script:Sources=$profiles; $script:Calls=New-Object Collections.Generic.List[object]
    $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations=New-Object Collections.Generic.List[string]
    $script:FailName=''; $script:CancelOnCapture=$false; $script:WarnCapture=$false; $script:CollideName=''; $script:AccountFailure=$false; $script:EmptyFileList=$false
    function script:Assert-SfsuMigrationHost([string]$Operation) { [pscustomobject]@{Build=26100;ProductType=1;Version='10.0.26100';Architecture='amd64';Computer='Synthetic'} }
    function script:Get-SfsuToolset([string]$PackageRoot,[string]$Architecture) { [pscustomobject]@{Directory=(Join-Path $script:FixtureRoot 'Toolset');Architecture='amd64';Version='10.0.26100.9457';Files=@()} }
    function script:Get-CimInstance { param($ClassName); $script:Sources | ForEach-Object { [pscustomobject]@{SID=$_.ProfileSid;LocalPath=$_.ProfilePath;Loaded=$_.Loaded;Special=$false} } }
    function script:Get-SfsuDestinationProfiles { $script:Destinations }
    function script:Get-SfsuDestinationProfileRoot { Join-Path $script:FixtureRoot 'Destination' }
    function script:Test-SfsuLocalAccountExists([string]$Name) { $Name -eq $script:CollideName -or $script:Accounts.ContainsKey($Name) }
    function script:New-SfsuRestoreAccount([string]$Name,[Security.SecureString]$Password) {
        if ($script:AccountFailure) { throw 'Synthetic account creation failed.' }
        if ($script:Accounts.ContainsKey($Name)) { throw 'Synthetic account collision.' }
        $script:Accounts[$Name]=[pscustomobject]@{Enabled=$false;Administrator=$false;Sid=('S-1-5-21-44-55-66-'+(1001+$script:Accounts.Count))}
        $script:Mutations.Add('Created:'+ $Name); $script:Accounts[$Name].Sid
    }
    function script:Disable-SfsuRestoreAccount([string]$Name) { $script:Accounts[$Name].Enabled=$false; $script:Mutations.Add('Disabled:'+ $Name) }
    function script:Set-SfsuRestoreAccountState($Plan,[string]$Sid) {
        $script:Accounts[$Plan.AccountName].Enabled=$Plan.LocalOptions.Enabled; $script:Accounts[$Plan.AccountName].Administrator=$Plan.LocalOptions.Administrator
        $script:Mutations.Add('Final:'+ $Plan.AccountName)
    }
    function script:Invoke-SfsuNativeTool {
        param($Tools,$Name,[string[]]$Arguments,$Run,$StepId,$Label,$Log='',$Progress='',$Control)
        $script:Calls.Add([pscustomobject]@{Name=$Name;Arguments=$Arguments;Label=$Label;Mutations=$script:Mutations.Count})
        Test-SfsuMigrationCancellation $Control
        if ($Name -eq $script:FailName) { throw 'Synthetic native process failure.' }
        if ($Log) { [IO.File]::WriteAllText($Log,'Synthetic native evidence.'); Add-SfsuRawLog $Run ([IO.Path]::GetFileName($Log)) $StepId }
        $config=@($Arguments | Where-Object { $_.StartsWith('/genconfig:') })
        if ($config.Count) {
            [IO.File]::WriteAllText($config[0].Substring(11),'<Configuration><Applications><component displayname="Microsoft Office 16" ID="office16" migrate="yes" /></Applications><WindowsComponents><component ID="capi2-certs" migrate="yes"/><component ID="crypto-keys" migrate="yes"/><component ID="dpapi-keys" migrate="yes"/><component ID="Windows-Defender-AM-Engine" migrate="yes"/></WindowsComponents></Configuration>')
        } elseif ($Name -eq 'scanstate.exe') {
            $estimate=@($Arguments | Where-Object { $_.StartsWith('/p:') })
            if ($estimate.Count) { [IO.File]::WriteAllText($estimate[0].Substring(3),'<PreMigration><storeSize><size clusterSize="4096">12345</size></storeSize></PreMigration>') }
            else {
                if ($script:CancelOnCapture) { $Control.CancelRequested=$true; Test-SfsuMigrationCancellation $Control }
                $directory=Join-Path $Arguments[0] 'USMT'; [void][IO.Directory]::CreateDirectory($directory); [IO.File]::WriteAllText((Join-Path $directory 'USMT.MIG'),'SYNTHETIC STORE - NOT USMT DATA')
                $sid=($Arguments | Where-Object { $_ -match '^/ui:S-1-5-21-\d+-\d+-\d+-\d+$' } | Select-Object -First 1).Substring(4)
                $profile=$script:Sources | Where-Object ProfileSid -eq $sid
                $list=@($Arguments | Where-Object { $_.StartsWith('/listfiles:') })[0].Substring(11)
                $entry=Join-Path $profile.ProfilePath 'Documents\fixture.txt'
                if ($script:EmptyFileList) { $entry='C:\Unselected\fixture.txt' }
                [IO.File]::WriteAllText($list,$entry)
            }
        } elseif ($Name -eq 'loadstate.exe') {
            $map=@($Arguments | Where-Object { $_.StartsWith('/mu:') })
            if ($map.Count) { $name=(($map[0].Substring(4) -split ':',2)[1] -split '\\')[-1]; $sid=$script:Accounts[$name].Sid }
            else { $sid=($Arguments | Where-Object { $_ -match '^/ui:S-1-5-21-\d+-\d+-\d+-\d+$' } | Select-Object -First 1).Substring(4) }
            $script:Destinations+=([pscustomobject]@{SID=$sid;LocalPath=(Join-Path $script:FixtureRoot ('Destination/'+$sid));Loaded=$false})
        }
        $warn=$script:WarnCapture -and $Name -eq 'scanstate.exe' -and -not $config.Count
        if ($warn) { Write-SfsuLogEvent -Run $Run -StepId $StepId -Severity WARNING -Message 'Synthetic native warning.' }
        [pscustomobject]@{ExitCode=0;HasWarnings=$warn;ErrorLines=0;WarningLines=0;NonFatalRecords=0}
    }
} $root @($local,$domain)

$ruleArgs=@(& $module { Get-SfsuRuleArguments C:\rules })
Assert-True ($ruleArgs.Count -eq 4 -and @($ruleArgs | Where-Object { $_ -like '*/i:*MigUser*' }).Count -eq 0) 'Exactly MigApp, MigDocs, campus policy and Config are separate native arguments.'
$userArgs=@(& $module { Get-SfsuUserArguments 'S-1-5-21-11-22-33-1001' })
Assert-True ($userArgs.Count -eq 3 -and $userArgs[0] -ceq '/ue:*' -and $userArgs[1] -ceq '/ui:S-1-5-21-11-22-33-1001' -and $userArgs[2] -ceq '/ui:S-1-5-21-11-22-33-1001_Classes') 'Exact SID and Classes filters avoid another RID with a matching prefix.'
Assert-Throws { & $module { Get-SfsuUserArguments '*' } } 'exact source' 'Wildcard user selection is refused.'
$badReview=New-Review $local; $badReview.Reviewed=$false
Assert-Throws { New-SfsuMigrationPolicy (Join-Path $root 'bad.xml') $badReview $root } 'Review cloud' 'Unreviewed cloud locations block policy generation.'
Assert-Throws { Set-SfsuCaptureLocations $badReview 'C:\' '' $true } 'whole volume' 'Whole-volume exclusions are refused.'
Assert-Throws { Set-SfsuCaptureLocations $badReview '' 'Unknown|C:\data' $true } 'Edge' 'Unknown browser identifiers are refused.'
Assert-Throws { Set-SfsuCaptureLocations $badReview '' '' $false } 'Confirm' 'Cloud review cannot be skipped.'
Set-SfsuCaptureLocations $badReview 'D:\Cloud & Files' 'Chrome|D:\Browser Profiles' $true | Out-Null
Assert-True ($badReview.Reviewed -and $badReview.AdditionalCloudRoots.Count -eq 1 -and $badReview.AdditionalBrowserRoots[0].Browser -eq 'Chrome') 'Per-profile custom cloud/browser paths retain exact literal locations.'

$capture=Invoke-SfsuCapture -PackageRoot $root -Reviews $reviews
Assert-True ($capture.Outcome -eq 'Completed' -and $capture.Errors.Count -eq 0 -and $capture.Paths.Count -eq 2) 'A clean synthetic multi-profile capture completes without routine acceptance warnings.'
$catalog=@(Get-SfsuBackupCatalog $root)
Assert-True ($catalog.Count -eq 2 -and @($catalog | Where-Object Status -eq 'Captured - store verified').Count -eq 2) 'Verified native captures have a readable store-verification status in the catalog.'
$manifest=(Read-SfsuBackupManifest $capture.Paths[0]).Data
Assert-True ($manifest.SchemaVersion -eq 4 -and $manifest.HasMigrationData -and $manifest.Engine.VerifyExitCode -eq 0 -and -not $manifest.Engine.EfsDecryptionVerified) 'Metadata records structural verification without inventing EFS decryption evidence.'
Assert-True ($manifest.Engine.Inclusion.Confirmed -and $manifest.Engine.Inclusion.ProfileFileCount -eq 1 -and $manifest.Engine.Inclusion.SourceSid -eq $local.ProfileSid) 'Positive selected-profile file evidence is saved separately from store integrity.'
$calls=@(& $module { $script:Calls.ToArray() })
$scan=@($calls | Where-Object { $_.Name -eq 'scanstate.exe' -and $_.Label -like 'Capturing*' })
Assert-True ($scan.Count -eq 2 -and @($scan[0].Arguments | Where-Object { $_ -eq '/efs:copyraw' }).Count -eq 1 -and $scan[0].Arguments -contains '/r:2' -and $scan[0].Arguments -contains '/w:3') 'Capture uses native EFS raw preservation and bounded native retries.'
Assert-True (@($calls.Arguments | Where-Object { $_ -match '^/(o|encrypt|key|lac|lae)(:|$)' }).Count -eq 0) 'Capture never overwrites stores, encrypts them or passes account/key secrets.'
$policyPath=Join-Path $capture.Paths[0] 'Policy/SfsuPolicy.xml'; $xml=[xml][IO.File]::ReadAllText($policyPath)
foreach ($extension in @('exe','msi','ost','tmp')) { Assert-True (@($xml.SelectNodes('//unconditionalExclude/objectSet/script') | Where-Object InnerText -eq ('MigXmlHelper.GenerateDrivePatterns("* [*.'+$extension+']", "Fixed")')).Count -eq 2) ('Fixed-drive '+$extension+' exclusion applies in both contexts.') }
foreach ($browserFile in @('Bookmarks','History','places.sqlite')) { Assert-True ($xml.OuterXml.Contains('['+$browserFile+']')) ('Browser capture includes '+$browserFile+'.') }
Assert-True ($xml.OuterXml.Contains('CacheStorage') -and $xml.OuterXml.Contains('cache2') -and $xml.OuterXml.Contains('Windows Defender') -and $xml.OuterXml.Contains('OneDrive')) 'Browser caches, Defender and cloud roots have unconditional exclusions.'
$config=[xml][IO.File]::ReadAllText((Join-Path $capture.Paths[0] 'Policy/Config.xml'))
Assert-True ($config.SelectSingleNode('//component[@ID="Windows-Defender-AM-Engine"]').migrate -eq 'no' -and $config.SelectSingleNode('//component[@ID="office16"]').migrate -eq 'yes') 'Generated config disables Defender without changing default Office migration.'
Assert-True ($config.SelectNodes('/Configuration/Policies/ErrorControl/fileError/fatal').Count -eq 2 -and $config.SelectSingleNode('/Configuration/Policies/ErrorControl/fileError/fatal').InnerText -eq '* [*]') 'Disk-full fatal rules use the documented Policies hierarchy and text patterns.'

$plans=@(& $module { param($root,$backups) Get-SfsuRestorePlans $root $backups } $root $catalog)
$localPlan=@($plans | Where-Object AccountType -eq 'Local')[0]
$domainPlan=@($plans | Where-Object AccountType -eq 'Domain')[0]
$secure=[Net.NetworkCredential]::new('','Synthetic-only-Password!29').SecurePassword
foreach ($plan in $plans) { if ($plan.AccountType -eq 'Local') { $plan.LocalOptions=[pscustomobject]@{Password=$secure;Enabled=$true;Administrator=$false} } }
& $module { $script:CollideName='LocalOne' }
$before=(& $module { $script:Calls.Count })
$blocked=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($blocked.Outcome -eq 'Failed' -and (& $module { $script:Mutations.Count }) -eq 0 -and (& $module { $script:Calls.Count }) -eq $before) 'Any existing local account stops the entire batch before verification, provisioning or LoadState.'
& $module { $script:CollideName='' }
$collisionFolder=Join-Path $root 'Destination/DomainOne'; [void][IO.Directory]::CreateDirectory($collisionFolder)
$blocked=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($blocked.Outcome -eq 'Failed' -and (& $module { $script:Mutations.Count }) -eq 0) 'A domain-profile folder collision also stops all local/domain targets before changes.'
# Remove only the exact empty synthetic collision folder that this test created.
[IO.Directory]::Delete($collisionFolder,$false)
& $module { $script:FailName='usmtutils.exe' }
$blocked=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($blocked.Outcome -eq 'Failed' -and (& $module { $script:Mutations.Count }) -eq 0) 'Failed pre-restore store verification prevents every account/data mutation.'
& $module { $script:FailName='' }
$restore=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($restore.Outcome -eq 'Completed' -and $restore.Errors.Count -eq 0) 'Clean synthetic mixed local/domain restore completes without routine acceptance warnings.'
$calls=@(& $module { $script:Calls.ToArray() })
$loads=@($calls | Where-Object Name -eq 'loadstate.exe')
Assert-True ($loads.Count -eq 2 -and @($loads | Where-Object { $_.Arguments -match '^/mu:' }).Count -eq 1) 'Only local recreation uses a same-name local mapping; domain identity has no remapping.'
Assert-True (@($loads.Arguments | Where-Object { $_ -match '^/(lac|lae|md)(:|$)' -or $_.Contains('Synthetic-only-Password') }).Count -eq 0) 'No password, /lac, /lae or different-domain mapping enters LoadState arguments.'
Assert-True ((& $module { $script:Accounts['LocalOne'].Enabled }) -and -not (& $module { $script:Accounts['LocalOne'].Administrator })) 'Per-account enabled and standard-user choices are applied after restoration.'
$events=[IO.File]::ReadAllText((Join-Path $restore.RunDirectory 'events.jsonl'))
Assert-True (-not $events.Contains('Synthetic-only-Password!29') -and $events.Contains('Enabled=True; Administrators member=False')) 'Reports record final account choices while excluding the password.'
Assert-True (-not $events.Contains('EFS-file decryption') -and -not $events.Contains('"Severity":"WARNING"')) 'Clean results have no unconditional EFS/sign-in acceptance warnings.'
Assert-True ($events.Contains('DisabledAccountCreated') -and $events.Contains('S-1-5-21-44-55-66-1001') -and $events.Contains('ProfileRegistrationConfirmed')) 'Destination SIDs and per-profile stages are durable in the run journal.'

$metadataPath=Join-Path $localPlan.Path 'backup.json'; $originalMetadata=[IO.File]::ReadAllText($metadataPath)
try {
    $older=ConvertFrom-Json $originalMetadata; $older.Engine.PSObject.Properties.Remove('Inclusion')
    [IO.File]::WriteAllText($metadataPath,(ConvertTo-Json $older -Depth 20))
    & $module { $script:Destinations=@(); $script:Accounts=@{} }
    $olderRestore=Invoke-SfsuRestore -PackageRoot $root -Backups @($localPlan)
    Assert-True ($olderRestore.Outcome -eq 'CompletedWithWarnings' -and $olderRestore.Errors.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $olderRestore.RunDirectory 'events.jsonl')).Contains('no saved positive profile-file inclusion evidence')) 'Older schema-four stores remain usable with an honest missing-inclusion-evidence warning.'
    $invalid=ConvertFrom-Json $originalMetadata; $invalid.Engine.Inclusion.SourceSid='S-1-5-21-1-2-3-9999'
    [IO.File]::WriteAllText($metadataPath,(ConvertTo-Json $invalid -Depth 20))
    Assert-Throws { Read-SfsuBackupManifest $localPlan.Path } 'capture-inclusion' 'Saved inclusion evidence cannot claim a different source SID.'
} finally { [IO.File]::WriteAllText($metadataPath,$originalMetadata) }

# Fresh synthetic destination: fail LoadState after account creation and verify
# disablement, retained source store, no final account-settings application.
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:FailName='loadstate.exe' }
$failed=Invoke-SfsuRestore -PackageRoot $root -Backups @($localPlan,$domainPlan)
Assert-True ($failed.Outcome -eq 'Failed' -and -not (& $module { $script:Accounts['LocalOne'].Enabled }) -and (& $module { $script:Mutations.ToArray() }) -contains 'Disabled:LocalOne') 'Restore failure disables accounts created by this run and preserves partial data.'
Assert-True (Test-Path -LiteralPath (Join-Path $capture.Paths[0] 'Store/USMT/USMT.MIG')) 'Failure never deletes the source store.'
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:FailName=''; $script:AccountFailure=$true }
$failed=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($failed.Outcome -eq 'Failed' -and (& $module { $script:Mutations.Count }) -eq 0) 'A failed account creation never disables an account that this run did not create.'

# A first-profile failure must not create the second local account. All source
# stores still verify before the first account mutation.
$secondLocal=New-Profile LocalTwo 4001
& $module { param($profile) $script:Sources+=@($profile); $script:AccountFailure=$false; $script:FailName='' } $secondLocal
$secondCapture=Invoke-SfsuCapture -PackageRoot $root -Reviews @((New-Review $secondLocal))
$secondPlan=@(& $module { param($root,$backups) Get-SfsuRestorePlans $root $backups } $root @([pscustomobject]@{Path=$secondCapture.Paths[0]}))[0]
$secondPlan.LocalOptions=[pscustomobject]@{Password=$secure;Enabled=$false;Administrator=$false}
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:Calls.Clear(); $script:FailName='loadstate.exe' }
$failed=Invoke-SfsuRestore -PackageRoot $root -Backups @($localPlan,$secondPlan)
Assert-True ($failed.Outcome -eq 'Failed' -and -not (& $module { $script:Accounts.ContainsKey('LocalTwo') })) 'Failure of the first restore leaves later local accounts uncreated.'
$verifiedCalls=@(& $module { $script:Calls | Where-Object Name -eq 'usmtutils.exe' })
Assert-True ($verifiedCalls.Count -eq 2 -and @($verifiedCalls | Where-Object Mutations -ne 0).Count -eq 0) 'Both stores verify before any local account is created.'
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:Calls.Clear(); $script:FailName='' }
$twoLocalRestore=Invoke-SfsuRestore -PackageRoot $root -Backups @($localPlan,$secondPlan)
$loads=@(& $module { $script:Calls | Where-Object Name -eq 'loadstate.exe' })
Assert-True ($twoLocalRestore.Outcome -eq 'Completed' -and $loads[0].Mutations -eq 1 -and $loads[1].Mutations -eq 2) 'Each account is created just before its own LoadState, with finalization after apply.'

$emptyProfile=New-Profile EmptyCapture 5001
& $module { param($profile) $script:Sources+=@($profile); $script:EmptyFileList=$true; $script:Calls.Clear() } $emptyProfile
$emptyCapture=Invoke-SfsuCapture -PackageRoot $root -Reviews @((New-Review $emptyProfile))
$emptyManifest=(Read-SfsuBackupManifest $emptyCapture.Paths[0]).Data
Assert-True ($emptyCapture.Outcome -eq 'Failed' -and -not $emptyManifest.HasMigrationData -and @(& $module { $script:Calls | Where-Object Name -eq 'usmtutils.exe' }).Count -eq 0) 'An intact-looking synthetic store with no selected-profile files cannot become accepted migration data.'
& $module { $script:EmptyFileList=$false }

# Policy corruption blocks restore before any mutation, even when the metadata
# still claims that capture and verification succeeded.
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:FailName='' }
$original=[IO.File]::ReadAllText($policyPath); [IO.File]::WriteAllText($policyPath,$original+'<!-- altered -->')
Assert-Throws { & $module { param($root,$backups) Get-SfsuRestorePlans $root $backups } $root $catalog } 'rules changed' 'A changed policy snapshot is rejected before restore.'
[IO.File]::WriteAllText($policyPath,$original)

$warningProfile=New-Profile WarningCapture 6001
& $module { param($profile) $script:Sources=@($profile); $script:WarnCapture=$true } $warningProfile
$warningCapture=Invoke-SfsuCapture -PackageRoot $root -Reviews @((New-Review $warningProfile))
$warningManifest=(Read-SfsuBackupManifest $warningCapture.Paths[0]).Data
Assert-True ($warningCapture.Outcome -eq 'CompletedWithWarnings' -and $warningCapture.Errors.Count -eq 0 -and $warningManifest.Status -eq 'CapturedWithWarnings') 'Operational capture warnings preserve verified data without turning successful completion into failure.'
$warningEvents=Get-Content -LiteralPath (Join-Path $warningCapture.RunDirectory 'events.jsonl') | ForEach-Object { ConvertFrom-Json $_ }
Assert-True ($warningEvents[-1].Data.Outcome -eq 'CompletedWithWarnings') 'The logger derives completed-with-warnings from recorded operational evidence.'
& $module { $script:WarnCapture=$false }

# Cancel during capture: metadata must stay non-restorable and the source sentinel
# must remain intact. A fresh account/profile avoids folder timestamp collisions.
$cancelProfile=New-Profile CancelOne 3001; $sentinel=Join-Path $cancelProfile.ProfilePath 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'preserve source')
& $module { param($profile) $script:Sources=@($profile); $script:AccountFailure=$false; $script:CancelOnCapture=$true } $cancelProfile
$control=[hashtable]::Synchronized(@{CancelRequested=$false;Message='';Percent=-1})
$cancelled=Invoke-SfsuCapture -PackageRoot $root -Reviews @((New-Review $cancelProfile)) -Control $control
Assert-True ($cancelled.Outcome -eq 'Cancelled' -and $cancelled.Paths.Count -eq 1) 'Cooperative cancellation is recorded as Cancelled.'
$cancelManifest=(Read-SfsuBackupManifest $cancelled.Paths[0]).Data
Assert-True ($cancelManifest.Status -eq 'CaptureCancelled' -and -not $cancelManifest.HasMigrationData -and [IO.File]::ReadAllText($sentinel) -eq 'preserve source') 'Cancelled capture keeps its evidence and leaves source content untouched.'
$secure.Dispose()
Write-Output ("PASS: $script:Assertions engine assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
