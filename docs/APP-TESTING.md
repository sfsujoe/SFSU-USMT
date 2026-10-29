# Discovery and backup-folder preparation

Open `sfsu-usmt.cmd` from the package. The application uses Windows PowerShell 5.1 and Windows Forms, with the supplied SFSU logo in its header. It works without the ADK payload. This is an operational inventory/preparation test, not a data backup: **no ScanState, LoadState, UsmtUtils, employee-file copying, or account changes occur.**

## Backup tab

The app reads registered `Win32_UserProfile` records and the local account database. Both local and domain candidates are listed; system profiles, missing directories, and directory links are excluded. Local classification uses the current machine's local-account SID prefix, independently of the folder name. The local SAM username is retained, with a folder-name fallback for a deleted local account. Loaded profiles remain visible; no capture or hive access occurs.

For domain candidates, the numeric profile directory name supplies the SFSU ID under the user's confirmed naming convention. Leading zeros are preserved and ID provenance is recorded as ProfileDirectory. Nonnumeric folders are flagged instead of guessed or offered as editable IDs. Local profiles show **Local Account** in the SFSU ID column and retain a separate username/SID. Even a numeric local folder is never treated as an SFSU ID.

LDAP searches domain candidates by exact binary SID. Local SIDs are never sent to LDAP, and local-only discovery does not connect. The default endpoint is `ad.sfsu.edu:389`, with Windows Negotiate authentication, signing/sealing, eight-second limits, no referral chasing, and a two-result limit. Returned SID and numeric account ID must match the source SID and inferred folder ID before the name is marked Directory verified. Conflicts cannot be bypassed by assigning a name. Exactly nine digits is not enforced until exceptions are confirmed.

The profile grid puts **Verified** between **SFSU ID** and **Name**, showing ✅ only for a directory-verified domain profile whose SID, folder ID/account ID, verification timestamp, and nonempty display name agree. Local classification and manually confirmed names do not receive an AD check mark. Assign Display Name clears any previous mark because the replacement name is manual. Tooltips explain the verification state, and the Identity column retains its readable status. This check mark says nothing about migration capture or restore success.

**SID** is the final profile column and contains the actual registered profile SID. The profile grid uses readable, user-resizable widths and a horizontal scrollbar. Select, SFSU ID, Verified, and Name remain frozen while Profile directory, Identity, and SID scroll. The full SID is also available in its cell tooltip. Restore's separate backup grid retains its existing layout.

The GUI automatically opens **Authenticate to Active Directory**, with the message **Enter your SFSU ID and password**. **Authenticate** is at the bottom right, with **Continue without AD** immediately to its left. Enter authenticates; Escape or closing the dialog continues without AD.

Enter a numeric SFSU ID or complete numeric-ID `@sfsu.edu` login. Username whitespace is trimmed, leading zeros are preserved, and bare IDs receive `@sfsu.edu`. Full logins receive no extra suffix. Other email addresses show **Enter your SFSU ID, not your email address.** Invalid/empty usernames and empty passwords cannot start authentication. Passwords are not trimmed. Exactly nine digits is not enforced pending confirmation of account-format exceptions.

Authenticate verifies signed/sealed LDAP and the directory naming context in a background worker, independently of whether employee profiles exist. A failure keeps the dialog open for retry or Continue without AD. The check has its own authentication journal/report. Success retains the credential only during the open app session and starts profile discovery. **Directory credentials...** on either tab reopens this same dialog. Passwords/credential objects are not saved or logged; account-name strings are logged. Share mapping remains separate.

**Continue without AD** clears cached directory credentials and enters manual mode. Profile refresh reads registered profiles without LDAP or default-credential fallback. Each selected profile requires an explicitly confirmed nonempty display name; domain IDs are inferred and local profiles have no SFSU ID. **Refresh current names** opens authentication first while in manual mode; saved metadata remains readable offline. Cancelling active authentication interrupts its worker, discards the credential, and preserves unfinished logs as Incomplete.

Before each actual LDAP connection, authentication, profile discovery, and Restore's current-name refresh log the endpoint, Negotiate/signing/sealing settings, credential source, account context, and Windows execution identity. Explicit-account diagnostics record the supplied username rather than a directory-confirmed identity. Developer headless discovery still supports default Windows credentials; those diagnostics label the outbound account Windows-selected/unverified and record execution identity separately. These identities can differ. An unavailable Windows identity does not block lookup. Offline listing records no LDAP attempt. Failed authentication retains the attempted context; passwords and credential objects are never serialized.

Mapping a drive with a power user account does not make that mapping's password available to this LDAP client. Windows exposes the mapping's account name, which could be used for a future username-prefill feature, but the app currently requires a separate Directory credentials entry. Shared credential entry via a different launcher remains a proposal; no mapping changes or password extraction are implemented.

Select a row and choose **Assign Display Name**. The dialog shows the inferred domain ID or local username as read-only text and asks only for a display name, with explicit confirmation that it belongs to the selected profile. These names remain labeled Manually entered. Both account types require a name. Directory SID/ID conflicts cannot be bypassed through this dialog.

Check one or more profiles, then choose **Prepare selected folders**. Each folder has this form:

