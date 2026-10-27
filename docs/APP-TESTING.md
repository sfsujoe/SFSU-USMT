# Discovery and backup-folder preparation

Open `sfsu-usmt.cmd` from the package. The application uses Windows PowerShell 5.1 and Windows Forms, with the supplied SFSU logo in its header. It works without the ADK payload. This is an operational inventory/preparation test, not a data backup: **no ScanState, LoadState, UsmtUtils, employee-file copying, or account changes occur.**

## Backup tab

The app reads registered `Win32_UserProfile` records and the local account database. It excludes system profiles, profiles from the current computer's local-account SID prefix, missing directories, and directory links. Other domain-style SIDs with existing profile directories are candidates; unresolved/deleted/nonemployee accounts can remain visible. Folder names alone never establish identity. Loaded profiles remain visible; no capture or hive access occurs.

For each candidate, LDAP searches its exact binary SID under the server's default naming context. The default endpoint is `ad.sfsu.edu:389`, with Windows Negotiate authentication, signing/sealing, eight-second request limits, no referral chasing, and a two-result limit. No domain-wide account listing occurs. Returned SID, numeric sAMAccountName, displayName, and UPN are checked before an identity is marked Directory verified. Numeric IDs remain strings, preserving leading zeros; exactly nine digits is not enforced until exceptions are confirmed.

Existing authentication is tried on startup. If it fails, **Directory credentials...** accepts the technician's AD power user account and retries. This credential is reused for later directory actions during the open app session and is not saved to disk or logged. Share mapping remains a separate technician action before launch. Credential cancellation leaves existing rows unchanged. A failed or unavailable directory does not invent a name.

Select an unresolved row and choose **Confirm manual identity...** to enter a numeric SFSU ID and display name, then explicitly confirm that pair belongs to the selected profile. Such rows and their saved metadata say Manually entered. Conflicting directory matches/SIDs cannot be bypassed with manual entry.

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

`backup.json` records schema/version, preparation timestamp, computer, source profile SID/path/loaded state, SFSU identity, directory identifiers or manual confirmation, and preparation log ID. Its status is **PreparedOnly** and `HasMigrationData` is **false**. No migration store is created. A failed/interrupted preparation may leave a folder without valid metadata; it is preserved for review and shown as unrecognized in Restore.

## Restore tab

Opening Restore reads the direct child directories under this package's Backups folder. Saved metadata works offline; no directory connection is required just to list folders. Valid entries start newest first using saved UTC instants. Click Name, SFSU ID, Timestamp, Computer, Status, or Formerly known as to sort. Timestamp cells show Pacific time with an offset; sorting uses the underlying UTC value. Checkbox selection remains attached to its folder after sorting. Unreadable, unsupported, or incomplete metadata is visible with an explicit status rather than silently accepted.

**Refresh current names** optionally looks up saved directory SIDs. Only a matching SID and SFSU ID can update the displayed name and populate Formerly known as. Historical metadata and directory names remain unchanged. Manual labels are never represented as verified renames. LDAP failure keeps saved names available. Cloud lookup is deferred.

Check folders and choose **Review selected backups** to reread their metadata and log the result. Prepared folders produce a warning that there is no migration data to restore. Invalid/out-of-root folders fail review. No restore or account mapping is performed. This version does not recognize an arbitrary legacy USMT store as a verified, usable backup.

## Logs, background tasks, and access

Every discovery, preparation, inventory, and restore review receives a durable real journal and HTML report under root Logs. Actual failures/warnings propagate to the report result. Successful folder preparation is not reported as a successful capture. Completed preparation logs are copied into each newly prepared directory; snapshot-copy failure is visible in the primary report.

Tasks use separate PowerShell runspaces so the window stays responsive. Selection/action controls are disabled during work. Cancel task requests interruption; unfinished journals remain Incomplete and partial folders are preserved. Closing during work first requests cancellation and then closes after the worker ends. Open latest report and Open Logs folder provide access to real results.

This version does not auto-elevate or change execution policy settings. Use an appropriate administrator session if local profile inventory is denied; the future migration engine will require elevation. Mapped drives can be unavailable in a different elevated session. This version does not implement automatic UNC translation/remapping or integrated SMB authentication; establish the share access needed by the session running the launcher. Elevated mapped-share and physical external-drive behavior still require representative validation.

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

# Existing renderer/journal regression checks; explicitly synthetic.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-Logging.ps1
```

Tests write only under ignored `tests/.work/`. UI screenshots use synthetic people. Live runtime logs and prepared metadata can contain employee identity/profile information; they are excluded from Git along with Backups. No credential is written into those records.
