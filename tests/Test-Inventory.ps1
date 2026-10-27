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
$sourcePath=Join-Path $testRoot 'synthetic-source'
[void][IO.Directory]::CreateDirectory($sourcePath)
$sentinel=Join-Path $sourcePath 'untouched.txt'; [IO.File]::WriteAllText($sentinel,'SYNTHETIC source data must never be copied or modified.')
$sourceHash=(Get-FileHash -LiteralPath $sentinel).Hash
$domainSid='S-1-5-21-111111-222222-333333-1101'
$localSid='S-1-5-21-444444-555555-666666-1001'
$fixtures=@(
    [pscustomobject]@{SID=$domainSid;LocalPath=$sourcePath;Special=$false;Loaded=$false},
    [pscustomobject]@{SID=$localSid;LocalPath=$sourcePath;Special=$false;Loaded=$false},
    [pscustomobject]@{SID='S-1-5-18';LocalPath=$sourcePath;Special=$true;Loaded=$true},
    [pscustomobject]@{SID='S-1-5-21-111111-222222-333333-1102';LocalPath=(Join-Path $testRoot 'missing');Special=$false;Loaded=$false}
)
& $module {
    param($items,$local)
    $script:Fixtures=$items; $script:LocalSid=$local
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID=$script:LocalSid} }
        $script:Fixtures
    }
} $fixtures $localSid
$profiles=@(Get-SfsuDomainProfiles)
Assert-True ($profiles.Count -eq 1) 'Only existing non-local, nonsystem domain-style profiles are listed.'
Assert-True ($profiles[0].ProfileSid -eq $domainSid) 'Profile SID is preserved independently of the directory name.'
Assert-True ($profiles[0].SfsuId -eq '') 'The directory name is not treated as authoritative account identity.'
& $module {
    param($sid)
    $script:Records=@{ $sid=@([pscustomobject]@{Sid=$sid;SamAccountName='000000123';DisplayName='Synthetic Person';UserPrincipalName='000000123@example.invalid'}) }
    $script:DirectoryFailure=$false
    function script:New-SfsuDirectorySession {
        param($Server,$Credential)
        if ($script:DirectoryFailure) { throw (New-Object DirectoryServices.Protocols.LdapException(81)) }
        $connection=New-Object psobject
        $connection | Add-Member ScriptMethod Dispose {}
        [pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid';Server=$Server}
    }
    function script:Get-SfsuDirectoryRecords {
        param($Session,$Sid)
        if ($script:Records.ContainsKey($Sid)) { $script:Records[$Sid] }
    }
} $domainSid
$discovery=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot
$verified=$discovery.Profiles[0]
Assert-True ($verified.IdentitySource -eq 'LDAP') 'Exact SID lookup resolves identity.'
Assert-True ($verified.SfsuId -ceq '000000123') 'Leading zeros in the SFSU ID are preserved.'
Assert-True ($verified.DisplayName -eq 'Synthetic Person') 'Directory display name is returned.'
$journal=[IO.File]::ReadAllText((Join-Path $discovery.RunDirectory 'events.jsonl'))
Assert-True (-not ($journal -match 'simulated') -and (ConvertFrom-Json ($journal -split "`n")[0]).Data.Sample -eq $false) 'Discovery journal records actual actions without simulated events.'
Assert-True ($journal -match 'ProfileDiscovery') 'Discovery has its own operation label.'
$filter=& $module { param($sid) ConvertTo-SfsuSidFilter $sid } $domainSid
Assert-True ($filter -match '^(\\[0-9a-f]{2})+$') 'SID filter uses binary hex escapes rather than filter text interpolation.'

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
$changed=@($renamed.Backups | Where-Object IdentitySource -eq 'LDAP')[0]
Assert-True ($changed.DisplayName -eq 'Synthetic New Name' -and $changed.FormerName -eq 'Synthetic Person') 'Verified rename produces a formerly-known-as label.'
Assert-True ((Get-FileHash -LiteralPath (Join-Path $path 'backup.json')).Hash -eq $manifestHash) 'Name refresh preserves saved identity metadata.'
Assert-True (@($renamed.Backups | Where-Object { $_.IdentitySource -eq 'Manual' -and $_.FormerName }).Count -eq 0) 'Manual names are not presented as verified name changes.'
& $module { param($sid) $script:Records[$sid][0].SamAccountName='000000999' } $domainSid
$idChanged=Invoke-SfsuBackupInventory -PackageRoot $testRoot -LookupNames
Assert-True (@($idChanged.Backups | Where-Object FormerName).Count -eq 0) 'An account ID conflict does not produce a name-change claim.'
$broken=Join-Path $testRoot 'Backups/broken-metadata'; [void][IO.Directory]::CreateDirectory($broken); [IO.File]::WriteAllText((Join-Path $broken 'backup.json'),'{truncated')
$invalid=@(Get-SfsuBackupCatalog $testRoot | Where-Object Path -eq $broken)[0]
Assert-True (-not $invalid.MetadataValid -and $invalid.Status -match 'Unreadable') 'Damaged metadata is visible but never trusted.'

if ($IncludeUi) {
    $uiManualFixture=$manual
    $uiForm=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
    try {
        $uiForm.ShowInTaskbar=$false; $uiForm.StartPosition='Manual'; $uiForm.Location=New-Object Drawing.Point(-30000,-30000)
        $uiForm.Show(); [Windows.Forms.Application]::DoEvents()
        Assert-True ($null -ne $script:SfsuUi.Logo) 'UI header loads the supplied SFSU logo.'
        Set-SfsuProfileRows @($verified,$uiManualFixture)
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
        $manualUiProfile=$verified.PSObject.Copy(); $manualUiProfile.IdentitySource='Unresolved'; $manualUiProfile.IdentityStatus='Account not found'
        Set-SfsuProfileRows @($manualUiProfile)
        $manualTimer=New-Object Windows.Forms.Timer; $manualTimer.Interval=100
        $manualTimer.Add_Tick({
            $testDialogWindow=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Confirm manual identity')
            if ($testDialogWindow.Count -eq 0) { return }; $manualTimer.Stop()
            $fields=@($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] } | Sort-Object Top)
            $fields[0].Text='000000321'; $fields[1].Text='Synthetic Manual UI'
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] }).Checked=$true
            ($testDialogWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq 'Confirm identity' }).PerformClick()
        })
        $manualTimer.Start()
        try { Show-SfsuManualIdentity } finally { $manualTimer.Dispose() }
        Assert-True ($manualUiProfile.IdentitySource -eq 'Manual' -and $manualUiProfile.SfsuId -ceq '000000321') 'Manual identity dialog applies explicit confirmation to the correct row.'
        $script:PasswordMasked=$false
        $credentialTimer=New-Object Windows.Forms.Timer; $credentialTimer.Interval=100
        $credentialTimer.Add_Tick({
            $testCredentialWindow=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Directory credentials')
            if ($testCredentialWindow.Count -eq 0) { return }; $credentialTimer.Stop()
            $script:PasswordMasked=@($testCredentialWindow[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.UseSystemPasswordChar }).Count -eq 1
            $testCredentialWindow[0].DialogResult='Cancel'; $testCredentialWindow[0].Close()
        })
        $credentialTimer.Start()
        try { Show-SfsuDirectoryCredentials } finally { $credentialTimer.Dispose() }
        Assert-True $script:PasswordMasked 'Directory credential dialog masks the password field.'
        Assert-True ($null -eq $script:SfsuUi.Credential -and $null -eq $script:SfsuUi.Worker) 'Cancelling credentials neither caches a password nor starts directory access.'
    } finally { $uiForm.Dispose() }
}
Write-Output ("PASS: $script:Assertions assertions on PowerShell " + $PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
