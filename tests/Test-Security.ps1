# Windows PowerShell 5.1. Synthetic credentials/files, no live LDAP or USMT.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/security-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
foreach ($file in Get-ChildItem (Join-Path $repository 'App/Scripts') -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $testRoot 'App/Scripts') }
Copy-Item -LiteralPath (Join-Path $repository 'App/Reporting/report.template.html') -Destination (Join-Path $testRoot 'App/Reporting/report.template.html')
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Assets'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Assets/SFSU Logo.png') -Destination (Join-Path $testRoot 'App/Assets/SFSU Logo.png')
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1') -Force
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Inventory.psm1') -Force
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Maintenance.psm1') -Force
$inventory=Get-Module Sfsu.Inventory
$logger=Get-Module Sfsu.Logging
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message }
$standard=[Management.Automation.PSCredential]::new('000000123@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-ONLY').SecurePassword)
foreach ($name in @('p000000123','p000000123@sfsu.edu','P000000123@SFSU.EDU','AB00123')) {
    Assert-True ((ConvertTo-SfsuLogin $name) -like '*@sfsu.edu') ('Generalized AD login accepted: '+$name)
    $powerCredential=[Management.Automation.PSCredential]::new($name,$standard.Password)
    $candidate=& $inventory { param($c) New-SfsuLdapConnection 'ad.sfsu.edu' $c } $powerCredential
    try { Assert-True ($candidate.AuthType -eq 'Kerberos') 'Generalized credentials retain Kerberos without binding.' } finally { $candidate.Dispose() }
}
Assert-Throws { & $inventory { New-SfsuLdapConnection 'ad.sfsu.edu' $null } } 'Explicit credential policy is retained.'
$connection=& $inventory { param($c) New-SfsuLdapConnection 'ad.sfsu.edu' $c } $standard
try {
    Assert-True ($connection.AuthType -eq 'Kerberos' -and $connection.SessionOptions.Signing -and $connection.SessionOptions.Sealing) 'Real connection configuration requires Kerberos, signing and sealing without contacting AD.'
    Assert-True ($connection.SessionOptions.ReferralChasing -eq 'None') 'Referral chasing remains disabled.'
} finally { $connection.Dispose() }
$uiSource=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Sfsu.Ui.ps1'))
Assert-True ($uiSource -notmatch 'ConvertTo-SecureString\s+\$s.Password.Text' -and $uiSource.Contains("[Net.NetworkCredential]::new('', `$s.Password.Text).SecurePassword")) 'Password input is never passed through the plaintext conversion cmdlet.'

