# Windows PowerShell 5.1; synthetic identities, loopback TLS only. No campus AD.
#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$sourcePath=Join-Path $repository 'tools/Test-SfsuLdaps.ps1'
$script:DiagnosticScriptPath=$sourcePath
$source=[IO.File]::ReadAllText($sourcePath)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load function definitions only; the diagnostic entry point is never invoked.
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message }
$outputParameter=$ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'OutputDirectory' }
Assert-True ($outputParameter.DefaultValue -is [Management.Automation.Language.StringConstantExpressionAst] -and $outputParameter.DefaultValue.Value -eq '') 'OutputDirectory parameter binding does not depend on PSScriptRoot or invoke Join-Path.'
$bindingProbe=[scriptblock]::Create($ast.ParamBlock.Extent.Text+"`r`n[pscustomobject]@{Root=`$PSScriptRoot;OutputDirectory=`$OutputDirectory}")
$bindingResult=& $bindingProbe
Assert-True ([string]::IsNullOrEmpty($bindingResult.Root) -and $bindingResult.OutputDirectory -eq '') 'Actual parameter block binds successfully when PSScriptRoot is empty.'
foreach ($badName in @('127.0.0.1','::1','server','https://dc.example.invalid','dc.example.invalid:636','dc.example.invalid.','-bad.example.invalid')) {
    Assert-Throws { Assert-DiagnosticDnsName $badName } ('Reject malformed/non-DNS endpoint '+$badName)
}
Assert-DiagnosticDnsName 'dc-01.ad.example.invalid'
Assert-True ((ConvertTo-DiagnosticLogin '000000123') -ceq '000000123@sfsu.edu') 'Normalize standard login without dropping zeros.'
foreach ($login in @('p000000123','P000000123@sfsu.edu','name@sfsu.edu')) {
    Assert-True ((ConvertTo-DiagnosticLogin $login) -like '*@sfsu.edu') 'Diagnostic uses generalized shared login policy.'
}
foreach ($badLogin in @('EXAMPLE\000000123','000000123@other.invalid')) {
    Assert-Throws { ConvertTo-DiagnosticLogin $badLogin } 'Reject nonstandard technician credentials.'
}
# Exercise the real prompt helper with a synthetic host. No GUI, terminal input
# or campus credential is involved; the password must use SecureString input.
$script:promptAccount='000000123'; $script:passwordPrompts=0; $script:emptyPassword=$false
function Read-Host {
    param([string]$Prompt,[switch]$AsSecureString)
    if ($AsSecureString) {
        $script:passwordPrompts++
        $text='SYNTHETIC-PROMPT-ONLY'
        if ($script:emptyPassword) { $text='' }
        return [Net.NetworkCredential]::new('',$text).SecurePassword
    }
    if ($Prompt -like '*password*') { throw 'Unexpected plaintext password prompt.' }
    return $script:promptAccount
}
$prompted=Read-DiagnosticCredential 'dc.example.invalid'
Assert-True ($prompted.UserName -eq '000000123@sfsu.edu' -and $prompted.Password.Length -gt 0 -and $script:passwordPrompts -eq 1) 'Same-window credential helper normalizes ID and reads password as SecureString.'
$prompted.Password.Dispose()
$script:promptAccount=''; $script:passwordPrompts=0
Assert-True ($null -eq (Read-DiagnosticCredential 'dc.example.invalid') -and $script:passwordPrompts -eq 0) 'Blank ID skips credentials before asking for password.'
$script:promptAccount='bad account'
Assert-Throws { Read-DiagnosticCredential 'dc.example.invalid' } 'Prompt rejects malformed login before password collection.'
Assert-True ($script:passwordPrompts -eq 0) 'Rejected ID never opens a password prompt.'
$script:promptAccount='000000123'; $script:emptyPassword=$true
Assert-Throws { Read-DiagnosticCredential 'dc.example.invalid' } 'Empty secure password cannot create a credential.'
Remove-Item Function:\Read-Host
Initialize-DiagnosticTls
Assert-True ($null -ne ('SfsuLdapsDiagnostic.TlsProbe' -as [type])) 'TLS helper compiles on Windows PowerShell 5.1.'

