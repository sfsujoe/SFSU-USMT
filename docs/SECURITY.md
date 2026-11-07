# Security and maintenance

The application remains a discovery, preparation and metadata-review tool. It does not run ScanState or LoadState, create accounts or migrate employee files. This document describes local safeguards and deployment requirements; synthetic tests do not establish production directory/share compatibility.

## Credentials and directory access

Use an SFSU account login or full UPN for the startup AD prompt. Numeric, alphabetic and p-prefixed accounts are permitted; there is no prefix-based privilege inference or sign-in restriction. The shared [identity policy](IDENTITY.md) controls the ID attribute and permitted login suffixes. University ID, SAM account name, UPN and profile path remain separate values. Actual credentials and directory read permissions still require representative campus testing.

Directory binding uses explicit credentials and Kerberos only, with signing/sealing required, LDAP v3 on port 389, eight-second timeouts and no referrals. There is no NTLM downgrade, default Windows credential reuse, LDAPS or StartTLS. Kerberos requires correct DNS/SPNs, time, KDC connectivity and a usable realm/account configuration. A failed secure connection can be retried or followed by explicit manual mode; it never silently weakens authentication. Test binding and read permissions from local-admin and supported off-domain sessions before deployment. LDAPS remains deferred and requires trusted server certificates and channel-binding validation.

The normal CMD launch hides the PowerShell host while retaining the existing masked WinForms sign-in dialog. Credentials are still entered directly into the app, never passed through launcher arguments or a second credential-collection process. The host retains NoProfile, STA, the caller's privileges and process-only ExecutionPolicy Bypass. No credential storage/provider, transport, expiry, retry or OS-policy change accompanies this presentation change. CLI/maintenance launches with arguments stay visible and synchronous; the application entry point requests a graphical startup-error message for GUI failures.

Passwords are converted through a direct .NET API rather than passed as plaintext cmdlet parameters, closing the reviewed `ConvertTo-SecureString` module-logging path. No Windows security logging policy is disabled. The app clears password input after submission and disposes failed/cancelled credentials. Successful credentials expire after ten minutes without directory activity; active tasks retain their credentials until completion, then restart the idle interval. Reopening the prompt and choosing Continue without AD, Escape or closing it retains the established meaning: discard credentials and use manual mode. Repeated failed authentication has a 2/4/8/16/30-second bounded retry cooldown. There are no automatic password retries.

This does not protect credentials from an administrator, a compromised endpoint, debugging, or all memory copies. Entering a password into an employee's own Windows session is discouraged. The documented workflow uses a separate local-admin session. Directory authentication resolves names; it is not authorization to access employee data.

Developer profile discovery without `-DirectoryCredential` is explicitly LDAP-free. A PowerShell caller can supply a PSCredential using a secure credential-entry mechanism and pass `-DiscoverProfiles -DirectoryCredential $credential`; never put passwords in shell arguments, transcripts, scripts or messages. Bare account logins are normalized using the configured suffix before constructing Kerberos credentials. Explicit credential selection remains required so the attempted account is intentional and auditable.

## Profiles and saved identity

Exact binary-SID filters remain escaped and limited to two results. A single returned SID must match the registered source profile SID; valid configured ID text, SAM account name and display name are required for verification. Folder spelling is not an identity source or a verification requirement. Missing/multivalued configured attributes remain unresolved. Genuine SID/multiple-match conflicts remain blocked. Local SAM classification takes precedence over folder spelling. Unsupported Entra/system/setup/missing/linked profiles are summarized by exclusion reason/count without logging additional excluded personal identifiers.

Source-profile discovery checks path/ancestor attributes without opening directories for file-list access. Restricted local or p-account profiles remain listed. Metadata-access failures are recorded as AccessUnverified with a warning, not misclassified as links; preparation requires metadata checks to succeed. Actual missing paths and confirmed reparse points remain excluded. Metadata-only preparation does not list, copy or modify source files, and a visible/AD-verified profile does not prove file-read permission for a future capture. Native write guards continue to apply to toolkit destinations independently.

Only schema-three preparation metadata is supported. Earlier development versions remain unrecognized and are not converted or deleted. Reading checks size, actual Boolean migration state, source/directory SID agreement, separate ID/account/UPN fields, saved attribute provenance, verification timestamp and manual confirmation. Folder labels do not validate identity. Invalid metadata stays visible as unrecognized. Structural validity is not cryptographic proof that a record is authentic. The code and metadata are editable by trusted operators under the accepted risk model.

## Files and reporting

Logging, metadata and snapshot paths reject reparse points in ancestors and leaves. Native directory handles prevent ancestor rename/deletion during guarded operations. Protected file opens reject leaf links and multiple hard links before changing bytes. Snapshot copying validates each source and opens destination files with CreateNew; existing snapshots are never merged or overwritten. Source/profile data and existing backups remain preserved. Network filesystem support for these native guards must be field-tested; unsupported protection fails visibly rather than silently skipping checks.

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

## Requirements before migration integration

Keep the engine disconnected until coverage, source-to-destination mapping, verification and restore acceptance are agreed and tested. Explicitly select an approved AES store-encryption mode. Pass a future encryption key through `/keyfile`, never `/key:<secret>`. Create the key file with restrictive permissions before writing its contents, outside migration collection and general logs, using an approved storage/recovery design. Keep the key out of cmdlet parameter logging, process arguments, metadata, reports and source control. Protect the key separately from the migration store and define cleanup/recovery; `/keyfile` alone does not secure an accessible plaintext file. Restrict the store directory from creation, avoid implicit overwrites, and require store verification plus actual restore tests before re-imaging readiness.

## Validation

Run `tests/Test-Security.ps1` plus inventory, authentication, reporting, report-write, appearance and resize regressions on Windows PowerShell 5.1. The security suite uses synthetic credentials and isolated native filesystem operations, including real junction/hard-link attacks and directory-handle rename refusal. It does not bind to campus AD, change logging policy, change share permissions or run USMT. Live Kerberos, module-logging, SMB/native-handle and accessibility acceptance remain separate checks.

`tests/Test-ProfileDiscoveryAccess.ps1` reproduces restricted local/p-profile directories with actual directory-list Deny ACLs on new fixtures, restores those ACLs in finally, and verifies metadata-only enumeration/preparation, explicit metadata-access warnings, source-junction refusal and source-content preservation. It never changes real profile/share ACLs.

User field report on 2026-11-02: the discovery fix worked and AD authentication is functioning after the security changes. This supports the tested setup; exact host/account/protocol evidence and the broader environment/permissions/accessibility matrix were not supplied. No capture or restore result is implied.