# SID-first resolution retains prefixed profiles, including Windows suffixes.
$sid='S-1-5-21-111111-222222-333333-1101'
$localSid='S-1-5-21-444444-555555-666666-1001'
$profilePath=Join-Path $testRoot 'p000000123.SFSU.000'
[void][IO.Directory]::CreateDirectory($profilePath)
& $inventory {
    param($path,$sid,$local)
    $script:SecurityPath=$path; $script:SecuritySid=$sid; $script:SecurityLocal=$local; $script:SecurityQueries=0
    function script:Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        if ($ClassName -eq 'Win32_UserAccount') { return [pscustomobject]@{SID=$script:SecurityLocal;Name='local-test'} }
        [pscustomobject]@{SID=$script:SecuritySid;LocalPath=$script:SecurityPath;Special=$false;Loaded=$false}
        [pscustomobject]@{SID='S-1-12-1-1-2-3-4';LocalPath=$script:SecurityPath;Special=$false;Loaded=$false}
    }
    function script:New-SfsuDirectorySession {
        param($Server,$Credential)
        $fake=New-Object psobject; $fake | Add-Member ScriptMethod Dispose {}
        [pscustomobject]@{Connection=$fake;Server=$Server;SearchBase='DC=example,DC=invalid'}
    }
    function script:Get-SfsuDirectoryRecords {
        param($Session,$Sid)
        $script:SecurityQueries++
        [pscustomobject]@{Sid=$Sid;SamAccountName='p000000123';DisplayName='Synthetic Power Profile';UserPrincipalName='p000000123@sfsu.edu'}
    }
} $profilePath $sid $localSid
$discovery=Invoke-SfsuProfileDiscovery -PackageRoot $testRoot -Credential $standard
$profile=$discovery.Profiles[0]
Assert-True ($discovery.Profiles.Count -eq 1 -and $profile.SfsuId -ceq 'p000000123' -and $profile.IdentitySource -eq 'LDAP') 'Standard credentials verify a p-account profile with a Windows domain/collision suffix.'
Assert-True ([IO.File]::ReadAllText((Join-Path $discovery.RunDirectory 'events.jsonl')).Contains('Unsupported account SID (including Entra profiles); count=1')) 'Unsupported exclusions are counted without logging their personal identifiers.'
$blockedPower=[Management.Automation.PSCredential]::new('p000000123@sfsu.edu',$standard.Password)
$blockedResult=Invoke-SfsuDirectoryAuthentication -PackageRoot $testRoot -Credential $blockedPower
Assert-True ($blockedResult.Success) 'The public authentication entry point accepts prefixed credentials with the synthetic session provider.'
$unknown=$profile.PSObject.Copy(); $unknown.ProfilePath=Join-Path $testRoot 'unknown-folder'; $unknown.SfsuId=''
$before=& $inventory { $script:SecurityQueries }
$resolved=& $inventory { param($p) Resolve-SfsuProfileIdentity $p $null } $unknown
Assert-True ((& $inventory { $script:SecurityQueries }) -eq $before+1 -and $resolved.IdentitySource -eq 'LDAP') 'An arbitrary folder name does not block exact-SID verification.'
$prepared=Invoke-SfsuBackupPreparation -PackageRoot $testRoot -Profiles @($profile)
Assert-True ($prepared.Paths.Count -eq 1 -and $prepared.Errors.Count -eq 0) 'Suffixed power-user profile prepares metadata and a safe log snapshot.'
$manifestPath=Join-Path $prepared.Paths[0] 'backup.json'
$saved=[IO.File]::ReadAllText($manifestPath)
foreach ($mutation in @('sid','id','manual','boolean')) {
    $data=ConvertFrom-Json $saved
    switch ($mutation) {
        'sid' { $data.Identity.DirectorySid=$localSid }
        'id' { $data.Identity.SfsuId='000000123' }
        'manual' { $data.Identity.Source='Manual'; $data.Identity.ManualConfirmed=$false }
        'boolean' { $data.HasMigrationData='false' }
    }
    [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json $data -Depth 8))
    Assert-True (-not (@(Get-SfsuBackupCatalog $testRoot)[0].MetadataValid)) ('Edited inconsistent metadata is rejected: '+$mutation)
}
[IO.File]::WriteAllText($manifestPath,$saved)

# Ordinary messages remain durable while expensive HTML generation is throttled.
$run=New-SfsuLogRun -PackageRoot $testRoot -Operation ReportPreview -Steps @(@{Id='check';Title='Synthetic check'})
Start-SfsuLogStep $run check
$run.LastRenderUtc=[DateTime]::UtcNow.AddMinutes(1)
$htmlHash=(Get-FileHash $run.ReportPath).Hash
1..120 | ForEach-Object { Write-SfsuLogEvent -Run $run -Message ('Synthetic event '+$_) }
Assert-True ((Get-FileHash $run.ReportPath).Hash -eq $htmlHash -and [IO.File]::ReadAllLines($run.EventsPath).Count -eq 122) '120 messages append durably without 120 forced HTML rewrites.'
$header=ConvertFrom-Json ([IO.File]::ReadAllLines($run.EventsPath)[0])
Assert-True (-not $header.Data.LogoData -and (Test-Path (Join-Path $run.RunDirectory 'logo.png'))) 'The portable PNG is stored beside the journal instead of a large Base64 header.'
Complete-SfsuLogStep $run check Passed 'Synthetic done'
Complete-SfsuLogRun $run Completed 'Synthetic completed' | Out-Null
Assert-True ([IO.File]::ReadAllText($run.ReportPath).Contains('Synthetic event 120') -and [IO.File]::ReadAllText($run.ReportPath).Contains('data:image/png;base64,')) 'Final reports contain every event and embed their own logo.'
$bounded=New-SfsuLogRun -PackageRoot $testRoot -Operation ReportPreview -Steps @(@{Id='check';Title='Bounded journal'})
$boundedSize=(Get-Item $bounded.EventsPath).Length
Assert-Throws { Write-SfsuLogEvent -Run $bounded -Message ('x'*1MB) } 'Oversized event writes are rejected before appending.'
Assert-True ((Get-Item $bounded.EventsPath).Length -eq $boundedSize) 'A rejected event leaves durable evidence unchanged.'
[IO.File]::AppendAllText($bounded.EventsPath,('x'*(1MB+1)))
Assert-Throws { Update-SfsuLogReport -RunDirectory $bounded.RunDirectory } 'Oversized saved records are rejected during report rebuilding.'