# A real untrusted loopback certificate must be rejected, with its details still
# available in the report. The certificate/key exist in memory, not a trust store.
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Threading.Tasks;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class SfsuDiagnosticLoopback {
    public static object RejectUntrusted(string host) {
        using (RSA rsa=RSA.Create(2048)) {
            var req=new CertificateRequest("CN=localhost",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
            var eku=new OidCollection(); eku.Add(new Oid("1.3.6.1.5.5.7.3.1"));
            req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(eku,false));
            using (var original=req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(2)))
            // Schannel on Framework needs a temporary key container. No
            // PersistKeySet flag is used; disposal removes the imported key.
            using (var cert=new X509Certificate2(original.Export(X509ContentType.Pfx), (string)null, X509KeyStorageFlags.DefaultKeySet)) {
                var listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
                int port=((IPEndPoint)listener.LocalEndpoint).Port;
                var server=Task.Run(delegate {
                    try { using (var client=listener.AcceptTcpClient()) using (var ssl=new SslStream(client.GetStream(),false)) {
                        ssl.AuthenticateAsServer(cert,false,SslProtocols.Tls12,false);
                    }} catch { }
                });
                try {
                    // Reflection keeps this helper independent of Add-Type's
                    // in-memory compiler assembly reference limitations.
                    Type probe=null;
                    foreach (var a in AppDomain.CurrentDomain.GetAssemblies()) {
                        probe=a.GetType("SfsuLdapsDiagnostic.TlsProbe"); if (probe!=null) break;
                    }
                    return probe.GetMethod("Run").Invoke(null,new object[]{host,port,3000});
                } finally { listener.Stop(); server.Wait(5000); }
            }
        }
    }
}
'@
$tls=[SfsuDiagnosticLoopback]::RejectUntrusted('localhost')
Assert-True ($tls.Status -ne 'Passed' -and $tls.Stage -eq 'TLS') 'Actual TLS rejects an untrusted server certificate.'
Assert-True ($tls.PolicyErrors -match 'RemoteCertificateChainErrors') 'Certificate policy error is preserved.'
Assert-True ($tls.Subject -eq 'CN=localhost' -and $tls.Thumbprint -and $tls.RevocationRequested) 'Failed TLS still captures certificate details and revocation request.'
$wrongName=[SfsuDiagnosticLoopback]::RejectUntrusted('127.0.0.1')
Assert-True ($wrongName.Status -ne 'Passed' -and $wrongName.PolicyErrors -match 'RemoteCertificateNameMismatch') 'Actual TLS rejects certificate hostname mismatch.'

