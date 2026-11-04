#requires -Version 5.1
<#
.SYNOPSIS
Read-only Windows PowerShell diagnostic for SFSU LDAPS and Kerberos LDAP.
.DESCRIPTION
No RSAT/ADWS or domain membership required for discovery. Uses DNS SRV records,
strict TLS certificate validation with revocation checking, explicit standard
credentials, Kerberos only, and exact-account/SID searches. Credentials are sent
to one selected DC only; no automatic password retries or authentication fallback.
Child processes bound DNS/TLS/LDAP execution, including native blocking calls.
See docs/LDAPS-DIAGNOSTIC.md for evidence limits and server-side CBT checks.
.EXAMPLE
.\Test-SfsuLdaps.ps1 -BindServer DCS01.ad.sfsu.edu -Compare389
.EXAMPLE
.\Test-SfsuLdaps.ps1 -Server DCS01.ad.sfsu.edu,DCS01-DR.ad.sfsu.edu -TransportOnly
#>
[CmdletBinding()]
param(
    [string]$Domain = 'ad.sfsu.edu',
    [string[]]$Server = @(),
    [string]$Site = '',
    [string]$BindServer = '',
    [Management.Automation.PSCredential]$Credential,
    [string]$ProfileSid = '',
    [string]$ExpectedAccountId = '',
    [switch]$TransportOnly,
    [switch]$Compare389,
    [ValidateRange(2,30)][int]$OperationTimeoutSeconds = 8,
    [ValidateRange(15,180)][int]$WorkerTimeoutSeconds = 45,
    [string]$OutputDirectory = '',
    [Parameter(DontShow)][ValidateSet('','Discovery','Context','Transport','Directory')][string]$InternalWorker = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the saved script once, after parameter binding. Editor/selection hosts
# can leave PSScriptRoot empty while evaluating parameter defaults. Workers must
# reopen this exact saved file, so never guess a path from the working directory.
$script:DiagnosticScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:DiagnosticScriptPath) -and $MyInvocation.MyCommand.PSObject.Properties['Path']) {
    $script:DiagnosticScriptPath = [string]$MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($script:DiagnosticScriptPath)) {
    throw 'Run the entire saved Test-SfsuLdaps.ps1 file using powershell.exe -File <full-script-path>. Running a pasted block or editor selection does not provide the file path required by its workers.'
}
$script:DiagnosticScriptPath = [IO.Path]::GetFullPath($script:DiagnosticScriptPath)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path ([IO.Path]::GetDirectoryName($script:DiagnosticScriptPath)) 'LdapsDiagnostics'
}

function Assert-DiagnosticDnsName([string]$Name) {
    $parsedIp = $null
    if ($Name.Length -gt 253 -or $Name -notmatch '^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' -or
        [Net.IPAddress]::TryParse($Name,[ref]$parsedIp)) { throw 'Use a fully qualified DNS hostname, without a port, path, IP address or trailing dot.' }
}

function ConvertTo-DiagnosticLogin([string]$Name) {
    $nameValue = $Name.Trim()
    if ($nameValue -match '^\d{1,32}$') { return ($nameValue+'@sfsu.edu') }
    if ($nameValue -match '^\d{1,32}@sfsu\.edu$') { return $nameValue.ToLowerInvariant() }
    throw 'Use a standard numeric SFSU ID, optionally followed by @sfsu.edu. Power-user credentials are not allowed.'
}

function Read-DiagnosticCredential([string]$SelectedServer) {
    # Get-Credential can open a background modal window in Windows PowerShell.
    # Keep both prompts in this host and never read the password as plain text.
    Write-Host ('Waiting for credentials in this PowerShell window for '+$SelectedServer+'.')
    $account=Read-Host 'Standard SFSU ID (blank to skip directory tests)'
    if ([string]::IsNullOrWhiteSpace($account)) { return $null }
    $login=ConvertTo-DiagnosticLogin $account
    $password=Read-Host 'SFSU password' -AsSecureString
    if ($null -eq $password -or $password.Length -eq 0) {
        if ($null -ne $password) { $password.Dispose() }
        throw 'Password is empty; no credentials submitted.'
    }
    try { [Management.Automation.PSCredential]::new($login,$password) }
    catch { $password.Dispose(); throw }
}