# Runtime directory links and file hard links cannot redirect protected writes.
$outside=Join-Path $testRoot 'outside'; [void][IO.Directory]::CreateDirectory($outside)
$sentinel=Join-Path $outside 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'SYNTHETIC PRESERVE')
$sentinelHash=(Get-FileHash $sentinel).Hash
$junction=Join-Path $testRoot 'Backups/linked-backup'
[void](New-Item -ItemType Junction -Path $junction -Target $outside)
Assert-Throws { Export-SfsuLogSnapshot -Run $run -BackupPath $junction } 'A junction backup destination is refused.'
Assert-Throws { Assert-SfsuSafePath (Join-Path $junction 'child') -AllowMissing } 'A junction ancestor is refused even for a missing leaf.'
$plain=Join-Path $testRoot 'Backups/plain'; [void][IO.Directory]::CreateDirectory($plain)
$logLink=Join-Path $plain 'Logs'; [void](New-Item -ItemType Junction -Path $logLink -Target $outside)
Assert-Throws { Export-SfsuLogSnapshot -Run $run -BackupPath $plain } 'A linked Logs child is refused.'
$hardLink=Join-Path $testRoot 'hard-linked-report.html'; [void](New-Item -ItemType HardLink -Path $hardLink -Target $sentinel)
Assert-Throws { & $logger { param($p) Write-SfsuAtomicText $p 'must not write' } $hardLink } 'A hard-linked report is refused before replacement or overwrite.'
Assert-Throws { & $logger { param($s,$d) Copy-SfsuReportFile $s $d } $run.ReportPath $hardLink } 'The fallback copy refuses a hard-linked target before truncation.'
$guard=Enter-SfsuPathGuard $plain
try { Assert-Throws { [IO.Directory]::Move($plain,($plain+'-moved')) } 'An active ancestor guard prevents renaming the destination directory.' } finally { $guard.Dispose() }
Assert-True ((Get-FileHash $sentinel).Hash -eq $sentinelHash) 'External sentinel bytes are preserved through all link attacks.'