# Isolate LDAP response fixtures. Never execute LdapConnection.Bind against AD.
Add-Type -AssemblyName System.DirectoryServices.Protocols
$script:fixtureSid='S-1-5-21-111111-222222-333333-1101'
$script:fixturePassword='SYNTHETIC-LDAPS-ONLY'
$credential=[Management.Automation.PSCredential]::new('000000123',[Net.NetworkCredential]::new('',$script:fixturePassword).SecurePassword)
Assert-True (-not [Management.Automation.PSSerializer]::Serialize($credential).Contains($script:fixturePassword)) 'Credential serialization does not contain a plaintext password.'
$script:fixtureId='000000123'; $script:fixtureUpn=''; $script:bindFails=$false; $script:queryFilters=@(); $script:disposed=$false
function New-Object {
    param([Parameter(Position=0)][string]$TypeName,[Parameter(Position=1)][object[]]$ArgumentList)
    if ($TypeName -eq 'System.DirectoryServices.Protocols.LdapConnection') {
        $fake=[pscustomobject]@{AuthType=$null;AutoBind=$true;Credential=$null;Timeout=$null
            SessionOptions=[pscustomobject]@{ProtocolVersion=0;ReferralChasing=$null;SecureSocketLayer=$false;Signing=$false;Sealing=$false
                SslInformation=[pscustomobject]@{Protocol=2048;AlgorithmIdentifier='Aes256';CipherStrength=256;HashStrength=256;ExchangeStrength=256}}}
        $fake | Add-Member ScriptMethod Bind { if ($script:bindFails) { throw [DirectoryServices.Protocols.LdapException]::new(49) } }
        $fake | Add-Member ScriptMethod Dispose { $script:disposed=$true }
        $fake | Add-Member ScriptMethod SendRequest {
            param($Request)
            $script:queryFilters+= $Request.Filter
            if ($Request.DistinguishedName -eq '') { return [pscustomobject]@{Entries=@([pscustomobject]@{Attributes=@{defaultNamingContext=@('DC=example,DC=invalid')}})} }
            $sid=[Security.Principal.SecurityIdentifier]::new($script:fixtureSid)
            $bytes=[byte[]]::new($sid.BinaryLength); $sid.GetBinaryForm($bytes,0)
            $attributes=@{objectSid=,([byte[]]$bytes);sAMAccountName=@($script:fixtureId);displayName=@('Synthetic Private Name');userPrincipalName=@($script:fixtureId+'@sfsu.edu')}
            if ($script:fixtureUpn) { $attributes.userPrincipalName=@($script:fixtureUpn) }
            return [pscustomobject]@{Entries=@([pscustomobject]@{Attributes=$attributes})}
        }
        $script:lastConnection=$fake
        return $fake
    }
    Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}
$data=@{Server='dc.example.invalid';Timeout=2;Credential=$credential;UseTls=$true;ProfileSid='';ExpectedAccountId=''}
$lookup=Invoke-DiagnosticDirectory $data
Assert-True ($lookup.Status -eq 'Passed' -and $lookup.Bind -eq 'Passed' -and $lookup.Lookup -eq 'Passed') 'Synthetic Kerberos LDAPS and SID round-trip succeed.'
Assert-True ($lookup.QueryScope -eq 'CredentialAccountSidRoundTripOnly') 'Self lookup does not claim source-profile verification.'
Assert-True ($script:lastConnection.AuthType -eq 'Kerberos' -and $script:lastConnection.SessionOptions.SecureSocketLayer -and -not $script:lastConnection.AutoBind) 'TLS uses explicit Kerberos without implicit binds.'
Assert-True ($lookup.ChannelBinding -like 'NotProven*') 'Successful LDAP never claims CBT enforcement.'
Assert-True ($lookup.LdapTls.ProtocolBits -eq '0x800' -and $lookup.LdapTls.Tls12Or13) 'Framework TLS 1.2 numeric protocol is recognized.'
Assert-True ($script:queryFilters[-1] -match 'objectSid=\\01' -and $script:disposed) 'Binary SID filter is escaped and connection disposed.'
$serialized=$lookup | ConvertTo-Json -Depth 10
foreach ($private in @($script:fixturePassword,$script:fixtureSid,'Synthetic Private Name','000000123')) {
    Assert-True (-not $serialized.Contains($private)) 'Result excludes password and returned personal identifiers.'
}
$data.ProfileSid=$script:fixtureSid; $data.ExpectedAccountId='p000000123'; $script:fixtureId='p000000123'; $script:queryFilters=@()
$lookup=Invoke-DiagnosticDirectory $data
Assert-True ($lookup.Status -eq 'Passed' -and $lookup.QueryScope -eq 'SuppliedProfileSidAndAccount' -and $script:queryFilters.Count -eq 2) 'Standard credential can verify separate p-account profile with exact SID.'
$script:fixtureId='000000123'
$lookup=Invoke-DiagnosticDirectory $data
Assert-True ($lookup.Status -eq 'Failed' -and -not $lookup.IdentityChecks.AccountIdMatches) 'Full prefixed account mismatch fails verification.'
$generalCredential=[Management.Automation.PSCredential]::new('a*(b)@sfsu.edu',$credential.Password)
$generalData=@{Server='dc.example.invalid';Timeout=2;Credential=$generalCredential;UseTls=$true;ProfileSid='';ExpectedAccountId=''}
$script:fixtureId='different.sam'; $script:fixtureUpn='a*(b)@sfsu.edu'; $script:queryFilters=@()
$generalLookup=Invoke-DiagnosticDirectory $generalData
Assert-True ($generalLookup.Status -eq 'Passed' -and $generalLookup.IdentityChecks.CredentialUpnMatches -and $script:queryFilters[1].Contains('userPrincipalName=a\2a\28b\29@sfsu.edu')) 'Credential lookup uses escaped literal UPN and accepts an independent SAM account name.'
$script:fixtureUpn='different.upn@sfsu.edu'
$generalMismatch=Invoke-DiagnosticDirectory $generalData
Assert-True ($generalMismatch.Status -eq 'Failed' -and -not $generalMismatch.IdentityChecks.CredentialUpnMatches) 'Credential SID round-trip refuses a mismatching returned UPN.'
$script:fixtureId='000000123'; $script:fixtureUpn=''
$script:bindFails=$true; $script:queryFilters=@()
$lookup=Invoke-DiagnosticDirectory $data
Assert-True ($lookup.Bind -eq 'Failed' -and $lookup.Failure.LdapCode -eq 49 -and $script:queryFilters.Count -eq 0) 'Credential rejection runs no directory query.'
$script:bindFails=$false; $script:fixtureId='p000000123'; $data.UseTls=$false
$lookup=Invoke-DiagnosticDirectory $data
Assert-True ($lookup.Status -eq 'Passed' -and $script:lastConnection.SessionOptions.Signing -and $script:lastConnection.SessionOptions.Sealing -and -not $script:lastConnection.SessionOptions.SecureSocketLayer) '389 comparison requires signing and sealing.'
Remove-Item Function:\New-Object