function Get-DiagnosticFailure($ErrorRecord) {
    $failure = $ErrorRecord.Exception
    while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    $ldapCode = $null
    if ($failure.GetType().FullName -eq 'System.DirectoryServices.Protocols.LdapException') { $ldapCode = $failure.ErrorCode }
    $resultCode = $null
    if ($failure.GetType().FullName -eq 'System.DirectoryServices.Protocols.DirectoryOperationException' -and $null -ne $failure.Response) { $resultCode = [string]$failure.Response.ResultCode }
    # Raw exception messages/server diagnostics can contain account identifiers.
    [pscustomobject]@{ Type=$failure.GetType().FullName; HResult=$failure.HResult; LdapCode=$ldapCode; ResultCode=$resultCode }
}

function Initialize-DiagnosticTls {
    if ('SfsuLdapsDiagnostic.TlsProbe' -as [type]) { return }
    # A compiled callback can run safely on SslStream's background TLS threads.
    # It records certificate evidence and REJECTS every reported policy error.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Security.Authentication.ExtendedProtection;
namespace SfsuLdapsDiagnostic {
    public sealed class TlsResult {
        public string Server, Stage="TCP", Status="Failed", ErrorType, SocketError;
        public int HResult, NativeErrorCode;
        public string LocalAddress, RemoteAddress, PolicyErrors, Subject, Issuer, Thumbprint;
        public string NotBeforeUtc, NotAfterUtc, San, Protocol, Cipher, Hash, KeyExchange;
        public int CipherBits, HashBits, KeyExchangeBits, DaysRemaining;
        public bool Encrypted, Signed, EndpointChannelBindingAvailable;
        public bool RevocationRequested=true;
        public string[] Eku=new string[0], ChainStatus=new string[0];
    }
    public static class TlsProbe {
        public static TlsResult Run(string host, int port, int timeoutMs) {
            TlsResult r=new TlsResult(); r.Server=host;
            using (TcpClient tcp=new TcpClient()) {
                SslStream ssl=null;
                try {
                    IAsyncResult connect=tcp.BeginConnect(host,port,null,null);
                    using (var wait=connect.AsyncWaitHandle) {
                        if (!wait.WaitOne(timeoutMs)) throw new TimeoutException();
                        tcp.EndConnect(connect);
                    }
                    r.LocalAddress=((IPEndPoint)tcp.Client.LocalEndPoint).Address.ToString();
                    r.RemoteAddress=((IPEndPoint)tcp.Client.RemoteEndPoint).Address.ToString();
                    r.Stage="TLS";
                    ssl=new SslStream(tcp.GetStream(),false,delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                        r.PolicyErrors=errors.ToString();
                        var statuses=new List<string>();
                        if (chain!=null) foreach (X509ChainStatus s in chain.ChainStatus) statuses.Add(s.Status.ToString());
                        r.ChainStatus=statuses.ToArray();
                        if (cert!=null) using (X509Certificate2 c=new X509Certificate2(cert)) {
                            r.Subject=c.Subject; r.Issuer=c.Issuer; r.Thumbprint=c.Thumbprint;
                            r.NotBeforeUtc=c.NotBefore.ToUniversalTime().ToString("o");
                            r.NotAfterUtc=c.NotAfter.ToUniversalTime().ToString("o");
                            r.DaysRemaining=(int)Math.Floor((c.NotAfter.ToUniversalTime()-DateTime.UtcNow).TotalDays);
                            var eku=new List<string>();
                            foreach (X509Extension e in c.Extensions) {
                                if (e.Oid.Value=="2.5.29.17") r.San=e.Format(false);
                                if (e.Oid.Value=="2.5.29.37") {
                                    var ext=new X509EnhancedKeyUsageExtension(e,e.Critical);
                                    foreach (var oid in ext.EnhancedKeyUsages) eku.Add(oid.Value);
                                }
                            }
                            r.Eku=eku.ToArray();
                        }
                        return errors==SslPolicyErrors.None;
                    });
                    // TLS 1.2 is explicit for the Windows PowerShell 5.1 baseline.
                    // This is not a TLS 1.3 capability test. Revocation is enabled.
                    var handshake=ssl.AuthenticateAsClientAsync(host,null,SslProtocols.Tls12,true);
                    if (!handshake.Wait(timeoutMs)) throw new TimeoutException();
                    handshake.GetAwaiter().GetResult();
                    r.Protocol=ssl.SslProtocol.ToString(); r.Encrypted=ssl.IsEncrypted; r.Signed=ssl.IsSigned;
                    r.Cipher=ssl.CipherAlgorithm.ToString(); r.CipherBits=ssl.CipherStrength;
                    r.Hash=ssl.HashAlgorithm.ToString(); r.HashBits=ssl.HashStrength;
                    r.KeyExchange=ssl.KeyExchangeAlgorithm.ToString(); r.KeyExchangeBits=ssl.KeyExchangeStrength;
                    try {
                        using (var binding=ssl.TransportContext.GetChannelBinding(ChannelBindingKind.Endpoint)) {
                            r.EndpointChannelBindingAvailable=binding!=null && !binding.IsInvalid;
                        }
                    } catch { }
                    if (!r.Encrypted || !r.Signed) throw new AuthenticationException();
                    r.Stage="Complete"; r.Status="Passed";
                } catch (Exception e) {
                    while (e.InnerException!=null) e=e.InnerException;
                    r.ErrorType=e.GetType().FullName;
                    r.HResult=e.HResult;
                    var native=e as System.ComponentModel.Win32Exception;
                    if (native!=null) r.NativeErrorCode=native.NativeErrorCode;
                    SocketException socket=e as SocketException;
                    if (socket!=null) r.SocketError=socket.SocketErrorCode.ToString();
                    if (e is TimeoutException) r.Status="TimedOut";
                } finally { if (ssl!=null) ssl.Dispose(); }
            }
            return r;
        }
    }
}
'@
}