# Retention is preview-first and excludes active/damaged/unknown runs and Backups.
$old=[DateTime]::UtcNow.AddDays(-60)
$lines=[IO.File]::ReadAllLines($run.EventsPath)
for ($i=0;$i -lt $lines.Count;$i++) { $event=ConvertFrom-Json $lines[$i]; $event.TimeUtc=$old.ToString('o'); $lines[$i]=ConvertTo-Json $event -Depth 12 -Compress }
[IO.File]::WriteAllLines($run.EventsPath,$lines)
foreach ($item in Get-ChildItem -LiteralPath $run.RunDirectory -Recurse -Force) { $item.LastWriteTimeUtc=$old }
(Get-Item -LiteralPath $run.RunDirectory).LastWriteTimeUtc=$old
$backupHash=(Get-FileHash $manifestPath).Hash
$preview=@(Invoke-SfsuLogRetention -PackageRoot $testRoot -Days 30)
Assert-True (@($preview | Where-Object { $_.Path -eq $run.RunDirectory -and $_.Status -eq 'Eligible' }).Count -eq 1 -and (Test-Path $run.RunDirectory)) 'Retention previews old finalized runs without deleting them.'
[void]@(Invoke-SfsuLogRetention -PackageRoot $testRoot -Days 30 -Apply -WhatIf)
Assert-True (Test-Path $run.RunDirectory) 'ShouldProcess WhatIf also prevents deletion when Apply is supplied.'
$snapshotRoot=$prepared.Paths[0]
$snapshotRun=@(Get-ChildItem -LiteralPath (Join-Path $snapshotRoot 'Logs') -Directory)[0]
$snapshotJournal=Join-Path $snapshotRun.FullName 'events.jsonl'
$snapshotLines=[IO.File]::ReadAllLines($snapshotJournal)
for ($i=0;$i -lt $snapshotLines.Count;$i++) { $event=ConvertFrom-Json $snapshotLines[$i]; $event.TimeUtc=$old.ToString('o'); $snapshotLines[$i]=ConvertTo-Json $event -Depth 12 -Compress }
[IO.File]::WriteAllLines($snapshotJournal,$snapshotLines)
foreach ($item in Get-ChildItem -LiteralPath $snapshotRun.FullName -Recurse -Force) { $item.LastWriteTimeUtc=$old }
(Get-Item -LiteralPath $snapshotRun.FullName).LastWriteTimeUtc=$old
$snapshotHash=(Get-FileHash $snapshotJournal).Hash
$wrongRoot=@(Invoke-SfsuLogRetention -PackageRoot $snapshotRoot -Days 30 -Apply)
Assert-True (@($wrongRoot | Where-Object { $_.Status -eq 'Preserved' -and $_.Reason -match 'backup snapshots are preserved' }).Count -eq 1 -and (Get-FileHash $snapshotJournal).Hash -eq $snapshotHash) 'A backup passed accidentally as PackageRoot cannot have its snapshots pruned.'
$applied=@(Invoke-SfsuLogRetention -PackageRoot $testRoot -Days 30 -Apply)
Assert-True (@($applied | Where-Object { $_.Path -eq $run.RunDirectory -and $_.Status -eq 'Removed' }).Count -eq 1 -and -not (Test-Path $run.RunDirectory)) 'Explicit apply removes only eligible root diagnostic runs.'
Assert-True ((Get-FileHash $manifestPath).Hash -eq $backupHash -and (Get-FileHash $sentinel).Hash -eq $sentinelHash) 'Retention preserves backups, finalized backup snapshots and linked destinations.'
Assert-True (@(Get-SfsuStorageAccessReview $testRoot).Count -eq 2) 'Storage ACL screening reports both runtime roots without changing permissions.'
$maintenanceOutput=& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1') -PreviewLogRetention
Assert-True ($LASTEXITCODE -eq 0) 'The packaged maintenance command runs without opening the UI or contacting AD.'

# Expiry and active-work protection use synthetic time, without waiting ten minutes.
$main=. (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
try {
    $script:SfsuUi.Credential=$standard; $script:SfsuUi.UseDirectory=$true
    $script:SfsuUi.DirectoryLastUsedUtc=[DateTime]::UtcNow.AddMinutes(-11)
    $script:SfsuUi.Worker=[pscustomobject]@{Synthetic=$true}
    Assert-True (-not (Test-SfsuCredentialExpiry) -and $null -ne $script:SfsuUi.Credential) 'Active work protects its credentials from disposal.'
    $script:SfsuUi.Worker=$null
    Assert-True ((Test-SfsuCredentialExpiry) -and -not $script:SfsuUi.UseDirectory -and $null -eq $script:SfsuUi.Credential) 'Ten minutes without directory activity clears credentials and selects manual mode.'
} finally { $main.Dispose() }
Write-Output ("PASS: $script:Assertions security assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
