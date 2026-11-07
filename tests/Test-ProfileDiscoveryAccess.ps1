# Windows PowerShell 5.1. All account/LDAP records are synthetic. ACL changes
# are limited to two new fixture directories and restored in finally.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/profile-access-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
foreach ($name in @('Sfsu.Logging.psm1','Sfsu.Inventory.psm1','Sfsu.Identity.psd1','Sfsu.Identity.psm1')) { Copy-Item -LiteralPath (Join-Path $repository ('App/Scripts/'+$name)) -Destination (Join-Path $testRoot 'App/Scripts') }
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1') -Force
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Inventory.psm1') -Force
$inventory=Get-Module Sfsu.Inventory
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message }
$localPath=Join-Path $testRoot 'local-restricted'
$powerPath=Join-Path $testRoot 'p000000123'
foreach ($path in @($localPath,$powerPath)) {
    # Verify the resolved target is within the new fixture before changing ACLs.
    if (-not [IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($testRoot)+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'ACL fixture escaped its workspace.' }
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'preserve.txt'),'Synthetic source contents stay unchanged.')
}
$localSid='S-1-5-21-444444-555555-666666-1001'
$powerSid='S-1-5-21-111111-222222-333333-1101'
& $inventory {
    param($localPath,$powerPath,$localSid,$powerSid)
    $script:AccessFixtures=@(
        [pscustomobject]@{SID=$localSid;LocalPath=$localPath;Special=$false;Loaded=$true},
        [pscustomobject]@{SID=$powerSid;LocalPath=$powerPath;Special=$false;Loaded=$false})
    $script:AccessLocalSid=$localSid
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID=$script:AccessLocalSid;Name='local-restricted'} }
        $script:AccessFixtures
    }
} $localPath $powerPath $localSid $powerSid
$saved=@{}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try { $principal=$identity.User } finally { $identity.Dispose() }
try {
    foreach ($path in @($localPath,$powerPath)) {
        $acl=Get-Acl -LiteralPath $path; $saved[$path]=$acl.GetSecurityDescriptorSddlForm('All')
        $deny=[Security.AccessControl.FileSystemAccessRule]::new($principal,[Security.AccessControl.FileSystemRights]::ListDirectory,[Security.AccessControl.AccessControlType]::Deny)
        [void]$acl.AddAccessRule($deny); Set-Acl -LiteralPath $path -AclObject $acl
        Assert-Throws { Assert-SfsuSafePath $path } 'The write guard reproduces the original failure on a directory without list permission.'
    }
    $profiles=@(Get-SfsuProfiles)
    Assert-True ($profiles.Count -eq 2) 'Read-only discovery keeps both restricted local and p-account profiles.'
    $local=@($profiles | Where-Object AccountType -eq 'Local')[0]
    $power=@($profiles | Where-Object AccountType -eq 'Domain')[0]
    Assert-True ($local.ProfileSid -eq $localSid -and $local.AccountName -eq 'local-restricted' -and -not $local.SfsuId) 'Restricted local profiles retain local SAM identity.'
    Assert-True ($power.ProfileSid -eq $powerSid -and -not $power.SfsuId) 'Restricted domain profiles retain their SID without guessing IDs.'
    Assert-True ($local.PathAccessStatus -eq 'Ready' -and $power.PathAccessStatus -eq 'Ready') 'Metadata checks succeed without requiring file-list access.'
    $discovery=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -SkipDirectoryLookup
    Assert-True ($discovery.Profiles.Count -eq 2 -and $discovery.DirectoryStatus -match 'skipped') 'Manual discovery lists both profiles without an AD connection.'
    Set-SfsuManualIdentity -Profile $local -DisplayName 'Synthetic Local' -Confirmed | Out-Null
    Set-SfsuManualIdentity -Profile $power -SfsuId 'p000000123' -DisplayName 'Synthetic Power' -Confirmed | Out-Null
    $prepared=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($local,$power)
    Assert-True ($prepared.Paths.Count -eq 2 -and $prepared.Errors.Count -eq 0) 'Metadata-only preparation does not require listing the source files.'
    # Simulate a stronger metadata-access denial without changing more ACLs.
    & $inventory {
        param($path)
        $script:MetadataDeniedPath=$path
        function script:Get-SfsuProfilePathAttributes {
            param($Path)
            if ($Path -eq $script:MetadataDeniedPath) { throw [UnauthorizedAccessException]::new('Synthetic metadata denial.') }
            [IO.File]::GetAttributes($Path)
        }
    } $powerPath
    $uncertain=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -SkipDirectoryLookup
    $retained=@($uncertain.Profiles | Where-Object ProfileSid -eq $powerSid)[0]
    Assert-True ($uncertain.Profiles.Count -eq 2 -and $retained.PathAccessStatus -eq 'AccessUnverified') 'An inaccessible source remains visible with access explicitly unverified.'
    $journal=[IO.File]::ReadAllText((Join-Path $uncertain.RunDirectory 'events.jsonl'))
    Assert-True ($journal.Contains('Source directory metadata access could not be verified; profile remains listed.') -and -not $journal.Contains('Excluded profiles: Linked')) 'Access denial is logged accurately, rather than mislabeled as a link.'
    $refused=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($retained)
    Assert-True ($refused.Paths.Count -eq 0 -and $refused.Errors.Count -eq 1) 'Preparation requires verified source metadata when access is unknown.'
    Assert-True ((ConvertTo-SfsuLogin 'p000000123') -eq 'p000000123@sfsu.edu') 'Prefixed logins are supported.'
} finally {
    foreach ($path in $saved.Keys) {
        $restored=[Security.AccessControl.DirectorySecurity]::new(); $restored.SetSecurityDescriptorSddlForm($saved[$path])
        Set-Acl -LiteralPath $path -AclObject $restored
    }
}
foreach ($path in @($localPath,$powerPath)) { Assert-True ([IO.File]::ReadAllText((Join-Path $path 'preserve.txt')) -eq 'Synthetic source contents stay unchanged.') 'Profile contents are preserved.' }
$sourceLink=Join-Path $testRoot 'source-link'
[void](New-Item -ItemType Junction -Path $sourceLink -Target $localPath)
& $inventory { param($p) $script:AccessFixtures+=[pscustomobject]@{SID='S-1-5-21-111111-222222-333333-1102';LocalPath=$p;Special=$false;Loaded=$false} } $sourceLink
$linked=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -SkipDirectoryLookup
Assert-True ($linked.Profiles.Count -eq 2 -and [IO.File]::ReadAllText((Join-Path $linked.RunDirectory 'events.jsonl')).Contains('Excluded profiles: Linked profile directory or ancestor; count=1')) 'Confirmed source junctions remain excluded with an accurate reason.'
$linkedProfile=$local.PSObject.Copy(); $linkedProfile.ProfilePath=$sourceLink
$linkedPreparation=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($linkedProfile)
Assert-True ($linkedPreparation.Paths.Count -eq 0 -and $linkedPreparation.Errors.Count -eq 1) 'Metadata-only preparation still refuses a confirmed linked source.'
Write-Output ("PASS: $script:Assertions profile-access assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