```text
Backups/SFSU-ID_Display-Name_Computer_YYYYMMDD-HHMMSS/
    backup.json
    Logs/<preparation-run-id>/
        report.html
        events.jsonl
        Raw/
```

Folder timestamps use America/Los_Angeles to the second; metadata also stores UTC and the Pacific offset. Invalid filename characters are replaced and display-name/computer components are length-limited; the full identity remains in metadata. Overly long package paths fail explicitly. There is no extra unique-ID suffix in backup folder names. Atomic directory creation refuses an existing destination, including a concurrent same-timestamp attempt; it never merges or overwrites. Retry later if a collision occurs. Existing GUID-based log run IDs are independent of folder names.

Local folders use `Local-AccountName_Display-Name_Computer_YYYYMMDD-HHMMSS` and the same collision protection. Version-two `backup.json` records account type/name, ID provenance (or NotApplicable for local accounts), source computer/profile SID/path/loaded state, identity confirmation, timestamps, and preparation log ID. Local records have no SFSU ID or directory SID. Version-one domain metadata remains readable without being rewritten. Status is **PreparedOnly**, `HasMigrationData` is **false**, and no migration store is created. Failed/interrupted folders remain available for review as unrecognized when metadata is invalid.

## Restore tab

Opening Restore reads direct child directories under Backups and works offline for both account types. Local entries show Local Account in the SFSU ID column; the Account column shows the actual username. Valid entries start newest first using saved UTC instants. Click Account, Name, SFSU ID, Timestamp, Computer, Status, or Formerly known as to sort. Pacific timestamp display uses underlying UTC values for sorting. Checkbox selections stay attached to their folders. Invalid metadata remains visibly unrecognized. Local-only name refresh does not contact LDAP; current-AD-name checks apply only to saved directory-verified domain identities.

**Refresh current names** optionally looks up saved directory SIDs. Only a matching SID and SFSU ID can update the displayed name and populate Formerly known as. Historical metadata and directory names remain unchanged. Manual labels are never represented as verified renames. LDAP failure keeps saved names available. Cloud lookup is deferred.

Check folders and choose **Review selected backups** to reread their metadata and log the result. Prepared folders produce a warning that there is no migration data to restore. Invalid/out-of-root folders fail review. No restore or account mapping is performed. This version does not recognize an arbitrary legacy USMT store as a verified, usable backup.

## Logs, background tasks, and access

Every discovery, preparation, inventory, and restore review receives a durable real journal and HTML report under root Logs. Actual failures/warnings propagate to the report result. Successful folder preparation is not reported as a successful capture. Completed preparation logs are copied into each newly prepared directory; snapshot-copy failure is visible in the primary report.

Tasks use separate PowerShell runspaces so the window stays responsive. Selection/action controls are disabled during work. Cancel task requests interruption; unfinished journals remain Incomplete and partial folders are preserved. Closing during work first requests cancellation and then closes after the worker ends. Open latest report and Open Logs folder provide access to real results.

This version does not auto-elevate or change execution policy settings. Use an appropriate administrator session if local profile inventory is denied; the future migration engine will require elevation. Mapped drives can be unavailable in a different elevated session. This version does not implement automatic UNC translation/remapping or integrated SMB authentication; establish the share access needed by the session running the launcher. Elevated mapped-share and physical external-drive behavior still require representative validation.

For the current share retest, close the app and copy the updated `Sfsu.Logging.psm1`, `Sfsu.Inventory.psm1`, and `Sfsu.Ui.ps1` into the share package's `App/Scripts/`, retaining existing Backups/Logs. Relaunch the unchanged CMD in the loaner/local-admin/mapped-share context. Test bare-ID/full-login entry, successful/failed authentication, retry, Continue without AD, required manual names, manual-mode refresh, reauthentication from both tabs, and Restore's offline listing. Confirm reports match journals. Keep new run folders on failure; historical reports will not update automatically. Live authentication with the new dialog remains unverified by Codex.

## Validation commands

```powershell
# Real read-only profile discovery and exact-SID LDAP lookup; writes ignored local logs.
.\sfsu-usmt.cmd -DiscoverProfiles

# Optional alternate directory endpoint, without changing the packaged default.
.\sfsu-usmt.cmd -LdapServer ad.sfsu.edu

# Synthetic inventory/identity fixtures and isolated actual folder/log operations.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-Inventory.ps1

# Adds an offscreen form, renders both tabs, and checks sorting/background tasks/cancellation.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Inventory.ps1 -IncludeUi

# Offscreen authentication layout, hints, failure/retry, cancellation, and credential
# transfer with a synthetic directory fixture. No live LDAP.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-AuthenticationUi.ps1

# Existing renderer/journal regression checks; explicitly synthetic.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-Logging.ps1

# Synthetic report replacement/overwrite failures, retries, cleanup, and recovery.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-ReportWrites.ps1
```

Tests write only under ignored `tests/.work/`. UI screenshots use synthetic people. Live runtime logs and prepared metadata can contain employee identity/profile information and technician account names; they are excluded from Git along with Backups. Passwords and credential objects are not written into those records.
