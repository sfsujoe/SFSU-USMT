# Same-process AD validation/ownership/expiry tests with synthetic credentials.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $repository 'App/Scripts/Sfsu.Launch.psm1') -Force -PassThru
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Test-Disposed($Credential) { try { [void]$Credential.Password.get_Length(); return $false } catch { return $true } }
function New-TestCredential { [Management.Automation.PSCredential]::new('campus.user@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-auth-secret').SecurePassword) }
& $module {
    function script:Invoke-SfsuStartupDirectoryAuthentication($PackageRoot,$LdapServer,$Credential) {
        $script:Bindings++; $script:Bound.Add($Credential)
        if ($script:Case -eq 'fatal') { throw 'Synthetic journal failure.' }
        $success=$script:Case -eq 'accept' -or ($script:Case -eq 'retry' -and $script:Bindings -eq 2)
        @{Success=$success;DirectoryStatus=$(if($success){'Connected'}else{'Authentication failed'});ReportPath='synthetic-report.html'}
    }
    function script:Confirm-SfsuSignInRetry($Message) {
        $script:Decisions++
        $disposed=$false; try { [void]$script:Bound[$script:Bound.Count-1].Password.get_Length() } catch { $disposed=$true }
        if (-not $disposed) { throw 'An AD-rejected credential survived into retry UI.' }
        return ($script:Case -in @('retry','cancel-retry'))
    }
    function script:Wait-SfsuSignInRetry($Failures) { $script:Waits++ }
    function script:Get-SfsuStartupSignIn($EntryPath) {
        $script:Prompts++
        if ($script:Case -eq 'cancel-retry') { return @{Credential=$null;UseDirectory=$false;ReportPath=''} }
        @{Credential=[Management.Automation.PSCredential]::new('campus.user@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-retry-secret').SecurePassword);UseDirectory=$false;ReportPath=''}
    }
}
foreach ($case in @('accept','reject','retry','cancel-retry','fatal','manual')) {
    $candidate=New-TestCredential
    $state=@{Credential=$candidate;UseDirectory=$true;ReportPath=''}
    if ($case -eq 'manual') { $candidate.Password.Dispose(); $state.Credential=$null }
    $result=& $module {
        param($case,$state)
        $script:Case=$case; $script:Bindings=0; $script:Prompts=0; $script:Decisions=0; $script:Waits=0
        $script:Bound=[Collections.Generic.List[object]]::new(); $failure=''; $result=$null
        try { $result=Complete-SfsuStartupSignIn $state 'C:\toolkit\App\Scripts\Start.ps1' 'C:\toolkit' 'dc.example.invalid' } catch { $failure=$_.Exception.Message }
        [pscustomobject]@{State=$result;Failure=$failure;Bindings=$script:Bindings;Prompts=$script:Prompts;Waits=$script:Waits;Bound=$script:Bound.ToArray()}
    } $case $state
    if ($case -ne 'fatal' -and $result.Failure) { throw ('Unexpected synthetic authentication failure: '+$result.Failure) }
    switch ($case) {
        accept {
            Assert-True ($result.State.UseDirectory -and [object]::ReferenceEquals($result.State.Credential,$candidate) -and $result.Bindings -eq 1 -and $result.Prompts -eq 0) 'Existing bootstrap credentials are explicitly validated once and retained without another prompt.'
            Assert-True ($result.State.ReportPath -eq 'synthetic-report.html' -and -not (Test-Disposed $candidate)) 'Successful AD evidence/report and the original live credential are handed to the UI.'
        }
        reject {
            Assert-True (-not $result.State.UseDirectory -and $null -eq $result.State.Credential -and (Test-Disposed $candidate) -and $result.Bindings -eq 1) 'AD failure cannot be promoted to connected merely because SMB succeeded; explicit Cancel continues manually.'
        }
        retry {
            Assert-True ($result.State.UseDirectory -and $result.Bindings -eq 2 -and $result.Prompts -eq 1 -and $result.Waits -eq 1) 'AD retry requires user choice, cooldown and a fresh combined sign-in.'
            Assert-True ((Test-Disposed $candidate) -and -not [object]::ReferenceEquals($candidate,$result.State.Credential)) 'AD retry disposes the rejected credential and retains only the replacement.'
        }
        cancel-retry {
            Assert-True (-not $result.State.UseDirectory -and $null -eq $result.State.Credential -and $result.Bindings -eq 1 -and $result.State.ReportPath -eq 'synthetic-report.html') 'Cancelling a retry preserves manual mode and the failed authentication report without a second bind.'
        }
        fatal {
            Assert-True ($result.Failure -match 'Review Logs' -and (Test-Disposed $candidate) -and $result.Bindings -eq 1) 'Unexpected authentication/journal failure stops startup and disposes the candidate.'
        }
        manual {
            Assert-True (-not $result.State.UseDirectory -and $result.Bindings -eq 0 -and $result.Prompts -eq 0) 'Manual startup performs no implicit/default directory authentication.'
        }
    }
    if ($null -ne $result.State) { & $module { param($s) Clear-SfsuStartupSignIn $s } $result.State }
}
Remove-Module $module

