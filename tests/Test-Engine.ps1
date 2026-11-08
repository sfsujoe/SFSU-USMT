# Native-engine integration fixtures. Never executes vendor binaries, inspects
# real profiles, binds AD, or creates/modifies a Windows account.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
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
    $script:FailName=''; $script:CancelOnCapture=$false; $script:WarnCapture=$false; $script:CollideName=''; $script:AccountFailure=$false
    function script:Assert-SfsuMigrationHost([string]$Operation) { [pscustomobject]@{Build=26100;ProductType=1;Version='10.0.26100';Architecture='amd64';Computer='Synthetic'} }
    function script:Get-SfsuToolset([string]$PackageRoot,[string]$Architecture) { [pscustomobject]@{Directory=(Join-Path $script:FixtureRoot 'Toolset');Architecture='amd64';Version='10.0.26100.9457';Files=@()} }
    function script:Get-CimInstance { param($ClassName); $script:Sources | ForEach-Object { [pscustomobject]@{SID=$_.ProfileSid;LocalPath=$_.ProfilePath;Loaded=$_.Loaded;Special=$false} } }
    function script:Get-SfsuDestinationProfiles { $script:Destinations }
    function script:Get-SfsuDestinationProfileRoot { Join-Path $script:FixtureRoot 'Destination' }
    function script:Test-SfsuLocalAccountExists([string]$Name) { $Name -eq $script:CollideName -or $script:Accounts.ContainsKey($Name) }
    function script:New-SfsuRestoreAccount([string]$Name,[Security.SecureString]$Password) {
        if ($script:AccountFailure) { throw 'Synthetic account creation failed.' }
        if ($script:Accounts.ContainsKey($Name)) { throw 'Synthetic account collision.' }
        $script:Accounts[$Name]=[pscustomobject]@{Enabled=$false;Administrator=$false;Sid='S-1-5-21-44-55-66-1001'}
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
            }
        } elseif ($Name -eq 'loadstate.exe') {
            $map=@($Arguments | Where-Object { $_.StartsWith('/mu:') })
            if ($map.Count) { $sid=$script:Accounts['LocalOne'].Sid }
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
Assert-True ($capture.Outcome -eq 'CompletedWithWarnings' -and $capture.Errors.Count -eq 0 -and $capture.Paths.Count -eq 2) 'A synthetic multi-profile capture completes with separate stores and explicit acceptance limitations.'
$catalog=@(Get-SfsuBackupCatalog $root)
Assert-True ($catalog.Count -eq 2 -and @($catalog | Where-Object Status -eq 'Captured - store verified').Count -eq 2) 'Verified native captures have a readable store-verification status in the catalog.'
$manifest=(Read-SfsuBackupManifest $capture.Paths[0]).Data
Assert-True ($manifest.SchemaVersion -eq 4 -and $manifest.HasMigrationData -and $manifest.Engine.VerifyExitCode -eq 0 -and -not $manifest.Engine.EfsDecryptionVerified) 'Metadata records structural verification without inventing EFS decryption evidence.'
$calls=@(& $module { $script:Calls.ToArray() })
$scan=@($calls | Where-Object { $_.Name -eq 'scanstate.exe' -and $_.Label -like 'Capturing*' })
Assert-True ($scan.Count -eq 2 -and @($scan[0].Arguments | Where-Object { $_ -eq '/efs:copyraw' }).Count -eq 1 -and $scan[0].Arguments -contains '/r:2' -and $scan[0].Arguments -contains '/w:3') 'Capture uses native EFS raw preservation and bounded native retries.'
Assert-True (@($calls.Arguments | Where-Object { $_ -match '^/(o|encrypt|key|lac|lae)(:|$)' }).Count -eq 0) 'Capture never overwrites stores, encrypts them or passes account/key secrets.'
$policyPath=Join-Path $capture.Paths[0] 'Policy/SfsuPolicy.xml'; $xml=[xml][IO.File]::ReadAllText($policyPath)
foreach ($extension in @('exe','msi','ost','tmp')) { Assert-True (@($xml.SelectNodes('//unconditionalExclude/objectSet/pattern') | Where-Object InnerText -eq ('* [*.'+$extension+']')).Count -eq 2) ('Unconditional '+$extension+' exclusion applies in both contexts.') }
foreach ($browserFile in @('Bookmarks','History','places.sqlite')) { Assert-True ($xml.OuterXml.Contains('['+$browserFile+']')) ('Browser capture includes '+$browserFile+'.') }
Assert-True ($xml.OuterXml.Contains('CacheStorage') -and $xml.OuterXml.Contains('cache2') -and $xml.OuterXml.Contains('Windows Defender') -and $xml.OuterXml.Contains('OneDrive')) 'Browser caches, Defender and cloud roots have unconditional exclusions.'
$config=[xml][IO.File]::ReadAllText((Join-Path $capture.Paths[0] 'Policy/Config.xml'))
Assert-True ($config.SelectSingleNode('//component[@ID="Windows-Defender-AM-Engine"]').migrate -eq 'no' -and $config.SelectSingleNode('//component[@ID="office16"]').migrate -eq 'yes') 'Generated config disables Defender without changing default Office migration.'
Assert-True ($config.SelectNodes('/Configuration/Policies/ErrorControl/fileError/fatal').Count -eq 2 -and $config.SelectSingleNode('/Configuration/Policies/ErrorControl/fileError/fatal').InnerText -eq '* [*]') 'Disk-full fatal rules use the documented Policies hierarchy and text patterns.'

$plans=@(& $module { param($root,$backups) Get-SfsuRestorePlans $root $backups } $root $catalog)
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
Assert-True ($restore.Outcome -eq 'CompletedWithWarnings' -and $restore.Errors.Count -eq 0) 'Synthetic mixed local/domain restore completes after all-target checks with explicit acceptance limitations.'
$calls=@(& $module { $script:Calls.ToArray() })
$loads=@($calls | Where-Object Name -eq 'loadstate.exe')
Assert-True ($loads.Count -eq 2 -and @($loads | Where-Object { $_.Arguments -match '^/mu:' }).Count -eq 1) 'Only local recreation uses a same-name local mapping; domain identity has no remapping.'
Assert-True (@($loads.Arguments | Where-Object { $_ -match '^/(lac|lae|md)(:|$)' -or $_.Contains('Synthetic-only-Password') }).Count -eq 0) 'No password, /lac, /lae or different-domain mapping enters LoadState arguments.'
Assert-True ((& $module { $script:Accounts['LocalOne'].Enabled }) -and -not (& $module { $script:Accounts['LocalOne'].Administrator })) 'Per-account enabled and standard-user choices are applied after restoration.'
$events=[IO.File]::ReadAllText((Join-Path $restore.RunDirectory 'events.jsonl'))
Assert-True (-not $events.Contains('Synthetic-only-Password!29') -and $events.Contains('Enabled=True; Administrators member=False')) 'Reports record final account choices while excluding the password.'
Assert-True ($events.Contains('EFS-file decryption') -and $events.Contains('CompletedWithWarnings')) 'Successful native/structural checks retain explicit intended-user acceptance limitations.'

# Fresh synthetic destination: fail LoadState after account creation and verify
# disablement, retained source store, no final account-settings application.
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:FailName='loadstate.exe' }
$failed=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($failed.Outcome -eq 'Failed' -and -not (& $module { $script:Accounts['LocalOne'].Enabled }) -and (& $module { $script:Mutations.ToArray() }) -contains 'Disabled:LocalOne') 'Restore failure disables accounts created by this run and preserves partial data.'
Assert-True (Test-Path -LiteralPath (Join-Path $capture.Paths[0] 'Store/USMT/USMT.MIG')) 'Failure never deletes the source store.'
& $module { $script:Destinations=@(); $script:Accounts=@{}; $script:Mutations.Clear(); $script:FailName=''; $script:AccountFailure=$true }
$failed=Invoke-SfsuRestore -PackageRoot $root -Backups $plans
Assert-True ($failed.Outcome -eq 'Failed' -and (& $module { $script:Mutations.Count }) -eq 0) 'A failed account creation never disables an account that this run did not create.'

# Policy corruption blocks restore before any mutation, even when the metadata
# still claims that capture and verification succeeded.
$original=[IO.File]::ReadAllText($policyPath); [IO.File]::WriteAllText($policyPath,$original+'<!-- altered -->')
Assert-Throws { & $module { param($root,$backups) Get-SfsuRestorePlans $root $backups } $root $catalog } 'rules changed' 'A changed policy snapshot is rejected before restore.'
[IO.File]::WriteAllText($policyPath,$original)

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
