# Offline combined sign-in: synthetic credentials only, no real UI/SMB/AD/USMT.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/combined-signin-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Test-Disposed($Credential) { try { [void]$Credential.Password.get_Length(); return $false } catch { return $true } }
$source=Join-Path $repository 'App/Scripts/Sfsu.Launch.psm1'
$module=Import-Module $source -Force -PassThru
& $module { function script:Read-SfsuWindowsCredential([string]$SharePath) { return $null } }
$entry=Join-Path $root ("entry & 'quotes' "+[char]0x6E2C+'.ps1')
[IO.File]::WriteAllText($entry,@'
param($LdapServer,$Scenario,[hashtable]$StartupSignIn)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'entry.json'),(ConvertTo-Json @{Server=$LdapServer;Scenario=$Scenario;Pid=$PID;Manual=($null -eq $StartupSignIn.Credential)}))
exit 7
'@)
$server='dc.example.invalid & ''literal'' $() ` "quotes"'
$arguments=& $module { param($p,$s) New-SfsuGuiBootstrapArguments $p $s Warnings } $entry $server
Assert-True ($arguments.Length -lt 30000) 'Compressed public code/configuration fits the bounded command line.'
function Invoke-Child([string]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments=$Arguments; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'Bootstrap fixture timed out.' }
        [pscustomobject]@{Code=$process.ExitCode;Id=$process.Id;Error=$stderr.GetAwaiter().GetResult();Output=$stdout.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}
$child=Invoke-Child $arguments
Assert-True ($child.Code -eq 7) ('Actual compressed/encoded bootstrap retains entry exit status: '+$child.Error)
$probe=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'entry.json')))
Assert-True ($probe.Server -ceq $server -and $probe.Scenario -eq 'Warnings' -and $probe.Pid -eq $child.Id -and $probe.Manual) 'Unicode/punctuation data and same-process manual handoff survive without a real credential prompt.'
Remove-Module $module

foreach ($name in @('Sfsu.Credentials.Native.cs','Sfsu.Identity.psm1','Sfsu.Identity.psd1')) { Copy-Item -LiteralPath (Join-Path $repository ('App/Scripts/'+$name)) -Destination $root }
$text=[IO.File]::ReadAllText($source)
$call="[void][Windows.Forms.MessageBox]::Show(`$message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)"
$marker=Join-Path $root 'message.json'
$replacement="[IO.File]::WriteAllText('"+$marker.Replace("'","''")+"',(ConvertTo-Json @{Message=`$message;Details=`$details}))"
if (-not $text.Contains($call)) { throw 'Bootstrap error UI seam missing.' }
$fixturePath=Join-Path $root 'FixtureLaunch.psm1'
[IO.File]::WriteAllText($fixturePath,$text.Replace($call,$replacement))
$fixture=Import-Module $fixturePath -Force -PassThru
foreach ($case in @('missing','blocked','constrained','policy')) {
    $package=Join-Path $root $case; [void][IO.Directory]::CreateDirectory((Join-Path $package 'App/Scripts'))
    if ($case -eq 'blocked') { [IO.File]::WriteAllText((Join-Path $package 'Logs'),'obstruction') }
    $argsLine=& $fixture { param($p) New-SfsuGuiBootstrapArguments $p 'dc.example.invalid' Completed } (Join-Path $package 'App/Scripts/Missing.ps1')
    if ($case -in @('constrained','policy')) {
        $code=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($argsLine -split ' ')[-1]))
        $prefix=if ($case -eq 'constrained') { '$ExecutionContext.SessionState.LanguageMode=''ConstrainedLanguage'';' } else { 'function Get-ExecutionPolicy { ''AllSigned'' };' }
        $argsLine='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix+$code))
    }
    $child=Invoke-Child $argsLine
    $expected=switch ($case) { 'constrained' { 77 }; 'policy' { 78 }; default { 79 } }
    Assert-True ($child.Code -eq $expected) ('Pre-entry failure retains its exit status: '+$child.Error)
    if ($case -in @('constrained','policy')) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $package 'Logs'))) 'Restrictions stop before native credential/share work.' }
    else {
        $message=ConvertFrom-Json ([IO.File]::ReadAllText($marker))
        if ($case -eq 'missing') { Assert-True (Test-Path -LiteralPath $message.Details) 'Pre-entry failure requests a graphical error and real saved details.' }
        else { Assert-True (-not $message.Details -and $message.Message -match 'could not be saved') 'Unavailable Logs retains a graphical error without claiming saved details.' }
    }
}
Remove-Module $fixture

