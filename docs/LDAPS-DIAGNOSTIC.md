# LDAPS diagnostic

`tools/Test-SfsuLdaps.ps1` is a standalone **Windows PowerShell 5.1** diagnostic. It does not change the application's authentication method, AD objects, certificate trust, saved execution policy or server configuration. It writes one JSON report and displays its path. No RSAT or ADWS is required. DNS discovery does not require a domain-joined computer; successful Kerberos authentication still requires usable DNS, KDC/realm connectivity, time and credentials.

## Run the diagnostic

Run from the intended technician Windows session using an SFSU account login/UPN at the prompt. P-prefixed and alphabetic logins are supported through the same [identity policy](IDENTITY.md) as the app. Keep this script in the package's tools folder and include App/Scripts/Sfsu.Identity.psm1 and Sfsu.Identity.psd1. Elevation is not required; a local-admin session can match the operational workflow. Do not start a transcript or put a password on the command line.

After transport checks, the script prints `Waiting for credentials in this PowerShell window` and asks for an account login/UPN and masked password in that window. Blank login skips directory tests and still writes the report. Waiting for interactive input has no network timeout. An alias TLS failure does not block binding to a separately selected healthy DC; the report retains both results.

Run the entire saved script using `powershell.exe -File`, as shown below. Report-path defaults are initialized after parameter binding from the saved script location, independent of the working directory. Pasted blocks/editor selections without a saved-file invocation path are rejected before network tests because the workers must reopen that file.

From the repository root:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SfsuLdaps.ps1 -BindServer DCS01.ad.sfsu.edu -Compare389
```

This discovers DC FQDNs through `_ldap._tcp.dc._msdcs.ad.sfsu.edu`, probes their TCP/TLS availability plus the app's `ad.sfsu.edu` alias, then authenticates **only to DCS01** if its strict TLS probe passed. `-Compare389` explicitly requests a second bind on that same DC using the application's current Kerberos signing/sealing settings, **only after LDAPS bind and queries pass**. Any failure or hard timeout skips further authentication. There is no automatic retry on another controller, NTLM, simple bind or implicit Windows-credential fallback.

For a shorter first run, test just the chosen DC (the domain alias is always probed too):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-SfsuLdaps.ps1 -Server DCS01.ad.sfsu.edu -BindServer DCS01.ad.sfsu.edu -Compare389
```

Without `-BindServer`, it selects the first non-alias DC that passes strict TLS, in explicit input order or DNS priority/name order. It does not claim to implement Windows DC-locator failover or SRV weight selection. If discovery fails, specify `-Server` explicitly. `-Site` restricts discovery to the supplied AD site's SRV records; a site-query failure is reported without silently switching sites.

Transport checks without any password prompt or LDAP bind:

```powershell
.\tools\Test-SfsuLdaps.ps1 -Server DCS01.ad.sfsu.edu,DCS01-DR.ad.sfsu.edu -TransportOnly
```

To verify a particular registered domain profile, supply its **source SID** and the corresponding full account ID together:

```powershell
# Replace these synthetic values with the intended test profile's real values.
.\tools\Test-SfsuLdaps.ps1 -Server DCS01.ad.sfsu.edu -BindServer DCS01.ad.sfsu.edu -ProfileSid 'S-1-5-21-111111-222222-333333-1101' -ExpectedAccountId 'p000000123'
```

Use a designated test profile's SID from the app or local ProfileList registry. ExpectedAccountId is the full expected **SAM account name**, which may differ from a separately configured university-ID attribute. P-prefixed accounts can be lookup targets or credentials. Returned profile values are not included in reports. Without these parameters, the credential-account SID round-trip is labeled CredentialAccountSidRoundTripOnly and does not establish agreement with a registered source profile.

To test the app's domain alias as the actual LDAP endpoint, explicitly select it:

```powershell
.\tools\Test-SfsuLdaps.ps1 -Server ad.sfsu.edu -BindServer ad.sfsu.edu
```

If alias certificate validation fails, no credentials are sent. Do not disable validation to make it pass. Wildcard subject text alone does not establish coverage of the domain alias; the actual hostname validation result matters.

Reports default to `tools/LdapsDiagnostics/ldaps-<UTC-time>-<random>.json`, excluded from Git. `-OutputDirectory` changes the report destination. Files use CreateNew; previous reports are not overwritten. Each report records client/domain/elevation context, UTC times, endpoint addresses and infrastructure certificate metadata. It omits the password, credential object, Windows username, returned display name, account ID and SID. Reports still contain internal network information; use an appropriately restricted location. An externally supplied `-Credential` remains owned by the caller; a prompted credential is disposed on completion.

## What the results establish