# Run actual UI seed/expiry functions without constructing UI or discovering users.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'App/Scripts/Sfsu.Ui.ps1'),[ref]$tokens,[ref]$errors)
foreach ($name in @('Start-SfsuInitialUi','Test-SfsuCredentialExpiry','Clear-SfsuDirectoryCredential')) {
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:Started=''; $script:OldPrompts=0
function Start-SfsuUiTask($Action) { $script:Started=$Action }
function Show-SfsuDirectoryCredentials { $script:OldPrompts++ }
$candidate=New-TestCredential
$script:SfsuStartupSignIn=@{Credential=$candidate;UseDirectory=$true;ReportPath='synthetic-report.html'}
$script:SfsuUi=@{Credential=$null;UseDirectory=$false;DirectoryLastUsedUtc=[DateTime]::MinValue;CredentialIdleMinutes=10;Worker=$null;Status=[pscustomobject]@{Text=''};Open=[pscustomobject]@{Enabled=$false};LatestReport=''}
Start-SfsuInitialUi
Assert-True ([object]::ReferenceEquals($script:SfsuUi.Credential,$candidate) -and $null -eq $script:SfsuStartupSignIn.Credential -and $script:SfsuUi.UseDirectory) 'UI takes ownership rather than copying the credential or leaving an original in bootstrap state.'
Assert-True ($script:Started -eq 'Discover profiles' -and $script:OldPrompts -eq 0 -and $script:SfsuUi.Open.Enabled -and $script:SfsuUi.LatestReport -eq 'synthetic-report.html') 'Verified startup skips the old AD form and starts discovery with the authentication report.'
Assert-True (Test-SfsuCredentialExpiry ([DateTime]::UtcNow.AddMinutes(11))) 'The transferred credential still expires after the existing ten-minute idle limit.'
Assert-True ((Test-Disposed $candidate) -and $null -eq $script:SfsuUi.Credential -and -not $script:SfsuUi.UseDirectory) 'Expiry disposes the actual transferred SecureString and returns to manual mode.'
$script:SfsuStartupSignIn=@{Credential=$null;UseDirectory=$false;ReportPath=''}; $script:Started=''
Start-SfsuInitialUi
Assert-True ($script:Started -eq 'Discover profiles' -and $script:OldPrompts -eq 0 -and -not $script:SfsuUi.UseDirectory) 'An explicit manual bootstrap decision does not trigger an unwanted second login form.'
$script:SfsuStartupSignIn=$null
Start-SfsuInitialUi
Assert-True ($script:OldPrompts -eq 1) 'Standalone UI callers without bootstrap state retain the existing sign-in behavior.'

# Real entry-point integration in an isolated package. Only Windows token,
# directory responses and modal UI are replaced. The carrier stays an object
# inside this child; its command line contains only a test wrapper file path.
$work=Join-Path $PSScriptRoot ('.work/signin-entry-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($work)
$launchPath=Join-Path $repository 'App/Scripts/Sfsu.Launch.psm1'
$launchText=[IO.File]::ReadAllText($launchPath)
$launchAst=[Management.Automation.Language.Parser]::ParseFile($launchPath,[ref]$tokens,[ref]$errors)
foreach ($name in @('Test-SfsuAdministrator','Invoke-SfsuStartupDirectoryAuthentication','Confirm-SfsuSignInRetry')) {
    $extent=$launchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true).Extent.Text
    $replacement=switch ($name) {
        'Test-SfsuAdministrator' { 'function Test-SfsuAdministrator { $true }' }
        'Confirm-SfsuSignInRetry' { 'function Confirm-SfsuSignInRetry { $false }' }
        default { 'function Invoke-SfsuStartupDirectoryAuthentication($PackageRoot,$LdapServer,$Credential) { $global:SyntheticBinds++; @{Success=$PackageRoot.EndsWith(''accept'');ReportPath=''synthetic-report.html'';DirectoryStatus=''Synthetic result''} }' }
    }
    $launchText=$launchText.Replace($extent,$replacement)
}
$entryText=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1'))
$message="[void][Windows.Forms.MessageBox]::Show(`$message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)"
$entryText=$entryText.Replace($message,"[IO.File]::WriteAllText((Join-Path `$packageRoot 'unexpected-error.txt'),`$message)")
$seedFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-SfsuInitialUi'},$true).Extent.Text
foreach ($case in @('accept','manual')) {
    $package=Join-Path $work $case; $scripts=Join-Path $package 'App/Scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Launch.psm1'),$launchText)
    [IO.File]::WriteAllText((Join-Path $scripts 'Start-SfsuUsmt.ps1'),$entryText)
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Logging.psm1'),'# Synthetic logger import; no employee/runtime reporting.')
    $uiProbe=@'
