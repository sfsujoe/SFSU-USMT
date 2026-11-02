# Security and maintenance

The application remains a discovery, preparation and metadata-review tool. It does not run ScanState or LoadState, create accounts or migrate employee files. This document describes local safeguards and deployment requirements; synthetic tests do not establish production directory/share compatibility.

## Credentials and directory access

Use a standard numeric SFSU ID, optionally followed by `@sfsu.edu`, for the startup AD prompt. Power-user IDs beginning with `p` are rejected in both the dialog and backend binding functions. This restriction applies to the technician connecting to AD, not to selected profiles: regular and p-account profiles remain distinct and can be verified by standard credentials, manually named, prepared, listed and reviewed. Standard-account directory read access still requires a representative campus test.

Directory binding uses explicit standard-account credentials and Kerberos only, with signing/sealing required, LDAP v3 on port 389, eight-second timeouts and no referrals. There is no NTLM downgrade, default Windows credential reuse, LDAPS or StartTLS. Kerberos requires correct DNS/SPNs, time, KDC connectivity and a usable realm/account configuration. A failed secure connection can be retried or followed by explicit manual mode; it never silently weakens authentication. Test successful standard-account binding from a local-admin session, plus supported off-domain hosts, before deployment. LDAPS remains a future deployment option requiring trusted server certificates and channel-binding validation, not a port-only change.

Passwords are converted through a direct .NET API rather than passed as plaintext cmdlet parameters, closing the reviewed `ConvertTo-SecureString` module-logging path. No Windows security logging policy is disabled. The app clears password input after submission and disposes failed/cancelled credentials. Successful credentials expire after ten minutes without directory activity; active tasks retain their credentials until completion, then restart the idle interval. Reopening the prompt and choosing Continue without AD, Escape or closing it retains the established meaning: discard credentials and use manual mode. Repeated failed authentication has a 2/4/8/16/30-second bounded retry cooldown. There are no automatic password retries.

This does not protect credentials from an administrator, a compromised endpoint, debugging, or all memory copies. Entering a password into an employee's own Windows session is discouraged. The documented workflow uses a separate local-admin session. Directory authentication resolves names; it is not authorization to access employee data.

Developer profile discovery without `-DirectoryCredential` is explicitly LDAP-free. A PowerShell caller can supply a PSCredential using a secure credential-entry mechanism and pass `-DiscoverProfiles -DirectoryCredential $credential`; never put passwords in shell arguments, transcripts, scripts or messages. Bare IDs are normalized before the Kerberos credential is constructed. Default/network-only Windows contexts are deliberately not used because their outbound identity cannot be guaranteed to exclude p-accounts.

## Profiles and saved identity

Exact binary-SID filters remain escaped and limited to two results. Domain folder base IDs can have recognized Windows `.DOMAIN`, `.000` or `.DOMAIN.000` suffixes. SID lookup runs even when a folder is unrecognized; only a recognized base ID agreeing with the returned account may become verified/prepared. Genuine SID/account-ID conflicts remain blocked. Local SAM classification still takes precedence over folder spelling. Unsupported Entra/system/setup/missing/linked profiles are summarized by exclusion reason/count without logging additional excluded personal identifiers.

Source-profile discovery checks path/ancestor attributes without opening directories for file-list access. Restricted local or p-account profiles remain listed. Metadata-access failures are recorded as AccessUnverified with a warning, not misclassified as links; preparation requires metadata checks to succeed. Actual missing paths and confirmed reparse points remain excluded. Metadata-only preparation does not list, copy or modify source files, and a visible/AD-verified profile does not prove file-read permission for a future capture. Native write guards continue to apply to toolkit destinations independently.

Manifest reading remains compatible with version-one domain and version-two domain/local records. It checks size, actual Boolean migration state, source-folder base ID, source/directory SID agreement, full account ID, verification timestamp and manual provenance. Invalid metadata stays visible as unrecognized. Structural validity is not cryptographic proof that a record is authentic. The code and metadata are editable by trusted operators under the accepted risk model.

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