function Invoke-DiagnosticDirectory($InputData) {
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $login = ConvertTo-DiagnosticLogin $InputData.Credential.UserName
    $useTls = [bool]$InputData.UseTls
    $port = 389
    if ($useTls) { $port = 636 }
    $r = [ordered]@{ Server=$InputData.Server; Port=$port; AuthType='Kerberos'; Stage='Configuration'; Status='Failed'; StartedUtc=[DateTime]::UtcNow.ToString('o'); FinishedUtc=$null
        Bind='NotRun'; RootDse='NotRun'; Lookup='NotRun'; QueryScope='NotRun'; IdentityChecks=$null
        LdapTls=$null; ChannelBinding='NotProven: client success cannot establish server CBT enforcement.'; Failure=$null }
    $ldap = $null
    try {
        $id = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier([string]$InputData.Server,$port,$true,$false)
        $ldap = New-Object System.DirectoryServices.Protocols.LdapConnection($id)
        $ldap.AuthType = [DirectoryServices.Protocols.AuthType]::Kerberos
        $ldap.AutoBind = $false
        $ldap.Credential = [Net.NetworkCredential]::new($login,$InputData.Credential.Password)
        $ldap.Timeout = [TimeSpan]::FromSeconds($InputData.Timeout)
        $ldap.SessionOptions.ProtocolVersion = 3
        $ldap.SessionOptions.ReferralChasing = [DirectoryServices.Protocols.ReferralChasingOptions]::None
        $ldap.SessionOptions.SecureSocketLayer = $useTls
        if (-not $useTls) { $ldap.SessionOptions.Signing=$true; $ldap.SessionOptions.Sealing=$true }
        # No certificate callback is installed on LdapConnection: retain Windows
        # LDAP certificate/name validation. The strict SslStream check is separate.
        $r.Stage='Bind'
        $ldap.Bind()
        $r.Bind='Passed'
        if ($useTls) {
            $r.Stage='LdapTls'
            $info = $ldap.SessionOptions.SslInformation
            $protocolBits=[int]$info.Protocol
            # Framework's SecurityProtocol enum predates TLS 1.2 names. Record
            # Schannel bits as well as its potentially numeric enum rendering.
            $modernTls=($protocolBits -band 0x3C00) -ne 0
            $r.LdapTls = [ordered]@{ Protocol=[string]$info.Protocol; ProtocolBits=('0x{0:X}' -f $protocolBits); Tls12Or13=$modernTls; CipherAlgorithm=[string]$info.AlgorithmIdentifier
                CipherBits=$info.CipherStrength; HashBits=$info.HashStrength; KeyExchangeBits=$info.ExchangeStrength }
            if (-not $modernTls -or $info.CipherStrength -lt 128) { throw 'LDAP negotiated obsolete TLS or insufficient encryption; queries stopped.' }
        }
        $r.Stage='RootDSE'
        $request = New-Object DirectoryServices.Protocols.SearchRequest
        $request.DistinguishedName=''; $request.Filter='(objectClass=*)'; $request.Scope='Base'
        foreach ($attribute in @('defaultNamingContext','dnsHostName','supportedSASLMechanisms')) { [void]$request.Attributes.Add($attribute) }
        $request.TimeLimit=[TimeSpan]::FromSeconds($InputData.Timeout); $request.SizeLimit=2
        $response=$ldap.SendRequest($request)
        if ($response.Entries.Count -ne 1 -or -not $response.Entries[0].Attributes.Contains('defaultNamingContext')) { throw 'Unexpected RootDSE response.' }
        $base=[string]$response.Entries[0].Attributes['defaultNamingContext'][0]
        $r.RootDse='Passed'
        $r.Stage='Lookup'
        $expectedId=($login -split '@')[0]
        $expectedSid=[string]$InputData.ProfileSid
        $scope='CredentialAccountSidRoundTripOnly'
        if ($expectedSid) { $scope='SuppliedProfileSidAndAccount'; $expectedId=[string]$InputData.ExpectedAccountId }
        $r.QueryScope=$scope
        # Without a source-profile SID, first read only the credential account;
        # then round-trip that SID. Do not claim this verifies a source profile.
        if (-not $expectedSid) {
            $own=New-Object DirectoryServices.Protocols.SearchRequest
            $own.DistinguishedName=$base; $own.Scope='Subtree'
            $own.Filter='(&(objectCategory=person)(objectClass=user)(sAMAccountName='+$expectedId+'))'
            [void]$own.Attributes.Add('objectSid'); $own.SizeLimit=2; $own.TimeLimit=[TimeSpan]::FromSeconds($InputData.Timeout)
            $found=$ldap.SendRequest($own)
            if ($found.Entries.Count -ne 1 -or -not $found.Entries[0].Attributes.Contains('objectSid')) { throw 'Credential account did not return exactly one SID.' }
            $sidObject=[Security.Principal.SecurityIdentifier]::new([byte[]]$found.Entries[0].Attributes['objectSid'][0],0)
            $expectedSid=$sidObject.Value
        }
        $sidObject=New-Object Security.Principal.SecurityIdentifier($expectedSid)
        $bytes=New-Object byte[] $sidObject.BinaryLength; $sidObject.GetBinaryForm($bytes,0)
        $escaped=($bytes | ForEach-Object { '\'+$_.ToString('x2') }) -join ''
        $query=New-Object DirectoryServices.Protocols.SearchRequest
        $query.DistinguishedName=$base; $query.Scope='Subtree'
        $query.Filter='(&(objectCategory=person)(objectClass=user)(objectSid='+$escaped+'))'
        foreach ($attribute in @('objectSid','sAMAccountName','userPrincipalName','displayName')) { [void]$query.Attributes.Add($attribute) }
        $query.TimeLimit=[TimeSpan]::FromSeconds($InputData.Timeout); $query.SizeLimit=2
        $found=$ldap.SendRequest($query)
        if ($found.Entries.Count -ne 1) { throw 'SID query did not return exactly one account.' }
        $entry=$found.Entries[0]
        foreach ($required in @('objectSid','sAMAccountName','userPrincipalName','displayName')) {
            if (-not $entry.Attributes.Contains($required)) { throw 'Required identity attribute missing.' }
        }
        $returnedSid=[Security.Principal.SecurityIdentifier]::new([byte[]]$entry.Attributes['objectSid'][0],0).Value
        $checks=[ordered]@{ ExactlyOneResult=$true; SidMatches=($returnedSid -eq $expectedSid)
            AccountIdMatches=([string]$entry.Attributes['sAMAccountName'][0] -ieq $expectedId)
            UpnMatchesConvention=([string]$entry.Attributes['userPrincipalName'][0] -ieq ($expectedId+'@sfsu.edu'))
            DisplayNamePresent=(-not [string]::IsNullOrWhiteSpace([string]$entry.Attributes['displayName'][0])) }
        $r.IdentityChecks=$checks
        if (-not $checks.SidMatches -or -not $checks.AccountIdMatches -or -not $checks.DisplayNamePresent) { throw 'Directory identity checks failed.' }
        $r.Lookup='Passed'; $r.Stage='Complete'; $r.Status='Passed'
    } catch {
        if ($r.Stage -eq 'Bind') { $r.Bind='Failed' }
        if ($r.Stage -eq 'RootDSE') { $r.RootDse='Failed' }
        if ($r.Stage -eq 'Lookup') { $r.Lookup='Failed' }
        $r.Failure=Get-DiagnosticFailure $_
    } finally { if ($null -ne $ldap) { $ldap.Dispose() } }
    $r.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    [pscustomobject]$r
}

function Invoke-DiagnosticWorker([string]$Mode, $Data, [int]$TimeoutSeconds, [string]$ScriptPath = $script:DiagnosticScriptPath) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $PSHOME 'powershell.exe'
    # Only script path and fixed worker mode are command arguments. Payload,
    # including a DPAPI-protected serialized PSCredential, uses redirected stdin.
    $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$ScriptPath+'" -InternalWorker '+$Mode
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    $started=$false
    try {
        [void]$process.Start()
        $started=$true
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write([Management.Automation.PSSerializer]::Serialize($Data))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            $process.Kill(); [void]$process.WaitForExit(5000)
            return [pscustomobject]@{Status='WorkerTimedOut';Stage=$Mode;Failure='Hard deadline exceeded; child terminated. No automatic retry.'}
        }
        $text=$stdout.GetAwaiter().GetResult()
        # Never return child stderr/raw exception text, which may contain inputs.
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{Status='WorkerFailed';Stage=$Mode;Failure='Worker failed without usable output.'}
        }
        try { $text | ConvertFrom-Json } catch { [pscustomobject]@{Status='WorkerFailed';Stage=$Mode;Failure='Worker output could not be parsed.'} }
    } catch {
        [pscustomobject]@{Status='WorkerFailed';Stage=$Mode;Failure=(Get-DiagnosticFailure $_)}
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}