$testRoot=Join-Path $PSScriptRoot ('.work/ldaps-diagnostic-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($testRoot)
# The process helper gets its script path from script scope. Use a harmless
# fixture worker to test DPAPI pipe round-trip and actual forced termination.
$fixturePath=Join-Path $testRoot 'worker.ps1'
@'
param([string]$InternalWorker)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$data=[Management.Automation.PSSerializer]::Deserialize([Console]::In.ReadToEnd())
if ($data.Sleep) { Start-Sleep -Seconds 10 }
[pscustomobject]@{Status='Passed';CredentialType=$data.Credential.GetType().FullName;PasswordLength=$data.Credential.Password.Length} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8
$pipeResult=Invoke-DiagnosticWorker 'Directory' @{Sleep=$false;Credential=$credential} 10 $fixturePath
    Assert-True ($pipeResult.Status -eq 'Passed' -and $pipeResult.CredentialType -eq 'System.Management.Automation.PSCredential' -and $pipeResult.PasswordLength -eq $script:fixturePassword.Length) 'Secure credential survives redirected stdin serialization.'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $timeout=Invoke-DiagnosticWorker 'Directory' @{Sleep=$true;Credential=$credential} 1 $fixturePath
    Assert-True ($timeout.Status -eq 'WorkerTimedOut' -and $watch.Elapsed.TotalSeconds -lt 8) 'Hard deadline terminates a blocked child process.'

# Exercise the entire command orchestration with a fake worker, including an
# authentication rejection. No DNS, TCP, credential prompt or AD calls occur.
$injected=@'
function Invoke-DiagnosticWorker([string]$Mode,$Data,[int]$TimeoutSeconds) {
    switch ($Mode) {
        'Context' { return [pscustomobject]@{Status='Passed';Synthetic=$true} }
        'Transport' { return [pscustomobject]@{Status='Passed';Stage='Complete';Server=$Data.Server;Synthetic=$true} }
        'Directory' {
            if (Test-Path (Join-Path $OutputDirectory 'attempt.txt')) { throw 'Unexpected second credential attempt.' }
            [void][IO.Directory]::CreateDirectory($OutputDirectory)
            [IO.File]::WriteAllText((Join-Path $OutputDirectory 'attempt.txt'),'1')
            return [pscustomobject]@{Status='Failed';Stage='Bind';Bind='Failed';Failure=[pscustomobject]@{LdapCode=49};Synthetic=$true}
        }
    }
}
function Read-DiagnosticCredential { param($SelectedServer) [Management.Automation.PSCredential]::new('000000123',[Net.NetworkCredential]::new('','SYNTHETIC-ONLY').SecurePassword) }
'@
$fixtureSource=$source.Replace("if (`$PSVersionTable.PSEdition -ne 'Desktop')",$injected+"`r`nif (`$PSVersionTable.PSEdition -ne 'Desktop')")
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'tools'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
foreach ($name in @('Sfsu.Identity.psm1','Sfsu.Identity.psd1')) { Copy-Item -LiteralPath (Join-Path $repository ('App/Scripts/'+$name)) -Destination (Join-Path $testRoot 'App/Scripts') }
$commandFixture=Join-Path $testRoot 'tools/command.ps1'
[IO.File]::WriteAllText($commandFixture,$fixtureSource)
$fixtureOutput=Join-Path $testRoot 'output'
& (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $commandFixture -Server dc.example.invalid -BindServer dc.example.invalid -Compare389 -OutputDirectory $fixtureOutput | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Orchestration fixture failed.' }
$resultFile=Get-ChildItem -LiteralPath $fixtureOutput -Filter '*.json' | Select-Object -First 1
$result=Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
Assert-True ($result.Directory.Failure.LdapCode -eq 49 -and $null -eq $result.Comparison389 -and $result.Overall -eq 'DirectoryNotPassed') 'Full command skips 389 and all further binds after credential failure.'
Assert-True ($result.Transport.Count -eq 2 -and $result.Notes -match 'No further credential attempts') 'Full command checks explicit DC and domain alias while preserving stop reason.'
# Previously every full-command fixture supplied OutputDirectory, hiding the
# broken default. Exercise the omitted parameter from a different current folder.
$unrelatedDirectory=Join-Path $testRoot 'different-working-directory'
[void][IO.Directory]::CreateDirectory($unrelatedDirectory)
Push-Location -LiteralPath $unrelatedDirectory
try {
    & (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $commandFixture -Server dc.example.invalid -TransportOnly | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Default-output launch fixture failed.' }
} finally { Pop-Location }
$defaultReports=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'tools/LdapsDiagnostics') -Filter '*.json')
Assert-True ($defaultReports.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $unrelatedDirectory 'LdapsDiagnostics'))) 'Omitted output directory resolves beside the saved script, independent of working directory.'
$defaultResult=Get-Content -LiteralPath $defaultReports[0].FullName -Raw | ConvertFrom-Json
Assert-True ($defaultResult.Overall -eq 'TransportOnly' -and $null -eq $defaultResult.Directory) 'Default-output launch completes without credentials using offline transport fixtures.'
$invalid=[Management.Automation.PSCredential]::new('bad account',$credential.Password)
$rejected=Invoke-DiagnosticWorker 'Directory' @{Credential=$invalid;Server='never-contacted.example.invalid';UseTls=$true;Timeout=2;ProfileSid='';ExpectedAccountId=''} 10 $sourcePath
Assert-True ($rejected.Status -eq 'WorkerFailed' -and $rejected.Stage -eq 'Directory') 'Actual diagnostic worker rejects malformed credentials before any LDAP construction/bind.'
$rejectedJson=$rejected | ConvertTo-Json -Depth 8
Assert-True (-not $rejectedJson.Contains('p000000123') -and -not $rejectedJson.Contains($script:fixturePassword)) 'Actual worker failure excludes credential identifiers and secret.'
$credential.Password.Dispose()
Write-Output ('Passed '+$script:assertions+' LDAPS diagnostic assertions; synthetic LDAP and loopback TLS only.')