$module=Import-Module $source -Force -PassThru
& $module {
    function script:Initialize-SfsuSignInAssets { }
    function script:Test-SfsuBootstrapEntryRead([string]$Path) {
        $script:Reads++
        if ($script:Case -in @('cancel-unreadable','conflict','network-error','still-unreadable') -or ($script:Reads -eq 1 -and $script:Case -in @('connect','file-denied','missing-file','retry'))) {
            if ($script:Case -eq 'file-denied') { throw [UnauthorizedAccessException]::new('Synthetic denial.') }
            throw [IO.FileNotFoundException]::new('Synthetic missing file.')
        }
    }
    function script:Test-SfsuBootstrapShareRead([string]$Path) { if ($script:Case -notin @('missing-file','file-denied')) { throw 'Synthetic unavailable share.' } }
    function script:Read-SfsuWindowsCredential([string]$SharePath) {
        $script:Prompts++
        if ($script:Case -like 'cancel-*') { return $null }
        $credential=[Management.Automation.PSCredential]::new('campus.user@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-fixture-secret').SecurePassword)
        $script:Candidates.Add($credential); return $credential
    }
    function script:Connect-SfsuBootstrapShare([string]$Path,$Credential) {
        $script:Connections++; $script:Share=$Path; $script:ShareCredential=$Credential
        if ($script:Case -in @('conflict','network-error') -or ($script:Case -eq 'retry' -and $script:Connections -eq 1)) { throw 'Synthetic connection failure; no existing connection removed.' }
    }
    function script:Confirm-SfsuSignInRetry([string]$Message) {
        $script:RetryRequests++; $disposed=$false
        try { [void]$script:Candidates[$script:Candidates.Count-1].Password.get_Length() } catch { $disposed=$true }
        if (-not $disposed) { throw 'Candidate was retained after failure.' }
        return ($script:Case -eq 'retry' -and $script:RetryRequests -eq 1)
    }
    function script:Wait-SfsuSignInRetry([int]$Failures) { $script:Waits++ }
    function script:Invoke-SfsuBootstrapEntry($EntryPath,$LdapServer,$Scenario,$SignIn) {
        $script:Launches++; $script:HandedCredential=$SignIn.Credential; $script:Manual=($null -eq $SignIn.Credential); return 0
    }
    function script:Show-SfsuBootstrapFailure($EntryPath,$Reason) { $script:Failure=$Reason }
}
function Invoke-Case([string]$Case,[string]$Path='\\synthetic.invalid\toolkit$\folder\App\Scripts\Start.ps1') {
    & $module {
        param($case,$path)
        $script:Case=$case; $script:Reads=0; $script:Prompts=0; $script:Connections=0; $script:Launches=0; $script:Waits=0; $script:RetryRequests=0
        $script:Share=''; $script:Failure=''; $script:Manual=$false; $script:HandedCredential=$null; $script:ShareCredential=$null
        $script:Candidates=[Collections.Generic.List[object]]::new()
        $code=Invoke-SfsuGuiBootstrap $path 'dc.example.invalid' Completed
        [pscustomobject]@{Code=$code;Prompts=$script:Prompts;Connections=$script:Connections;Launches=$script:Launches;Share=$script:Share;Failure=$script:Failure;Manual=$script:Manual;Waits=$script:Waits;Candidates=$script:Candidates.ToArray();SameCredential=[object]::ReferenceEquals($script:ShareCredential,$script:HandedCredential)}
    } $Case $Path
}
foreach ($case in @('connect','file-denied')) {
    $probe=Invoke-Case $case
    Assert-True ($probe.Code -eq 0 -and $probe.Prompts -eq 1 -and $probe.Connections -eq 1 -and $probe.Launches -eq 1 -and $probe.SameCredential) 'A single prompt supplies the exact same credential object to SMB and the app.'
    Assert-True ($probe.Share -ceq '\\synthetic.invalid\toolkit$' -and (Test-Disposed $probe.Candidates[0])) 'Only the share root is targeted and unclaimed credentials are disposed after app return.'
}
$probe=Invoke-Case accessible
Assert-True ($probe.Code -eq 0 -and $probe.Prompts -eq 1 -and $probe.Connections -eq 0 -and $probe.Launches -eq 1) 'Existing readable share access is reused without replacing or conflicting with its network identity; AD still gets one explicit credential.'
Assert-True (Test-Disposed $probe.Candidates[0]) 'Unclaimed AD credentials are disposed even when no new share connection was needed.'
$probe=Invoke-Case missing-file
Assert-True ($probe.Code -eq 79 -and $probe.Prompts -eq 0 -and $probe.Launches -eq 0) 'Missing files on an accessible share fail before credential collection.'
$probe=Invoke-Case cancel-readable
Assert-True ($probe.Code -eq 0 -and $probe.Manual -and $probe.Connections -eq 0 -and $probe.Launches -eq 1) 'Cancel can continue manually when exact toolkit access already exists.'
foreach ($case in @('cancel-unreadable','conflict','network-error','still-unreadable')) {
    $probe=Invoke-Case $case
    Assert-True ($probe.Code -eq 79 -and $probe.Launches -eq 0 -and $probe.Failure.Length -gt 0) 'Cancel, conflicts, connection failure and persistent unreadability cannot bypass required share access.'
    foreach ($candidate in $probe.Candidates) { Assert-True (Test-Disposed $candidate) 'Failed candidates are cleared before retry/manual decisions.' }
}
$probe=Invoke-Case retry
Assert-True ($probe.Code -eq 0 -and $probe.Prompts -eq 2 -and $probe.Connections -eq 2 -and $probe.Launches -eq 1 -and $probe.Waits -eq 1) 'Explicit retry collects a fresh credential after cooldown without an automatic password retry.'
Assert-True ((Test-Disposed $probe.Candidates[0]) -and (Test-Disposed $probe.Candidates[1])) 'Rejected and unclaimed successful credentials are both disposed.'
$probe=Invoke-Case accessible 'C:\toolkit\App\Scripts\Start.ps1'
Assert-True ($probe.Code -eq 0 -and $probe.Prompts -eq 1 -and $probe.Connections -eq 0) 'Local startup prompts for AD without a share connection.'
$probe=Invoke-Case accessible '\\?\C:\toolkit\Start.ps1'
Assert-True ($probe.Code -eq 79 -and $probe.Prompts -eq 0 -and $probe.Connections -eq 0) 'Device paths are rejected without credential work.'
Remove-Module $module