| Field or stage | Meaning |
| --- | --- |
| Context | Windows build, PowerShell/.NET version, domain membership, local-account session classification and elevated-admin status. A context failure is reported separately. |
| TCP | The selected hostname resolved and accepted a TCP connection on 636 from this location. A timeout alone cannot identify firewall, routing or service cause. |
| TLS | A separate SslStream handshake used TLS 1.2, normal hostname/chain validation and revocation checking. Any reported certificate error is rejected. SAN, EKU OIDs, validity, thumbprint, chain errors, endpoint addresses and negotiated cryptography are recorded when available, including certificate information on validation failure. TLS 1.3 support is not tested. |
| DaysRemaining | Certificate lifetime at run time. Review impending renewal with AD administrators, then rerun after renewal. This does not inspect renewal automation or promise service continuity. |
| Bind | An explicit Kerberos LDAP bind succeeded on 636 using Windows LDAP's default certificate validation. No custom LDAP certificate callback is installed. TLS takes the transport protection role on 636; 389 separately requests SASL signing/sealing. |
| LdapTls | Negotiated TLS and cipher strength on the **actual LDAP connection** after bind. Framework's enum lacks modern TLS names, so Schannel protocol bits are also recorded. Values containing 0x400/0x800 indicate TLS 1.2; 0x1000/0x2000 indicate TLS 1.3. The script stops before directory queries if modern TLS/at least 128-bit encryption is not observed. OS TLS policy governs this connection; the separate TLS 1.2 probe does not force LDAP's protocol, and this after-bind check cannot retroactively protect credentials on an obsolete OS configuration. |
| RootDSE | A bounded base query returned a default naming context. |
| Lookup / IdentityChecks | An escaped binary-SID query returned exactly one user with matching SID/SAM account name and a populated display name. Credential-account testing first searches the escaped literal UPN and reads the actual SAM name/SID; CredentialUpnMatches must pass. That check is null for an explicitly supplied profile target. No UPN-prefix/SAM equality convention is assumed. Searches retain size limit two, bounded time limits and no referrals. |
| Comparison389 | Same-account/same-controller Kerberos bind, RootDSE and SID lookup with signing/sealing on 389. Requested only by Compare389 after LDAPS passes. |
| EndpointChannelBindingAvailable | The **separate SslStream probe** could obtain a TLS endpoint channel-binding token. This does not show that LdapConnection sent a token or that AD enforced one. |
| WorkerTimedOut | A child process exceeded the 45-second default hard deadline and was terminated. The exact blocked native substage may be unknown. No further credential attempts occur. |
| Overall | Summary of the selected directory test. `DirectoryPassedWithEvidenceLimits` can coexist with unreachable DR endpoints or alias TLS failures; inspect all Transport results. It never certifies CBT, all-host compatibility or migration success. |

The TLS probe and actual LDAP session are separate connections. Certificates are not pinned between them; the captured TLS certificate cannot establish exactly which certificate the second connection presented, especially for a DNS alias resolving to multiple servers. Both clients retain certificate validation. Revocation checks may use Windows cached revocation data and may contact CA revocation endpoints; a successful result does not prove a fresh CRL/OCSP download occurred. A revocation-unavailable result is a failed validation, not permission to ignore it.

Each operation has an eight-second default timeout, and each worker (DNS/context/TLS/directory) has a separate 45-second hard deadline, adjustable with `-OperationTimeoutSeconds` and `-WorkerTimeoutSeconds`. Multiple endpoints add to total time. Child processes run hidden, under the same user/token, and receive DPAPI-protected credential serialization over redirected stdin, never a credential file or password argument. Child stderr/raw exception messages are not exported; failures include stage, type and numeric LDAP/HResult codes where available. LDAP 49 indicates rejection, but the report intentionally does not capture personal/raw server diagnostic text. Correct account/password/policy problems before another run; repeated invocations can still contribute to lockout counters.

## Channel binding requires AD administrator evidence

The report intentionally leaves `ChannelBinding` as `NotProven`. A successful SASL/Kerberos LDAPS bind does not show that the DC requires CBT. No client-only success test can prove the server's rejection policy.

Provide the selected DC, Directory StartedUtc/FinishedUtc, client source IP from the transport probe and protocol to an AD administrator. Ask them to:

1. Confirm the effective **Domain controller: LDAP server channel binding token requirements** setting on the tested DC. `Always` requires valid tokens for applicable TLS/SASL sessions. Record how and when policy was verified; do not change policy just for this test without separate authorization.
2. Correlate available Directory Service events with the run: **3039** for failed CBT validation, **3074/3075** for relevant audit warnings. Event availability depends on Windows updates, diagnostic logging and effective policy. Missing events alone do not prove compliance.
3. For a successful bind with effective `Always` confirmed on that exact DC at that time, record the paired evidence that this client was accepted under enforcement. With `Never` or `When supported`, success alone remains insufficient to demonstrate enforced CBT.

The diagnostic does not query remote event logs, require DC-admin credentials, change auditing/GPO/registry, generate intentionally malformed authentication or test simple bind. A future basic-bind portability experiment would need an explicit decision to change the project's Kerberos-only policy.

Repeat the same selected-DC test from representative domain-joined/local-admin and supported off-domain hosts, onsite/VPN network paths, and intended elevation contexts. Compare reports by Windows build, context, addresses and UTC times. The script records the current context; it cannot create or simulate missing environments. This covers directory read behavior only; it says nothing about SMB access, source-file permissions, USMT capture or restore.

## Local validation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LdapsDiagnostic.ps1
```

The focused suite uses synthetic LDAP responses, a real untrusted loopback TLS server certificate, secure credential-pipe round-trip, forced child timeout and a full-command bind-rejection fixture. It does not contact campus DNS/AD, install a trusted certificate, change saved execution policy or use real passwords. Schannel needs an ordinary Windows test context for its temporary test private key; the restricted sandbox may deny that operation. Live LDAP, campus certificate/revocation behavior and CBT remain field tests.

References: [Microsoft LDAP channel binding](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/ldap-channel-binding), [LDAPS certificate requirements](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/configure-ldap-signing-certificates), [SslStream authentication/revocation behavior](https://learn.microsoft.com/en-us/dotnet/api/system.net.security.sslstream.authenticateasclient?view=netframework-4.8.1).
