# Native USMT orchestration. Public entry points perform all-target preflight;
# tests replace module-private OS/process adapters, never enable a runtime bypass.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Logging.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Inventory.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Launch.psm1')
if (-not ('Sfsu.Engine.NativeRun' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Sfsu.Engine.Native.cs') }
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Policy.psm1')

function Test-SfsuMigrationCancellation($Control) {
    if ($Control -and $Control.CancelRequested) { throw [OperationCanceledException]::new('The technician cancelled the operation. Partial stores/accounts/data are preserved; no rollback is implied.') }
}

function Set-SfsuMigrationProgress($Control,[string]$Message,[int]$Percent=-1) {
    if ($Control) { $Control.Message=$Message; $Control.Percent=$Percent }
}

function Get-SfsuMigrationHost {
    $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $architecture=[Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $architecture) { $architecture=[Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    $folder=switch ($architecture.ToUpperInvariant()) { 'AMD64' { 'amd64' }; 'ARM64' { 'arm64' }; default { throw 'This engine supports x64 and ARM64 Windows only.' } }
    [pscustomobject]@{Build=[int]$os.BuildNumber;ProductType=[int]$os.ProductType;Version=[string]$os.Version;Architecture=$folder;Computer=$env:COMPUTERNAME}
}

function Assert-SfsuMigrationHost([string]$Operation) {
    if (-not (Test-SfsuAdministrator)) { throw 'Run the app as administrator before capture or restore.' }
    $hostInfo=Get-SfsuMigrationHost
    $minimum=10240; if ($Operation -eq 'Restore') { $minimum=22000 }
    if ($hostInfo.ProductType -ne 1 -or $hostInfo.Build -lt $minimum) { throw 'Capture requires Windows 10 or later; restore requires Windows 11. Windows Server is unsupported.' }
    [Sfsu.Engine.Accounts]::EnablePrivileges()
    $hostInfo
}

function Get-SfsuExecutableVersion([string]$Path) {
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    '{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
}

function Get-SfsuToolset([string]$PackageRoot,[string]$Architecture) {
    if ($Architecture -notin @('amd64','arm64')) { throw 'Unsupported native architecture.' }
    $directory=Join-Path $PackageRoot ('App/User State Migration Tool/'+$Architecture)
    [void](Assert-SfsuSafePath $directory)
    $files=New-Object Collections.Generic.List[object]
    $version=''; $machine=0x8664; if ($Architecture -eq 'arm64') { $machine=0xaa64 }
    foreach ($name in @('scanstate.exe','loadstate.exe','usmtutils.exe','mighost.exe','migcore.dll','migstore.dll','migsys.dll','MigApp.xml','MigDocs.xml','MigXML.xsd')) {
        $path=Join-Path $directory $name; [void](Assert-SfsuSafePath $path)
        if ($name.EndsWith('.exe')) {
            $stream=[Sfsu.SafeFiles]::Open($path,$false,$false); $reader=New-Object IO.BinaryReader($stream)
            try { $stream.Position=0x3c; $offset=$reader.ReadInt32(); $stream.Position=$offset; if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $machine) { throw 'The supplied USMT executable architecture is incorrect.' } } finally { $reader.Dispose() }
            $signature=Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw ('A valid Microsoft signature is required: '+$name) }
            $current=Get-SfsuExecutableVersion $path
            if (-not $version) { $version=$current }
            if ($version -ne $current) { throw 'USMT executables must come from the same ADK build.' }
        }
        $versionText=''; if ($name.EndsWith('.exe')) { $versionText=[Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion }
        $files.Add([pscustomobject]@{Name=$name;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;FileVersionText=$versionText})
    }
    foreach ($name in @('DLManifests','ReplacementManifests')) { [void](Assert-SfsuSafePath (Join-Path $directory $name)) }
    [pscustomobject]@{Directory=$directory;Architecture=$Architecture;Version=$version;Files=$files.ToArray()}
}

function ConvertTo-SfsuNativeArgument([string]$Value) {
    if ($Value -match '[\x00\r\n]') { throw 'Invalid native command-line argument.' }
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}

function Read-SfsuNativeTail([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $guard=Enter-SfsuPathGuard $Path; $stream=$null
    try {
        $stream=[Sfsu.SafeFiles]::OpenSharedRead($Path)
        # USMT text logs can be UTF-16; preserve the BOM's encoding when tailing.
        $prefix=New-Object byte[] 3; $read=$stream.Read($prefix,0,3); $encoding=[Text.Encoding]::UTF8
        if ($read -ge 2 -and $prefix[0] -eq 255 -and $prefix[1] -eq 254) { $encoding=[Text.Encoding]::Unicode }
        $start=[Math]::Max(0,$stream.Length-65536); if ($encoding -eq [Text.Encoding]::Unicode -and $start%2) { $start++ }
        $stream.Position=$start; $reader=New-Object IO.StreamReader($stream,$encoding,$true)
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { if ($stream) { $stream.Dispose() }; $guard.Dispose() }
}

function Get-SfsuNativeDiagnostics([string]$Log,[string]$Progress,[int]$ExitCode) {
    $errors=0; $warnings=0; $nonfatal=0
    foreach ($path in @($Log,$Progress)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $guard=Enter-SfsuPathGuard $path; $stream=$null; $reader=$null
        try {
            $stream=[Sfsu.SafeFiles]::OpenSharedRead($path)
            $reader=New-Object IO.StreamReader($stream)
            while (-not $reader.EndOfStream) {
                $line=$reader.ReadLine()
                if ($line -match '(?i)\bError\b') { $errors++ }
                if ($line -match '(?i)\bWarning\b') { $warnings++ }
                if ($line -match '(?i)nonFatalError') { $nonfatal++ }
            }
        } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }; $guard.Dispose() }
    }
    [pscustomobject]@{ExitCode=$ExitCode;ErrorLines=$errors;WarningLines=$warnings;NonFatalRecords=$nonfatal;HasWarnings=($ExitCode -eq 3 -or $errors -gt 0 -or $warnings -gt 0 -or $nonfatal -gt 0)}
}

function Start-SfsuNativeProcess([string]$Path,[string]$Arguments,[string]$Directory) {
    [Sfsu.Engine.NativeRun]::new($Path,$Arguments,$Directory)
}

function Invoke-SfsuNativeTool {
    param($Tools,[string]$Name,[string[]]$Arguments,$Run,[string]$StepId,[string]$Label,[string]$Log='',[string]$Progress='',$Control)
    Test-SfsuMigrationCancellation $Control
    if ($Name -notin @('scanstate.exe','loadstate.exe','usmtutils.exe')) { throw 'Unsupported migration executable.' }
    $path=Join-Path $Tools.Directory $Name
    $argumentText=(@($Arguments | ForEach-Object { ConvertTo-SfsuNativeArgument $_ }) -join ' ')
    Write-SfsuLogEvent -Run $Run -StepId $StepId -Message ($Label+' started.') -Details ($Name+' '+$argumentText)
    $lease=Enter-SfsuPathGuard $Tools.Directory
    $executable=$null; $process=$null
    $observationFailure=''; $observationWarningRecorded=$false
    try {
        $executable=[Sfsu.SafeFiles]::Open($path,$false,$false)
        $process=Start-SfsuNativeProcess $path $argumentText $Tools.Directory
        $last=-1; $lastPoll=[DateTime]::MinValue
        while (-not $process.Poll(200)) {
            Test-SfsuMigrationCancellation $Control
            if ($Progress -and ([DateTime]::UtcNow-$lastPoll).TotalSeconds -ge 1) {
                $lastPoll=[DateTime]::UtcNow
                try {
                    $tail=Read-SfsuNativeTail $Progress
                    $matches=[regex]::Matches($tail,'(?i)totalPercentageCompleted\s*,\s*(\d{1,3})')
                    if ($matches.Count -gt 0) {
                        $percent=[Math]::Min(100,[int]$matches[$matches.Count-1].Groups[1].Value)
                        Set-SfsuMigrationProgress $Control $Label $percent
                        if ($percent -ge $last+5) { $last=$percent; Write-SfsuLogEvent -Run $Run -StepId $StepId -Message ($Label+': native progress '+$percent+'%.') }
                    } else { Set-SfsuMigrationProgress $Control $Label }
                } catch {
                    if ($_.Exception -is [OperationCanceledException] -or $_.Exception -is [Management.Automation.PipelineStoppedException]) { throw }
                    Test-SfsuMigrationCancellation $Control
                    Set-SfsuMigrationProgress $Control ($Label+' (progress/report refresh temporarily unavailable; native process continues)')
                    if (-not $observationFailure) {
                        $cause=$_.Exception.Message
                        if ($cause.Length -gt 1500) { $cause=$cause.Substring(0,1500) }
                        $observationFailure='Progress/report observation failed while the native process continued. Progress file: '+$Progress+'. '+$cause
                        # A journal append can succeed while its HTML refresh is
                        # denied. Retry this warning after exit if recording fails.
                        try { Write-SfsuLogEvent -Run $Run -StepId $StepId -Severity WARNING -Message $observationFailure -NextAction 'Review the original native logs. No process was cancelled because of this observation failure.'; $observationWarningRecorded=$true }
                        catch { }
                    }
                }
            }
        }
        Test-SfsuMigrationCancellation $Control
        $code=$process.ExitCode
    } finally { if ($process) { $process.Dispose() }; if ($executable) { $executable.Dispose() }; $lease.Dispose() }
    # Native work has ended. Required result/journal failures may stop subsequent
    # stages, but an optional live refresh must never kill the running native job.
    # Persist the actual exit before optional raw-link/diagnostic work. A denied
    # HTML refresh can throw after this journal append; the exit is still evidence.
    Write-SfsuLogEvent -Run $Run -StepId $StepId -Message ($Label+' exited with code '+$code+'.')
    if ($observationFailure -and -not $observationWarningRecorded) { Write-SfsuLogEvent -Run $Run -StepId $StepId -Severity WARNING -Message $observationFailure -NextAction 'Review the original native logs and reporting access.' }
    foreach ($file in @($Log,$Progress)) {
        if ($file -and (Test-Path -LiteralPath $file)) { Add-SfsuRawLog -Run $Run -Name ([IO.Path]::GetFileName($file)) -StepId $StepId }
    }
    $diagnostics=Get-SfsuNativeDiagnostics $Log $Progress $code
    if ($observationFailure) { $diagnostics.HasWarnings=$true }
    Write-SfsuLogEvent -Run $Run -StepId $StepId -Message ($Label+' native diagnostic summary.') -Details (ConvertTo-Json $diagnostics -Compress)
    if ($code -notin @(0,3) -or ($Name -eq 'usmtutils.exe' -and $code -ne 0)) { throw ($Label+' failed with USMT exit code '+$code+'. Review the original logs; dependent operations were stopped.') }
    if ($diagnostics.HasWarnings) { Write-SfsuLogEvent -Run $Run -StepId $StepId -Severity WARNING -Message ($Label+' reported warnings/nonfatal errors. A completed command does not prove complete data migration.') -NextAction 'Review native logs and reconcile unavailable data before re-imaging.' }
    $diagnostics
}

function Get-SfsuRuleArguments([string]$Directory) {
    @(('/i:'+(Join-Path $Directory 'MigApp.xml')),('/i:'+(Join-Path $Directory 'MigDocs.xml')),('/i:'+(Join-Path $Directory 'SfsuPolicy.xml')),('/config:'+(Join-Path $Directory 'Config.xml')))
}

function Get-SfsuUserArguments([string]$Sid) {
    if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'An exact source profile SID is required.' }
    # Exact SID plus its Classes context; no prefix wildcard that could include
    # another account whose RID starts with the same digits.
    @('/ue:*',('/ui:'+$Sid),('/ui:'+$Sid+'_Classes'))
}

function Save-SfsuEngineManifest([string]$Path,$Data) { Write-SfsuAtomicText (Join-Path $Path 'backup.json') (ConvertTo-Json $Data -Depth 20) }

function Assert-SfsuCaptureProfile($Profile) {
    Assert-SfsuIdentityEvidence $Profile $Profile.ProfileSid
    if ($Profile.Loaded) { throw ('Sign out the selected employee before capture so browser databases and settings are closed: '+$Profile.ProfilePath) }
    $registered=@(Get-CimInstance -ClassName Win32_UserProfile | Where-Object SID -eq $Profile.ProfileSid)
    if ($registered.Count -ne 1 -or $registered[0].Loaded -or [IO.Path]::GetFullPath($registered[0].LocalPath).TrimEnd('\') -ine [IO.Path]::GetFullPath($Profile.ProfilePath).TrimEnd('\')) { throw 'The source profile registration/path changed or is now loaded. Refresh profiles before capture.' }
}

function Invoke-SfsuCaptureReview {
    param([string]$PackageRoot,[object[]]$Profiles)
    if (@($Profiles).Count -eq 0) { throw 'Select at least one profile.' }
    $run=New-SfsuLogRun -PackageRoot $PackageRoot -Operation BackupPreparation -Steps @(@{Id='locations';Title='Review selected source profiles and cloud/browser locations'}) -Label 'Capture planning only; no employee files copied.'
    try {
        Start-SfsuLogStep $run locations
        $hostInfo=Assert-SfsuMigrationHost Backup
        $reviews=foreach ($profile in $Profiles) { Assert-SfsuCaptureProfile $profile; Get-SfsuLocationReview $profile }
        Complete-SfsuLogStep $run locations Passed 'Source locations discovered. Technician review is required before capture.'
        Complete-SfsuLogRun $run Completed 'Review the discovered roots and add any missing custom locations.' | Out-Null
        [pscustomobject]@{Reviews=@($reviews);ReportPath=$run.ReportPath;RunDirectory=$run.RunDirectory}
    } catch {
        Write-SfsuLogEvent -Run $run -Severity ERROR -Message $_.Exception.Message
        Complete-SfsuLogRun $run Failed 'Capture planning stopped; no capture ran.' | Out-Null
        throw
    }
}

function Set-SfsuCaptureLocations {
    param($Review,[string]$CloudText,[string]$BrowserText,[bool]$Confirmed)
    if (-not $Confirmed) { throw 'Confirm that you reviewed cloud locations and added missing roots before capture.' }
    $cloud=@($CloudText -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { Expand-SfsuProfileLocation $_ $Review.Profile -CloudRoot })
    $browsers=foreach ($line in @($BrowserText -split '\r?\n' | Where-Object { $_.Trim() })) {
        $parts=$line -split '\|',2
        if ($parts.Count -ne 2 -or $parts[0].Trim() -notin @('Edge','Chrome','Firefox')) { throw 'Enter custom browser folders as Edge|C:\Path, Chrome|C:\Path or Firefox|C:\Path, one per line.' }
        [pscustomobject]@{Browser=$parts[0].Trim();Path=(Expand-SfsuProfileLocation $parts[1].Trim() $Review.Profile)}
    }
    $Review.AdditionalCloudRoots=$cloud; $Review.AdditionalBrowserRoots=@($browsers); $Review.Reviewed=$true
    $Review
}

function Test-SfsuMigrationRules([string]$PolicyDirectory) {
    foreach ($name in @('MigApp.xml','MigDocs.xml','SfsuPolicy.xml','Config.xml')) {
        $path=Join-Path $PolicyDirectory $name; [void](Assert-SfsuSafePath $path)
        $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing='Prohibit'; $settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($path,$settings)
        try { while ($reader.Read()) { } } finally { $reader.Dispose() }
    }
}

function Get-SfsuMigrationFreeSpace([string]$Path) { [Sfsu.Engine.Locations]::FreeBytes($Path) }
function Read-SfsuStoreEstimate([string]$Path) {
    $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing='Prohibit'; $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($Path,$settings); $xml=New-Object Xml.XmlDocument; $xml.XmlResolver=$null
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $sizes=@(foreach ($node in $xml.SelectNodes('//storeSize/size')) { $value=0L; if ([long]::TryParse($node.InnerText,[ref]$value) -and $value -gt 0) { $value } })
    if ($sizes.Count -eq 0) { return 0L }
    [long]($sizes | Measure-Object -Maximum).Maximum
}

function Invoke-SfsuCapture {
    param([string]$PackageRoot,[object[]]$Reviews,$Control=$null)
    if (@($Reviews).Count -eq 0) { throw 'Select at least one reviewed profile.' }
    $run=New-SfsuLogRun -PackageRoot $PackageRoot -Operation Backup -Steps @(@{Id='preflight';Title='Check all selected sources and native dependencies'},@{Id='capture';Title='Estimate and capture selected profiles'},@{Id='verify';Title='Verify all compressed stores'}) -Label 'Native USMT capture; unencrypted compressed stores; cloud uploads assumed complete.'
    $paths=New-Object Collections.Generic.List[string]; $errors=New-Object Collections.Generic.List[string]
    $backups=New-Object Collections.Generic.List[object]; $active='preflight'; $outcome='Failed'; $current=$null
    try {
        Start-SfsuLogStep $run preflight
        $hostInfo=Assert-SfsuMigrationHost Backup; $tools=Get-SfsuToolset $PackageRoot $hostInfo.Architecture
        $selected=@{}
        foreach ($review in $Reviews) {
            Test-SfsuMigrationCancellation $Control; Assert-SfsuCaptureProfile $review.Profile
            if (-not $review.Reviewed -or $selected.ContainsKey($review.Profile.ProfileSid)) { throw 'Every source needs location review and must appear only once.' }
            $selected[$review.Profile.ProfileSid]=$true
        }
        Complete-SfsuLogStep $run preflight Passed ('All sources passed. Native tool version '+$tools.Version+'; '+$tools.Architecture+'.')
        $active='capture'; Start-SfsuLogStep $run capture; $index=0
        $allProfiles=@(Get-CimInstance -ClassName Win32_UserProfile)
        foreach ($review in $Reviews) {
            Test-SfsuMigrationCancellation $Control; Assert-SfsuCaptureProfile $review.Profile; $index++
            $current=New-SfsuPreparedBackup -PackageRoot $PackageRoot -Profile $review.Profile -RunId $run.RunId
            $paths.Add($current.Path); $backups.Add($current)
            $current.Manifest.SchemaVersion=4; $current.Manifest.Status='Capturing'
            $current.Manifest['Engine']=[ordered]@{Store='Store';SourceSid=$review.Profile.ProfileSid;Architecture=$tools.Architecture;ToolVersion=$tools.Version;ToolFiles=$tools.Files;SourceOS=$hostInfo.Version;PolicyFiles=@();Policy=$null;CaptureExitCode=$null;VerifyExitCode=$null;EfsDecryptionVerified=$false;CaptureRunId=$run.RunId}
            Save-SfsuEngineManifest $current.Path $current.Manifest
            $lease=Enter-SfsuPathGuard $current.Path
            try {
                $policy=Join-Path $current.Path 'Policy'; [Sfsu.SafeFiles]::ReserveDirectory($policy)
                foreach ($name in @('MigApp.xml','MigDocs.xml')) {
                    $source=[Sfsu.SafeFiles]::Open((Join-Path $tools.Directory $name),$false,$false); $dest=$null
                    try { $dest=[Sfsu.SafeFiles]::Open((Join-Path $policy $name),$true,$true); $source.CopyTo($dest); $dest.Flush($true) } finally { if ($dest) { $dest.Dispose() }; $source.Dispose() }
                }
                $other=@($allProfiles | Where-Object { $_.SID -ne $review.Profile.ProfileSid -and -not $_.Special } | ForEach-Object LocalPath)
                $current.Manifest.Engine.Policy=New-SfsuMigrationPolicy -Path (Join-Path $policy 'SfsuPolicy.xml') -Review $review -PackageRoot $PackageRoot -OtherProfiles $other
                Write-SfsuLogEvent -Run $run -StepId capture -Message 'Cloud roots/caches and exact native exclusions were reviewed.' -Details (ConvertTo-Json $current.Manifest.Engine.Policy -Depth 8)
                $prefix='p'+$index
                $config=Join-Path $policy 'Config.xml'
                $genlog=Get-SfsuRawLogPath $run ($prefix+'-config.log')
                $genargs=@(('/genconfig:'+$config),('/i:'+(Join-Path $policy 'MigApp.xml')),('/i:'+(Join-Path $policy 'MigDocs.xml')),('/i:'+(Join-Path $policy 'SfsuPolicy.xml')),('/l:'+$genlog),'/v:5')
                Invoke-SfsuNativeTool -Tools $tools -Name scanstate.exe -Arguments $genargs -Run $run -StepId capture -Label 'Generate native component configuration' -Log $genlog -Control $Control | Out-Null
                $disabled=Set-SfsuGeneratedConfig $config
                Test-SfsuMigrationRules $policy
                $current.Manifest.Engine.PolicyFiles=@(foreach ($name in @('MigApp.xml','MigDocs.xml','SfsuPolicy.xml','Config.xml')) { [pscustomobject]@{Name=$name;Sha256=(Get-FileHash -LiteralPath (Join-Path $policy $name) -Algorithm SHA256).Hash} })
                Save-SfsuEngineManifest $current.Path $current.Manifest
                $store=Join-Path $current.Path 'Store'
                $common=@(Get-SfsuRuleArguments $policy)+@(Get-SfsuUserArguments $review.Profile.ProfileSid)+@('/efs:copyraw','/c','/r:2','/w:3','/v:5')
                $estimate=Get-SfsuRawLogPath $run ($prefix+'-estimate.xml'); $estlog=Get-SfsuRawLogPath $run ($prefix+'-estimate.log')
                Set-SfsuMigrationProgress $Control ('Estimating '+$review.Profile.DisplayName)
                Invoke-SfsuNativeTool -Tools $tools -Name scanstate.exe -Arguments (@($store)+$common+@(('/p:'+$estimate),('/l:'+$estlog))) -Run $run -StepId capture -Label 'Estimate capture size' -Log $estlog -Control $Control | Out-Null
                if (Test-Path -LiteralPath $estimate) {
                    Add-SfsuRawLog $run ([IO.Path]::GetFileName($estimate)) capture
                    $estimated=Read-SfsuStoreEstimate $estimate
                    $free=Get-SfsuMigrationFreeSpace $current.Path
                    $current.Manifest.Engine['EstimatedStoreBytes']=$estimated; $current.Manifest.Engine['DestinationFreeBytes']=$free
                    Write-SfsuLogEvent -Run $run -StepId capture -Message ('Native store estimate: '+$estimated+' bytes (maximum reported cluster-size estimate); destination available: '+$free+' bytes.')
                    if ($estimated -gt 0 -and $free -lt [decimal]$estimated*1.1) { throw 'The destination lacks the native estimated store size plus a 10 percent working margin. Capture was not started.' }
                    if ($estimated -eq 0) { Write-SfsuLogEvent -Run $run -StepId capture -Severity WARNING -Message 'USMT wrote an estimate but its size format was not recognized. The original estimate is retained; native disk-full handling still applies.' }
                }
                $log=Get-SfsuRawLogPath $run ($prefix+'-scanstate.log'); $progress=Get-SfsuRawLogPath $run ($prefix+'-scan-progress.log'); $list=Get-SfsuRawLogPath $run ($prefix+'-files.txt')
                $captured=Invoke-SfsuNativeTool -Tools $tools -Name scanstate.exe -Arguments (@($store)+$common+@(('/l:'+$log),('/progress:'+$progress),('/listfiles:'+$list))) -Run $run -StepId capture -Label ('Capturing '+$review.Profile.DisplayName+' ('+$index+'/'+$Reviews.Count+')') -Log $log -Progress $progress -Control $Control
                $current.Manifest.Engine.CaptureExitCode=$captured.ExitCode
                $current.Manifest.Engine['CaptureWarnings']=$captured.HasWarnings
                if (Test-Path -LiteralPath $list) { Add-SfsuRawLog $run ([IO.Path]::GetFileName($list)) capture }
                Save-SfsuEngineManifest $current.Path $current.Manifest
            } finally { $lease.Dispose() }
        }
        Complete-SfsuLogStep $run capture Passed 'Native capture commands ended. Compressed-store verification follows.'
        $active='verify'; Start-SfsuLogStep $run verify; $index=0
        foreach ($current in $backups) {
            Test-SfsuMigrationCancellation $Control; $index++
            $store=Join-Path $current.Path 'Store/USMT/USMT.MIG'; [void](Assert-SfsuSafePath $store)
            $lease=Enter-SfsuPathGuard (Join-Path $current.Path 'Store'); $hold=$null
            try {
                $hold=[Sfsu.SafeFiles]::Open($store,$false,$false)
                $log=Get-SfsuRawLogPath $run ('p'+$index+'-verify.log')
                $verified=Invoke-SfsuNativeTool -Tools $tools -Name usmtutils.exe -Arguments @('/verify:all',$store,('/l:'+$log)) -Run $run -StepId verify -Label ('Verify captured store '+$index) -Log $log -Control $Control
                $current.Manifest.Engine.VerifyExitCode=$verified.ExitCode
                $current.Manifest.Engine['StoreLength']=$hold.Length
                $current.Manifest.Status='CapturedVerified'; if ($current.Manifest.Engine.CaptureWarnings -or $verified.HasWarnings) { $current.Manifest.Status='CapturedWithWarnings' }
                $current.Manifest.HasMigrationData=$true
                Save-SfsuEngineManifest $current.Path $current.Manifest
                Write-SfsuCheckpoint -Run $run -StepId verify -Status Passed -Message ($current.Path+': compressed catalog and files passed UsmtUtils /verify:all.')
            } finally { if ($hold) { $hold.Dispose() }; $lease.Dispose() }
        }
        Write-SfsuCheckpoint -Run $run -StepId verify -Status Warning -Message 'Store integrity was checked. Intended-user EFS decryption and application/browser fidelity require an actual restore test; they are not established by a successful capture.' -NextAction 'Retain the source until coverage, warnings and intended-user decryption are accepted.'
        Complete-SfsuLogStep $run verify Passed 'Store verification ended; detailed evidence and limitations are retained.'
        $outcome='CompletedWithWarnings'; Complete-SfsuLogRun $run Completed 'Capture finished. Review warnings and restore/decryption acceptance before re-imaging.' | Out-Null
    } catch {
        $cancelled=$_.Exception -is [OperationCanceledException]; $outcome='Failed'; if ($cancelled) { $outcome='Cancelled' }
        $errors.Add($_.Exception.Message)
        foreach ($backup in $backups) {
            if (-not $backup.Manifest.HasMigrationData) { $backup.Manifest.Status=if ($cancelled) { 'CaptureCancelled' } else { 'CaptureFailed' }; try { Save-SfsuEngineManifest $backup.Path $backup.Manifest } catch { } }
        }
        Write-SfsuLogEvent -Run $run -StepId $active -Severity ERROR -Message $errors[$errors.Count-1] -NextAction 'Partial stores are preserved and cannot be selected for restore. Start a new capture after resolving the cause.'
        Complete-SfsuLogRun $run $outcome 'Capture stopped. Completed stores and partial evidence were preserved; nothing was overwritten.' | Out-Null
    } finally {
        foreach ($path in $paths) { try { Export-SfsuLogSnapshot $run $path | Out-Null } catch { $errors.Add('Report snapshot could not be copied; retain the root Logs report.') } }
        Set-SfsuMigrationProgress $Control ('Capture '+$outcome)
    }
    [pscustomobject]@{Paths=$paths.ToArray();Errors=$errors.ToArray();Outcome=$outcome;ReportPath=$run.ReportPath;RunDirectory=$run.RunDirectory}
}

function Get-SfsuDestinationProfiles { @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop) }
function Test-SfsuLocalAccountExists([string]$Name) { [Sfsu.Engine.Accounts]::Exists($Name) }
function Get-SfsuDestinationProfileRoot { [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory -ErrorAction Stop).ProfilesDirectory) }
function New-SfsuRestoreAccount([string]$Name,[Security.SecureString]$Password) { [Sfsu.Engine.Accounts]::CreateDisabled($Name,$Password) }
function Disable-SfsuRestoreAccount([string]$Name) { [Sfsu.Engine.Accounts]::SetEnabled($Name,$false) }
function Set-SfsuRestoreAccountState($Plan,[string]$Sid) {
    [Sfsu.Engine.Accounts]::SetGroup($Sid,'S-1-5-32-545',$true)
    [Sfsu.Engine.Accounts]::SetGroup($Sid,'S-1-5-32-544',$Plan.LocalOptions.Administrator)
    if ([Sfsu.Engine.Accounts]::IsAdministrator($Plan.AccountName) -ne $Plan.LocalOptions.Administrator) { throw 'The restored account Administrators membership did not match the technician choice; the account stays disabled.' }
    [Sfsu.Engine.Accounts]::SetEnabled($Plan.AccountName,$Plan.LocalOptions.Enabled)
    if ([Sfsu.Engine.Accounts]::Enabled($Plan.AccountName) -ne $Plan.LocalOptions.Enabled) { throw 'The restored account enabled state could not be verified.' }
}

function Get-SfsuRestorePlans {
    param([string]$PackageRoot,[object[]]$Backups,[switch]$RequireOptions)
    if (@($Backups).Count -eq 0) { throw 'Select at least one backup.' }
    $root=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'Backups')).TrimEnd('\')
    $destinationProfiles=@(Get-SfsuDestinationProfiles); $profileRoot=Get-SfsuDestinationProfileRoot
    $plans=New-Object Collections.Generic.List[object]; $seen=@{}
    foreach ($backup in $Backups) {
        $path=[IO.Path]::GetFullPath($backup.Path).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($path) -ine $root) { throw 'A selected backup is outside this package Backups directory.' }
        $manifest=(Read-SfsuBackupManifest $path).Data
        if ($manifest.SchemaVersion -ne 4 -or -not $manifest.HasMigrationData -or $manifest.Status -notin @('CapturedVerified','CapturedWithWarnings')) { throw 'Every selected backup must contain a verified native capture; prepared, failed and cancelled folders cannot restore.' }
        $sid=[string]$manifest.SourceProfile.Sid; $name=[string]$manifest.Identity.AccountName
        if ($seen.ContainsKey($sid)) { throw 'Select only one backup for each destination identity.' }; $seen[$sid]=$true
        if (@($destinationProfiles | Where-Object SID -eq $sid).Count -gt 0 -or (Test-Path -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$sid))) { throw 'A selected destination employee profile already exists. The entire restore is stopped.' }
        $leaf=[IO.Path]::GetFileName([string]$manifest.SourceProfile.Path)
        $candidates=@($leaf,$name,[string]$manifest.Identity.SamAccountName) | Where-Object { $_ } | Select-Object -Unique
        foreach ($candidate in $candidates) {
            if ($candidate -match '[\\/:*?"<>|]' -or $candidate -in @('.','..')) { throw 'Unsafe destination profile-folder candidate.' }
            foreach ($folder in @(Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction Stop)) {
                if ($folder.Name -ieq $candidate -or $folder.Name.StartsWith($candidate+'.',[StringComparison]::OrdinalIgnoreCase)) { throw 'A selected destination employee profile folder already exists. The entire restore is stopped.' }
            }
        }
        $options=$null
        if ($manifest.Identity.AccountType -eq 'Local') {
            if ($name.Length -gt 20 -or $name -match '["/\\\[\]:;|=,+*?<>\x00-\x1f]' -or $name.TrimEnd(' ','.') -ne $name -or -not $name.Trim('.').Trim()) { throw 'The saved local account name is not valid for Windows account creation.' }
            if (Test-SfsuLocalAccountExists $name) { throw 'A selected target local account already exists. The entire restore is stopped before account or data changes.' }
            $key='Local:'+ $name
            if ($seen.ContainsKey($key)) { throw 'Two selected backups target the same local account name.' }; $seen[$key]=$true
            if ($backup.PSObject.Properties['LocalOptions']) { $options=$backup.LocalOptions }
            if ($RequireOptions -and ($null -eq $options -or $options.Password -isnot [Security.SecureString] -or $options.Password.Length -eq 0 -or $options.Password.Length -gt 256 -or $options.Enabled -isnot [bool] -or $options.Administrator -isnot [bool])) { throw 'Each local account needs a password, explicit enabled state and Administrators-membership choice.' }
        }
        $policy=Join-Path $path 'Policy'
        foreach ($file in $manifest.Engine.PolicyFiles) {
            if ($file.Name -notin @('MigApp.xml','MigDocs.xml','SfsuPolicy.xml','Config.xml')) { throw 'Unknown captured policy filename.' }
            $filePath=Join-Path $policy $file.Name; [void](Assert-SfsuSafePath $filePath)
            if ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -cne $file.Sha256) { throw 'Captured migration rules changed or are damaged. The restore is stopped.' }
        }
        Test-SfsuMigrationRules $policy
        [void](Assert-SfsuSafePath (Join-Path $path 'Store/USMT/USMT.MIG'))
        $plans.Add([pscustomobject]@{Path=$path;Manifest=$manifest;ProfileSid=$sid;AccountType=$manifest.Identity.AccountType;AccountName=$name;DisplayName=$manifest.Identity.DisplayName;LocalOptions=$options;PolicyDirectory=$policy})
    }
    $plans.ToArray()
}

