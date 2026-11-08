# Security and maintenance

The application now connects native capture/restore and local-account recreation for controlled validation. This document describes implemented local safeguards and deployment requirements; synthetic tests do not establish real migration, account API provisioning or production directory/share compatibility. See [migration behavior and acceptance](MIGRATION.md).

## Credentials and directory access

Use an SFSU account login or full UPN for the startup AD prompt. Numeric, alphabetic and p-prefixed accounts are permitted; there is no prefix-based privilege inference or sign-in restriction. The shared [identity policy](IDENTITY.md) controls the ID attribute and permitted login suffixes. University ID, SAM account name, UPN and profile path remain separate values. Actual credentials and directory read permissions still require representative campus testing.

Directory binding uses explicit credentials and Kerberos only, with signing/sealing required, LDAP v3 on port 389, eight-second timeouts and no referrals. There is no NTLM downgrade, default Windows credential reuse, LDAPS or StartTLS. Kerberos requires correct DNS/SPNs, time, KDC connectivity and a usable realm/account configuration. A failed secure connection can be retried or followed by explicit manual mode; it never silently weakens authentication. Test binding and read permissions from local-admin and supported off-domain sessions before deployment. LDAPS remains deferred and requires trusted server certificates and channel-binding validation.

GUI startup checks the actual Windows administrator token and requests elevation using the OS RunAs broker before importing application services or collecting AD credentials. An already elevated app proceeds directly. UAC cancellation stops startup; there is no unelevated fallback. The bootstrap waits for the elevated child, preserving its exit status, and reports unsuccessful child startup with an administrator/share-access diagnostic. The normal CMD still returns after starting its hidden host. The child uses the explicit system Windows PowerShell executable, NoProfile, STA, a hidden console and process-only ExecutionPolicy Bypass. A mapped entry path is resolved to UNC before relaunch; local/removable and UNC paths remain unchanged. No SMB remapping, stored credentials, registry/UAC-policy changes or saved execution-policy changes occur. The elevated account must independently have package/share access. Headless/developer/maintenance actions do not auto-elevate.

The masked WinForms AD sign-in remains separate from Windows UAC. AD credentials are entered after elevation, never passed through bootstrap arguments. Directory authentication does not grant local rights or establish SMB authentication. Expiry/retry/transport rules are unchanged; credential expiry does not remove process elevation. Native USMT children use the elevated GUI token without alternate credentials, under a job object for descendant cancellation. The engine enables only privileges already assigned to that process; missing rights stop migration.

Passwords are converted through a direct .NET API rather than passed as plaintext cmdlet parameters, closing the reviewed `ConvertTo-SecureString` module-logging path. No Windows security logging policy is disabled. The app clears password input after submission and disposes failed/cancelled credentials. Successful credentials expire after ten minutes without directory activity; active tasks retain their credentials until completion, then restart the idle interval. Reopening the prompt and choosing Continue without AD, Escape or closing it retains the established meaning: discard credentials and use manual mode. Repeated failed authentication has a 2/4/8/16/30-second bounded retry cooldown. There are no automatic password retries.

This does not protect credentials from an administrator, a compromised endpoint, debugging, or all memory copies. Entering a password into an employee's own Windows session is discouraged. The documented workflow uses a separate local-admin session. Directory authentication resolves names; it is not authorization to access employee data.

Developer profile discovery without `-DirectoryCredential` is explicitly LDAP-free. A PowerShell caller can supply a PSCredential using a secure credential-entry mechanism and pass `-DiscoverProfiles -DirectoryCredential $credential`; never put passwords in shell arguments, transcripts, scripts or messages. Bare account logins are normalized using the configured suffix before constructing Kerberos credentials. Explicit credential selection remains required so the attempted account is intentional and auditable.

## Profiles and saved identity

Exact binary-SID filters remain escaped and limited to two results. A single returned SID must match the registered source profile SID; valid configured ID text, SAM account name and display name are required for verification. Folder spelling is not an identity source or a verification requirement. Missing/multivalued configured attributes remain unresolved. Genuine SID/multiple-match conflicts remain blocked. Local SAM classification takes precedence over folder spelling. Unsupported Entra/system/setup/missing/linked profiles are summarized by exclusion reason/count without logging additional excluded personal identifiers.

Source-profile discovery checks path/ancestor attributes without opening directories for file-list access. Restricted local or p-account profiles remain listed. Metadata-access failures are recorded as AccessUnverified with a warning, not misclassified as links; preparation requires metadata checks to succeed. Actual missing paths and confirmed reparse points remain excluded. Metadata-only preparation does not list, copy or modify source files, and a visible/AD-verified profile does not prove file-read permission for a future capture. Native write guards continue to apply to toolkit destinations independently.

Schema-three preparation metadata and schema-four native-capture metadata are supported. Versions 1/2 remain unrecognized without conversion/deletion. Reading checks bounded text/size, Boolean migration state, SID/identity evidence and manual confirmation. Native records additionally require valid capture/verification state, fixed Store path, exact source SID, known architecture, tool version and four captured policy hashes. Restore rereads/hash-checks rules and freshly verifies every compressed store before mutation, holding stores/rules read-only through apply. Prepared/failed/cancelled records cannot restore. Folder labels do not validate identity. These checks are not cryptographic authentication of editable metadata/code under the accepted trusted-operator model.

## Files and reporting