$script:SfsuUi=@{Credential=$null;UseDirectory=$false;DirectoryLastUsedUtc=[DateTime]::MinValue;Open=[pscustomobject]@{Enabled=$false};LatestReport=''}
function Show-SfsuDirectoryCredentials { throw 'Unexpected duplicate AD prompt.' }
function Start-SfsuUiTask($Action) {
 [IO.File]::WriteAllText((Join-Path $packageRoot 'ui-result.json'),(ConvertTo-Json @{Action=$Action;Connected=$script:SfsuUi.UseDirectory;Binds=$global:SyntheticBinds;CarrierEmpty=($null -eq $script:SfsuStartupSignIn.Credential);Pid=$PID}))
 if($null -ne $script:SfsuUi.Credential) { $script:SfsuUi.Credential.Password.Dispose(); $script:SfsuUi.Credential=$null }
}
Start-SfsuInitialUi
'@
    [IO.File]::WriteAllText((Join-Path $scripts 'Sfsu.Ui.ps1'),$seedFunction+"`r`n"+$uiProbe)
    $wrapper=Join-Path $package 'wrapper.ps1'
    [IO.File]::WriteAllText($wrapper,@'
$global:SyntheticBinds=0
$candidate=[Management.Automation.PSCredential]::new('campus.user@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-entry-secret').SecurePassword)
$state=@{Credential=$candidate;UseDirectory=$false;ReportPath=''}
& (Join-Path $PSScriptRoot 'App/Scripts/Start-SfsuUsmt.ps1') -StartupSignIn $state
$disposed=$false; try { [void]$candidate.Password.get_Length() } catch { $disposed=$true }
if(-not $disposed) { throw 'Entry/UI did not dispose the synthetic credential.' }
'@)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$wrapper+'"'; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardError=$true; $start.RedirectStandardOutput=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stderr=$process.StandardError.ReadToEndAsync(); $stdout=$process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Entry integration fixture timed out.' }
        $errorText=$stderr.GetAwaiter().GetResult(); [void]$stdout.GetAwaiter().GetResult()
        Assert-True ($process.ExitCode -eq 0) ('Actual entry validates/hands off/disposes the synthetic credential: '+$errorText)
        $result=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $package 'ui-result.json')))
        Assert-True ($result.Connected -eq ($case -eq 'accept') -and $result.Binds -eq 1 -and $result.CarrierEmpty -and $result.Pid -eq $process.Id -and $result.Action -eq 'Discover profiles') 'Actual entry and actual UI seed use independent AD evidence in the same process without another login or retained credential copy.'
    } finally { $process.Dispose() }
}
Write-Output ("PASS: $script:Assertions combined-sign-in assertions on PowerShell "+$PSVersionTable.PSVersion)