function Invoke-SfsuRestorePlanning {
    param([string]$PackageRoot,[object[]]$Backups)
    $run=New-SfsuLogRun -PackageRoot $PackageRoot -Operation RestoreReview -Steps @(@{Id='preflight';Title='Check all selected destination identities'}) -Label 'Restore planning only. No account/data changes.'
    try {
        Start-SfsuLogStep $run preflight; $hostInfo=Assert-SfsuMigrationHost Restore
        $plans=@(Get-SfsuRestorePlans $PackageRoot $Backups)
        Complete-SfsuLogStep $run preflight Passed 'All selected targets passed collision checks. Collect local-account settings before starting restore.'
        Complete-SfsuLogRun $run Completed 'Target review completed; no restore ran.' | Out-Null
        [pscustomobject]@{Plans=$plans;ReportPath=$run.ReportPath;RunDirectory=$run.RunDirectory}
    } catch { Write-SfsuLogEvent -Run $run -Severity ERROR -Message $_.Exception.Message; Complete-SfsuLogRun $run Failed 'Target review stopped before any account/data changes.' | Out-Null; throw }
}

function Invoke-SfsuRestore {
    param([string]$PackageRoot,[object[]]$Backups,$Control=$null)
    $run=New-SfsuLogRun -PackageRoot $PackageRoot -Operation Restore -Steps @(@{Id='preflight';Title='Preflight every selected target'},@{Id='verify';Title='Verify every selected store before account/data changes'},@{Id='apply';Title='Restore selected identities'},@{Id='accounts';Title='Apply and verify requested local-account settings'}) -Label 'Native USMT restore. Existing accounts/profiles are never reused.'
    $created=New-Object Collections.Generic.List[object]; $errors=New-Object Collections.Generic.List[string]; $active='preflight'; $outcome='Failed'; $plans=@()
    $storeGuards=New-Object Collections.Generic.List[object]; $storeStreams=New-Object Collections.Generic.List[object]
    try {
        Start-SfsuLogStep $run preflight; Test-SfsuMigrationCancellation $Control
        $hostInfo=Assert-SfsuMigrationHost Restore; $tools=Get-SfsuToolset $PackageRoot $hostInfo.Architecture
        $plans=@(Get-SfsuRestorePlans -PackageRoot $PackageRoot -Backups $Backups -RequireOptions)
        foreach ($plan in $plans) { if ($plan.Manifest.Engine.ToolVersion -ne $tools.Version) { throw 'Use the same USMT build as capture; install the matching architecture payload before restore.' } }
        Complete-SfsuLogStep $run preflight Passed 'All selected targets and supplied account options passed. No account/data changes have occurred.'
        $active='verify'; Start-SfsuLogStep $run verify; $index=0
        # Hold every store and captured rule read-only from verification through
        # apply, closing the verify-then-change race without copying large stores.
        foreach ($plan in $plans) {
            $storeGuards.Add((Enter-SfsuPathGuard $plan.Path))
            $storeStreams.Add([Sfsu.SafeFiles]::Open((Join-Path $plan.Path 'Store/USMT/USMT.MIG'),$false,$false))
            foreach ($name in @('MigApp.xml','MigDocs.xml','SfsuPolicy.xml','Config.xml')) { $storeStreams.Add([Sfsu.SafeFiles]::Open((Join-Path $plan.PolicyDirectory $name),$false,$false)) }
        }
        foreach ($plan in $plans) {
            Test-SfsuMigrationCancellation $Control; $index++; $store=Join-Path $plan.Path 'Store/USMT/USMT.MIG'
            $log=Get-SfsuRawLogPath $run ('p'+$index+'-pre-restore-verify.log')
            Invoke-SfsuNativeTool -Tools $tools -Name usmtutils.exe -Arguments @('/verify:all',$store,('/l:'+$log)) -Run $run -StepId verify -Label ('Verify source store '+$index) -Log $log -Control $Control | Out-Null
            if ($plan.Manifest.Status -eq 'CapturedWithWarnings') { Write-SfsuLogEvent -Run $run -StepId verify -Severity WARNING -Message 'This store was captured with warnings/nonfatal errors. Restore cannot recover files that capture omitted.' }
        }
        Complete-SfsuLogStep $run verify Passed 'Every selected compressed store passed native verification before provisioning.'
        # Repeat all-target collision checks immediately before the first mutation.
        $plans=@(Get-SfsuRestorePlans -PackageRoot $PackageRoot -Backups $Backups -RequireOptions)
        $active='apply'; Start-SfsuLogStep $run apply
        foreach ($plan in $plans) {
            Test-SfsuMigrationCancellation $Control
            if ($plan.AccountType -eq 'Local') {
                $record=[pscustomobject]@{Plan=$plan;Sid='';Created=$false}
                $created.Add($record)
                $record.Sid=New-SfsuRestoreAccount $plan.AccountName $plan.LocalOptions.Password
                $record.Created=$true
                Write-SfsuLogEvent -Run $run -StepId apply -Message ('Created disabled local account '+$plan.AccountName+'. Password omitted from all reports/arguments.')
            }
        }
        $index=0
        foreach ($plan in $plans) {
            Test-SfsuMigrationCancellation $Control; $index++
            $lease=Enter-SfsuPathGuard $plan.Path; $hold=$null
            try {
                $store=Join-Path $plan.Path 'Store'; $hold=[Sfsu.SafeFiles]::Open((Join-Path $store 'USMT/USMT.MIG'),$false,$false)
                $log=Get-SfsuRawLogPath $run ('p'+$index+'-loadstate.log'); $progress=Get-SfsuRawLogPath $run ('p'+$index+'-load-progress.log')
                $arguments=@($store)+@(Get-SfsuRuleArguments $plan.PolicyDirectory)+@(Get-SfsuUserArguments $plan.ProfileSid)+@('/c','/r:2','/w:3','/v:5',('/l:'+$log),('/progress:'+$progress))
                if ($plan.AccountType -eq 'Local') { $arguments+=('/mu:'+$plan.Manifest.SourceComputer+'\'+$plan.AccountName+':'+$env:COMPUTERNAME+'\'+$plan.AccountName) }
                Invoke-SfsuNativeTool -Tools $tools -Name loadstate.exe -Arguments $arguments -Run $run -StepId apply -Label ('Restoring '+$plan.DisplayName+' ('+$index+'/'+$plans.Count+')') -Log $log -Progress $progress -Control $Control | Out-Null
                $expected=$plan.ProfileSid; if ($plan.AccountType -eq 'Local') { $expected=($created | Where-Object { $_.Plan.Path -eq $plan.Path }).Sid }
                if (@(Get-SfsuDestinationProfiles | Where-Object SID -eq $expected).Count -ne 1) { throw 'LoadState exited but the intended destination profile registration was not found. Restore verification failed.' }
                Write-SfsuCheckpoint -Run $run -StepId apply -Status Passed -Message ('Native apply ended and the intended destination SID/profile registration was found for '+$plan.DisplayName+'.')
            } finally { if ($hold) { $hold.Dispose() }; $lease.Dispose() }
        }
        Complete-SfsuLogStep $run apply Passed 'Native restores ended and destination profile registrations were verified.'
        $active='accounts'; Start-SfsuLogStep $run accounts
        foreach ($record in $created) {
            Test-SfsuMigrationCancellation $Control
            Set-SfsuRestoreAccountState $record.Plan $record.Sid
            Write-SfsuCheckpoint -Run $run -StepId accounts -Status Passed -Message ('Verified '+$record.Plan.AccountName+': Enabled='+$record.Plan.LocalOptions.Enabled+'; Administrators member='+$record.Plan.LocalOptions.Administrator+'.')
        }
        Write-SfsuCheckpoint -Run $run -StepId accounts -Status Warning -Message 'Intended-user sign-in, EFS-file decryption and application/browser fidelity have not been exercised by this administrator restore. Sign in as each restored user and validate before retiring the source.'
        Complete-SfsuLogStep $run accounts Passed 'Requested local-account settings were checked; domain-account memberships were not changed by the application.'
        $outcome='CompletedWithWarnings'; Complete-SfsuLogRun $run Completed 'Restore finished. Review native warnings and perform intended-user acceptance; partial results are never represented as a complete content comparison.' | Out-Null
    } catch {
        $outcome='Failed'; if ($_.Exception -is [OperationCanceledException]) { $outcome='Cancelled' }
        $errors.Add($_.Exception.Message)
        Write-SfsuLogEvent -Run $run -StepId $active -Severity ERROR -Message $errors[$errors.Count-1] -NextAction 'Accounts/data already created are preserved. Newly created local accounts are disabled on failure; resolve collisions manually before another attempt.'
        foreach ($record in $created) {
            # Never disable an account that another operator created after our
            # preflight. The native adapter handles its own post-create failure.
            try { if ($record.Created) { Disable-SfsuRestoreAccount $record.Plan.AccountName } }
            catch { Write-SfsuLogEvent -Run $run -StepId $active -Severity ERROR -Message 'Could not confirm disablement of a newly provisioned local account. Technician intervention is required.' }
        }
        Complete-SfsuLogRun $run $outcome 'Restore stopped. Existing source stores, partial destination data and account evidence were preserved; no rollback/deletion was attempted.' | Out-Null
    } finally {
        foreach ($stream in $storeStreams) { $stream.Dispose() }
        foreach ($guard in $storeGuards) { $guard.Dispose() }
        foreach ($plan in $plans) { try { Export-SfsuLogSnapshot $run $plan.Path | Out-Null } catch { $errors.Add('Report snapshot could not be copied; retain the root Logs report.') } }
        Set-SfsuMigrationProgress $Control ('Restore '+$outcome)
    }
    [pscustomobject]@{Outcome=$outcome;Errors=$errors.ToArray();ReportPath=$run.ReportPath;RunDirectory=$run.RunDirectory}
}

Export-ModuleMember -Function Invoke-SfsuCaptureReview,Invoke-SfsuCapture,Invoke-SfsuRestorePlanning,Invoke-SfsuRestore,Set-SfsuCaptureLocations