Logging, metadata and snapshot paths reject reparse points in ancestors and leaves. Native directory handles prevent ancestor rename/deletion during guarded operations. Protected file opens reject leaf links and multiple hard links before changing bytes. Snapshot copying validates each source and opens destination files with CreateNew; existing snapshots are never merged or overwritten. Source/profile data and existing backups remain preserved. Network filesystem support for these native guards must be field-tested; unsupported protection fails visibly rather than silently skipping checks.

Raw-report link inspection uses an access-free, fully shared metadata handle with the same leaf link/hard-link checks and guarded ancestors. Live progress/diagnostic reads use no-follow shared read handles. These observation-only modes do not change protected writes, journal/metadata opens or read-only store holds. Unsafe raw links are omitted with a visible report warning. Observer/HTML-refresh errors do not cancel a running native process; they retain warnings, while required result-recording failures after native exit still prevent dependent stages from claiming success.

Events are flushed immediately. Cached bounded parsing and incremental event state reduce repeated full journal reads; ordinary-message HTML refresh is throttled to one second, while checkpoints, lifecycle boundaries and errors refresh immediately. A copied `logo.png` travels with each run for portable rebuilding, and generated HTML embeds it without remote resources. Old journals with embedded Base64 logos remain readable. Journals are limited to 32 MB, 1 MB per record and 20,000 records; metadata to 1 MB; backup listings to 10,000 folders. Safety-limit failures preserve evidence for troubleshooting.

## Permissions and retention

Keep `Logs` and `Backups` accessible only to approved technicians/data custodians and required system/administration identities. Configure restricted parent filesystem ACLs before creating runtime data so new folders inherit the intended protection from their first write. Validate actual group membership, child ACLs, SMB share permissions, encryption and removable-media protection. The application does not invent a campus technician-group name, reset inherited permissions or change production ACLs. User-editable scripts are explicitly an accepted risk; do not use that acceptance to infer public access to employee data.

The local filesystem ACL screen flags broad Allow entries for Everyone, Authenticated Users, built-in Users and Anonymous. It is a screening aid, not an effective-access or SMB-share audit:

```powershell
.\sfsu-usmt.cmd -ReviewStorageAccess
```

Root diagnostic-log retention is manual and preview-first. Thirty days is the command's default proposal, not an approved campus retention period. The operator supplies the required number of days and explicitly applies deletion after reviewing the preview:

```powershell
.\sfsu-usmt.cmd -PreviewLogRetention -LogRetentionDays 30
.\sfsu-usmt.cmd -ApplyLogRetention -LogRetentionDays 30
```

Only generated, finalized, readable root `Logs/<run-id>` directories with old completion and descendant modification times are eligible. Recent, incomplete, damaged, unknown and linked directories are preserved. This never runs automatically, never deletes `Backups` or their finalized log snapshots, and does not implement employee-backup retention. Do not run maintenance concurrently with other operators changing the package. Review handling of existing root startup error files separately; they are not automatically removed.

SFSU's Sensitive Data policy lists SF State ID as Level 3 and restricts publicly identifying ID displays. Restricted internal technician records should not be equated automatically with public posting. Confirm access and retention with the responsible campus owner; future migration content can have a higher classification than the identifiers in preparation metadata.

## Migration and account safeguards

The engine implements D46-D60's policies and D67's integration request. D54 selects unencrypted stores, superseding the earlier AES/keyfile recommendation; there is no store key/prompt. EFS is separate: /efs:copyraw and required user certificate/private-key/DPAPI components are retained. Intended-user decryption remains unverified until an actual user-context test; reports retain that warning. Unique folders/no /o prevent implicit store overwrite. Source employees must be signed out, and all selected restore targets must pass collision checks before account/data changes. Local account existence or employee profile/folder presence stops the whole restore; domain AD existence is expected.

D66/D67 implement an individual masked password/confirmation, explicit enabled-state choice and Administrators choice defaulting to No for every local account. All choices precede restore. Read-only SecureStrings are session-only; inputs/references are cleared and disposed after cancellation/completion. Passwords never enter process arguments, metadata or logs. NetUserAdd receives a temporarily marshalled password buffer that is zeroed/freed, creates accounts disabled and applies destination password policy. No /lac or /lae is used. Final Users/Administrators membership and enabled state are applied/verified after native restore; migrated membership cannot silently override the technician choice. Failed/cancelled batches disable only accounts created by that run and retain partial data/accounts. Existing/racing accounts are never disabled/reset/reused; no automatic rollback/deletion occurs. Endpoint memory/admin exposure remains a limitation. See [LoadState options](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-loadstate-syntax) and [NetUserAdd](https://learn.microsoft.com/en-us/windows/win32/api/lmaccess/nf-lmaccess-netuseradd).

## Validation

Run `tests/Test-Security.ps1` plus inventory, authentication, reporting, report-write, appearance and resize regressions on Windows PowerShell 5.1. The security suite uses synthetic credentials and isolated native filesystem operations, including real junction/hard-link attacks and directory-handle rename refusal. It does not bind to campus AD, change logging policy, change share permissions or run USMT. Live Kerberos, module-logging, SMB/native-handle and accessibility acceptance remain separate checks.

`tests/Test-ProfileDiscoveryAccess.ps1` reproduces restricted local/p-profile directories with actual directory-list Deny ACLs on new fixtures, restores those ACLs in finally, and verifies metadata-only enumeration/preparation, explicit metadata-access warnings, source-junction refusal and source-content preservation. It never changes real profile/share ACLs.

User field report on 2026-11-02: the discovery fix worked and AD authentication is functioning after the security changes. This supports the tested setup; exact host/account/protocol evidence and the broader environment/permissions/accessibility matrix were not supplied. No capture or restore result is implied.