if ($InternalWorker) {
    try {
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $data=[Management.Automation.PSSerializer]::Deserialize([Console]::In.ReadToEnd())
        switch ($InternalWorker) {
            'Transport' { Initialize-DiagnosticTls; $result=[SfsuLdapsDiagnostic.TlsProbe]::Run($data.Server,636,([int]$data.Timeout*1000)) }
            'Directory' { $result=Invoke-DiagnosticDirectory $data }
            'Discovery' {
                $records=@(Resolve-DnsName -Name $data.Query -Type SRV -DnsOnly -ErrorAction Stop | Where-Object Type -eq 'SRV' | Sort-Object Priority,NameTarget)
                $result=[pscustomobject]@{Status='Passed';Query=$data.Query;Servers=@($records | ForEach-Object { $_.NameTarget.TrimEnd('.') } | Select-Object -Unique)}
            }
            'Context' {
                $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
                try {
                    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
                    $computer=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
                    $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
                    $result=[pscustomobject]@{Status='Passed';DomainJoined=[bool]$computer.PartOfDomain;ComputerDomain=$computer.Domain
                        ElevatedAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                        Windows=$os.Caption;Build=$os.BuildNumber;PowerShell=$PSVersionTable.PSVersion.ToString();DotNet=[Environment]::Version.ToString()
                        SessionAuthenticationType=$identity.AuthenticationType;SessionIsLocalAccount=($identity.Name -like ($env:COMPUTERNAME+'\*'));SessionIdentityNotExported=$true}
                } finally { $identity.Dispose() }
            }
        }
        $result | ConvertTo-Json -Depth 12 -Compress
        exit 0
    } catch {
        [pscustomobject]@{Status='WorkerFailed';Stage=$InternalWorker;Failure=(Get-DiagnosticFailure $_)} | ConvertTo-Json -Depth 5 -Compress
        exit 0
    }
}