Add-Type -Path (Join-Path $repository 'App/Scripts/Sfsu.Credentials.Native.cs')
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SfsuCredentialPackFixture {
 [DllImport("credui.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] public static extern bool CredPackAuthenticationBufferW(uint flags,string user,string password,IntPtr buffer,ref uint size);
}
'@
$size=[uint32]0
[void][SfsuCredentialPackFixture]::CredPackAuthenticationBufferW(0,'campus.user@sfsu.edu','SYNTHETIC-fixture-secret',[IntPtr]::Zero,[ref]$size)
$buffer=[Runtime.InteropServices.Marshal]::AllocCoTaskMem($size)
try {
    Assert-True ([SfsuCredentialPackFixture]::CredPackAuthenticationBufferW(0,'campus.user@sfsu.edu','SYNTHETIC-fixture-secret',$buffer,[ref]$size)) 'Windows packs a local synthetic credential without a dialog.'
    $unpack=[Sfsu.SignIn.Native].GetMethod('Unpack',[Reflection.BindingFlags]'Static,NonPublic')
    $native=$unpack.Invoke($null,@($buffer,$size))
    Assert-True ($native.UserName -eq 'campus.user@sfsu.edu' -and $native.Password.IsReadOnly() -and [Net.NetworkCredential]::new('',$native.Password).Password -ceq 'SYNTHETIC-fixture-secret') 'Native unpack retains the exact username/password in a read-only SecureString.'
    $password=$native.TakePassword(); $native.Dispose()
    Assert-True ($password.Length -eq 24) 'Ownership transfer survives native-result disposal.'
    $password.Dispose()
} finally { for ($i=0;$i -lt $size;$i++) { [Runtime.InteropServices.Marshal]::WriteByte($buffer,$i,0) }; [Runtime.InteropServices.Marshal]::FreeCoTaskMem($buffer) }
$nativeText=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Sfsu.Credentials.Native.cs'))
Assert-True ($nativeText.Contains('out buffer,out size,ref save,1)') -and $nativeText.Contains('WNetAddConnection2W(ref resource,secret,user,0)') -and $nativeText.Contains('ZeroFreeGlobalAllocUnicode') -and -not $nativeText.Contains('WNetCancelConnection')) 'APIs request no save checkbox, secondary network UI, persistent mapping or disconnect, and clear temporary password memory.'

# Actual prompt-wrapper validation/ownership and connection error mapping,
# replacing the native API call boundaries only; no real dialog or connection.
$nativeCall='$result=[Sfsu.SignIn.Native]::Connect($SharePath,$Credential.UserName,$Credential.Password)'
if (-not $text.Contains($nativeCall)) { throw 'Explicit network API fixture seam missing.' }
$fixtureText=$text.Replace($nativeCall,'$result=$script:NativeResult')
$fixtureText=[regex]::Replace($fixtureText,'(?m)^    \$native=\[Sfsu.SignIn.Native\]::Prompt\([^\r\n]+\)\r?$','    $native=$script:PromptCandidate')
$apiPath=Join-Path $root 'ApiFixture.psm1'; [IO.File]::WriteAllText($apiPath,$fixtureText)
$api=Import-Module $apiPath -Force -PassThru
& $api { param($base) Import-Module (Join-Path $base 'Sfsu.Identity.psm1') -Force; $script:IdentityPolicy=Get-SfsuIdentityPolicy } $root
$constructor=[Sfsu.SignIn.Credential].GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0]
foreach ($user in @('p000000123@sfsu.edu','person@unconfigured.invalid','SFSU\person')) {
    $secret=[Net.NetworkCredential]::new('','SYNTHETIC-ui-secret').SecurePassword; $secret.MakeReadOnly()
    $native=$constructor.Invoke(@($user,$secret)); $credential=$null; $failure=''
    try { $credential=& $api { param($candidate) $script:PromptCandidate=$candidate; Read-SfsuWindowsCredential '\\synthetic.invalid\toolkit$' } $native } catch { $failure=$_.Exception.Message }
    if ($user -eq 'p000000123@sfsu.edu') {
        Assert-True ($credential.UserName -eq $user -and $null -eq $native.Password -and $credential.Password.get_Length() -gt 0) 'A valid Windows result transfers its SecureString to the PSCredential without retaining a native-result copy.'
        $credential.Password.Dispose()
    } else {
        $disposed=$false; try { [void]$secret.get_Length() } catch { $disposed=$true }
        Assert-True ($failure.Length -gt 0 -and $disposed -and $null -eq $native.Password) 'Rejected suffix/domain input clears the native credential before any network use.'
    }
}
$synthetic=[Management.Automation.PSCredential]::new('campus.user@sfsu.edu',[Net.NetworkCredential]::new('','SYNTHETIC-network-secret').SecurePassword)
try {
    foreach ($code in @(0,1219,53)) {
        $failure=''; try { & $api { param($code,$credential) $script:NativeResult=$code; Connect-SfsuBootstrapShare '\\synthetic.invalid\toolkit$' $credential } $code $synthetic } catch { $failure=$_.Exception.Message }
        $valid=switch($code) { 0 { -not $failure }; 1219 { $failure -match '1219' -and $failure -match 'No existing connection was removed' }; 53 { $failure -match 'Windows error 53' } }
        Assert-True $valid 'Explicit native connection success/conflict/network errors retain correct outcomes without a second credential prompt.'
    }
} finally { $synthetic.Password.Dispose(); Remove-Module $api }
Write-Output ("PASS: $script:Assertions combined-share bootstrap assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