if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this diagnostic in Windows PowerShell 5.1 (powershell.exe), matching the application runtime.' }
Assert-DiagnosticDnsName $Domain
if ($Site -and $Site -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$') { throw 'Use a DNS-safe AD site name.' }
if ($BindServer) { Assert-DiagnosticDnsName $BindServer }
foreach ($name in $Server) { Assert-DiagnosticDnsName $name }
if ([bool]$ProfileSid -ne [bool]$ExpectedAccountId) { throw 'Supply both -ProfileSid and -ExpectedAccountId, or neither.' }
if ($ProfileSid) {
    [void](New-Object Security.Principal.SecurityIdentifier($ProfileSid))
    if ($ExpectedAccountId -notmatch '^p?\d{1,32}$') { throw 'ExpectedAccountId must be a numeric or p-prefixed numeric profile ID.' }
}
if ($TransportOnly -and ($Compare389 -or $Credential -or $ProfileSid)) { throw 'TransportOnly cannot be combined with credential, profile or Compare389 options.' }

$report=[ordered]@{SchemaVersion=1;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null
    Domain=$Domain;Context=$null;Discovery=$null;Transport=@();Directory=$null;Comparison389=$null
    ChannelBinding='NotProven: ask AD administrators for effective policy and correlated DC audit evidence.'
    CertificateScope='Strict SslStream TLS 1.2/revocation probe; separate LDAP connection uses Windows default certificate validation. Certificates are not pinned between these connections.'
    AuthenticationPolicy='Explicit standard SFSU account; Kerberos only; one DC; no automatic retries, NTLM, simple bind, or implicit Windows credentials.'
    Notes=@();Overall='Incomplete'}
Write-Host 'SFSU LDAPS diagnostic - no directory writes or migrations.'
$report.Context=Invoke-DiagnosticWorker 'Context' @{} $WorkerTimeoutSeconds
$targets=@($Server)
if ($targets.Count -eq 0) {
    $query='_ldap._tcp.dc._msdcs.'+$Domain
    if ($Site) { $query='_ldap._tcp.'+$Site+'._sites.dc._msdcs.'+$Domain }
    Write-Host ('Discovering DCs through DNS: '+$query)
    $report.Discovery=Invoke-DiagnosticWorker 'Discovery' @{Query=$query} $WorkerTimeoutSeconds
    if ($report.Discovery.Status -eq 'Passed') { $targets=@($report.Discovery.Servers) }
    else { $report.Notes+='DNS discovery failed. Rerun with explicit -Server FQDNs.' }
}
if ($BindServer) { $targets=@($BindServer)+$targets }
# Probe the app's domain alias as well, but only bind to it if explicitly chosen.
$targets=@($targets+$Domain | Select-Object -Unique)
if ($targets.Count -gt 32) { throw 'Limit diagnostics to 32 endpoints per run with -Server or -Site.' }
$transport=New-Object Collections.Generic.List[object]
foreach ($target in $targets) {
    Assert-DiagnosticDnsName $target
    Write-Host ('Checking TCP/TLS: '+$target+':636')
    $probe=Invoke-DiagnosticWorker 'Transport' @{Server=$target;Timeout=$OperationTimeoutSeconds} $WorkerTimeoutSeconds
    if (-not $probe.PSObject.Properties['Server']) { $probe | Add-Member NoteProperty Server $target }
    $transport.Add($probe)
    Write-Host ('  '+$probe.Status+' ('+$probe.Stage+')')
}
$report.Transport=@($transport.ToArray())
$chosen=$BindServer
if (-not $chosen) {
    $usable=@($transport | Where-Object { $_.Status -eq 'Passed' -and $_.Server -ine $Domain })
    if ($usable.Count -gt 0) { $chosen=$usable[0].Server }
}
$chosenProbe=@($transport | Where-Object Server -ieq $chosen)
$ownsCredential=$false
try {
    if (-not $TransportOnly -and $chosen -and $chosenProbe.Count -eq 1 -and $chosenProbe[0].Status -eq 'Passed') {
        if ($null -eq $Credential) { $Credential=Read-DiagnosticCredential $chosen; $ownsCredential=$true }
        if ($null -eq $Credential) { $report.Notes+='Credential entry cancelled. Directory tests not run.' }
        else {
            [void](ConvertTo-DiagnosticLogin $Credential.UserName)
            Write-Host ('Testing Kerberos LDAPS bind and bounded queries on '+$chosen)
            $payload=@{Server=$chosen;Timeout=$OperationTimeoutSeconds;Credential=$Credential;UseTls=$true;ProfileSid=$ProfileSid;ExpectedAccountId=$ExpectedAccountId}
            $report.Directory=Invoke-DiagnosticWorker 'Directory' $payload $WorkerTimeoutSeconds
            Write-Host ('  LDAPS: '+$report.Directory.Status+' ('+$report.Directory.Stage+')')
            if ($Compare389 -and $report.Directory.Status -eq 'Passed') {
                Write-Host 'Comparing current Kerberos signing/sealing on 389 on the SAME controller.'
                $payload.UseTls=$false
                $report.Comparison389=Invoke-DiagnosticWorker 'Directory' $payload $WorkerTimeoutSeconds
                Write-Host ('  LDAP 389: '+$report.Comparison389.Status+' ('+$report.Comparison389.Stage+')')
            } elseif ($Compare389) { $report.Notes+='389 comparison skipped after LDAPS failure/timeout. No further credential attempts.' }
            $payload.Clear()
        }
    } elseif (-not $TransportOnly) { $report.Notes+='No eligible DC passed strict TLS checks, or BindServer failed them. No credentials sent.' }
    if ($TransportOnly) { $report.Overall='TransportOnly' }
    elseif ($null -ne $report.Directory -and $report.Directory.Status -eq 'Passed') {
        $report.Overall='DirectoryPassedWithEvidenceLimits'
        if ($Compare389 -and ($null -eq $report.Comparison389 -or $report.Comparison389.Status -ne 'Passed')) { $report.Overall='ComparisonIncompleteOrFailed' }
    } else { $report.Overall='DirectoryNotPassed' }
} catch {
    $report.Notes+='Diagnostic stopped; no additional credentials attempted.'
    $report.Notes+=Get-DiagnosticFailure $_
    $report.Overall='DiagnosticStopped'
} finally { if ($ownsCredential -and $null -ne $Credential) { $Credential.Password.Dispose(); $Credential=$null } }
$report.FinishedUtc=[DateTime]::UtcNow.ToString('o')
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$outputPath=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('ldaps-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
$json=$report | ConvertTo-Json -Depth 14
$stream=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $encoded=[Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($encoded,0,$encoded.Length) } finally { $stream.Dispose() }
Write-Host ('Result: '+$report.Overall)
Write-Host ('Report: '+$outputPath)
Write-Host 'CBT enforcement remains unproven. See docs/LDAPS-DIAGNOSTIC.md for server evidence and interpretation.'
$outputPath
