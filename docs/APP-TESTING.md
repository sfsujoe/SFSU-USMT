# Discovery and backup-folder preparation

Open `sfsu-usmt.cmd` from the package. The application uses Windows PowerShell 5.1 and Windows Forms, with the supplied SFSU logo in its header. It works without the ADK payload. This is an operational inventory/preparation test, not a data backup: **no ScanState, LoadState, UsmtUtils, employee-file copying, or account changes occur.**

Normal startup opens the main window maximized, titled **SFSU User State Migration Tool**. Restore Down remains available. The underlined, keyboard-focusable attribution **By Academic Technology at SF State** opens `https://at.sfsu.edu/` in the default browser when activated. Authentication stays normal-sized and centered over the main window. Developer `-BuildUiOnly` retains a normal window for isolated layout tests; it does not open authentication or inventory automatically.

## Appearance and accessibility

Choose **Theme & Font** at the bottom right, or press **Alt+T**. Options are SFSU Classic (the default), SFSU Ocean, SFSU Forest, SFSU Warm, Dark Mode, and Windows system colors. The same dialog offers text sizes of 100%, 125%, 150%, and 200%. Selection previews immediately in the main window and open toolkit dialogs. **Use theme** saves; Cancel, Escape, or closing the dialog restores both the previous theme and text size. The main screen does not display a theme-name label.

The shared preference is `App/Settings/appearance.json`, resolved from the package location. It contains only SchemaVersion, ThemeId, and TextScale. It is created only when a technician saves a choice. There is no AppData, user-profile, registry, or endpoint-local settings fallback. All technicians using that toolkit read the latest saved choice at startup, before AD authentication is shown; already-open sessions retain their own choice until changed or relaunched. Missing settings use Classic/100%. Unreadable, oversized, malformed, unsupported-version, or unknown settings fall back with an explanatory status message. Older version-one files containing only ThemeId still load at 100% text size.

Preference writes use a toolkit-local lock, flushed temporary JSON, replacement with a bounded copy fallback for SMB filesystems, and cleanup. A blocked/read-only save keeps the chooser open with an error and does not claim the choice was saved. Concurrent saves serialize, with the last successful save becoming the next-launch preference. An interruption during the copy fallback can leave invalid JSON; startup then falls back safely. Runtime settings are Git-ignored. Preserve App/Settings when updating the toolkit.

Windows high contrast always overrides custom colors using the actual Windows system palette. It is checked at startup, through UI-thread color-change events, and by a one-second UI timer to catch accessibility changes that do not emit a color-change event. This changes no Windows setting. Turning contrast off restores the selected theme. Override information appears only inside the chooser. Grids, manual-row colors, selection text, buttons, inputs, and all toolkit dialogs use paired foreground/background colors. Native title bars, scrollbars, and system message boxes retain Windows appearance. System/high-contrast mode uses native tab/selector rendering and readable SFSU text branding in place of the white logo. Static HTML reports keep their independent embedded report styles.

Keyboard behavior: Tab/Shift+Tab move between controls; arrow keys navigate grids and selectors; Space toggles the Select-column checkbox; F3 sorts the current text column and toggles ascending/descending; Enter activates a dialog's default action; Escape cancels its dialog (continuing manually for AD). Ctrl+Tab switches Backup/Restore. Main-window shortcuts are Alt+T (theme), Alt+R (refresh current list), Alt+D (directory credentials), Alt+N (assign name in Backup), and Alt+P (prepare/review selection). Credential fields have Alt+I/Alt+P labels; the name field has Alt+D. Each dialog has explicit input names and logical tab order. Tables allow Tab to leave them. Status/error text is exposed through accessible names, polite live-region semantics and UI Automation notifications on supporting .NET Framework runtimes, without moving focus. Verification shows readable **AD verified** text alongside the check mark and retains detailed Identity text; color or emoji alone does not carry the result.

Action bars and header text wrap at smaller widths. Dialogs measure labels/buttons at the current font, can be resized, and scroll when required to keep actions reachable. At large text sizes a small main window also scrolls vertically instead of collapsing its profile grid; Alt+T still opens the chooser. Grid rows/columns grow with text; later frozen profile columns unfreeze when needed to retain horizontal access to the other columns. At ordinary size the first four columns remain frozen when space permits. These changes target WCAG 2.2 AA using WCAG2ICT guidance and native Windows accessibility behavior; they are not a certification of the app.

During border dragging, native ResizeBegin/ResizeEnd events defer custom measurement in the main window and all toolkit dialogs. Native docking, anchoring and painting continue; custom wrapping and column-freeze decisions settle when the drag ends. Unchanged moves and height-only changes avoid unnecessary measurement when layout inputs have not changed. Maximize/restore, programmatic width changes, font changes and initial DPI layout still update outside an interactive drag. Final property changes are briefly batched with SuspendLayout/ResumeLayout and protected against reentrant resize callbacks. Only columns whose required Frozen state changes are updated. Moving a dialog does not disable its automatic content sizing; completing a resize preserves the chosen height. Temporary horizontal scroll offsets are normalized before dialog measurement, retaining vertical scroll position where possible.

For the resize update on an existing D38 package, close the app and replace only `Sfsu.Ui.ps1` and `Sfsu.Appearance.psm1` in App/Scripts. Preserve App/Settings, Backups, and Logs. Manually drag borders/corners at normal and 200% text sizes, release at narrow/wide sizes, cancel a resize back to its original size, move dialogs without resizing, and check maximize/restore, column scrolling/frozen columns and final text wrapping. Automated native-event dispatch validates the deferral logic; actual mouse-drag responsiveness remains a technician check.

For acceptance, use keyboard-only operation, Narrator and/or NVDA on the actual supported Windows/.NET versions, each available Windows contrast theme including light contrast, live contrast toggling with dialogs open, real display/DPI scaling and the four text sizes. Check focus, names/roles/checkbox states, grid navigation/sorting, error/task announcements, button access after resizing, and shared preference permissions from two technician sessions. Automated local contrast/structure/scaling checks are supporting evidence; real assistive-technology and share validation remain pending.

## Backup tab

The D43 discovery regression is corrected: source profiles are inspected through path metadata without requiring directory-list permission. Restricted local and p-account profiles must remain listed; metadata-access denial produces an AccessUnverified warning and a profile-directory tooltip instead of silently hiding the row as a link. Preparation requires successful metadata inspection, while actual capture/file-read access remains untested. Confirmed source links and missing directories remain excluded. Update Sfsu.Inventory.psm1 and Sfsu.Ui.ps1 together with the app closed; no account, ACL or AD sign-in policy change is needed for this fix.

The app reads registered `Win32_UserProfile` records and the local account database. Both local and domain candidates are listed; system profiles, `defaultuser0`, missing directories, and directory links are excluded. The setup-account exclusion matches an exact profile-folder name or a current-machine local SAM account name, ignoring case. It also covers a deleted setup account whose folder survives or a setup account whose profile folder has a different name; `defaultuser01` and other similarly named users remain eligible. Filtering does not delete or modify any account/profile. Local classification uses the current machine's local-account SID prefix, independently of the folder name. The local SAM username is retained, with a folder-name fallback for a deleted local account. Loaded profiles remain visible; no capture or hive access occurs.

For domain candidates, the profile directory base name supplies the SFSU ID: numeric IDs and power-user IDs consisting of `p` followed by the regular numeric ID. Recognized Windows `.DOMAIN`, `.000` and `.DOMAIN.000` suffixes are accepted while preserving leading zeros and the full `p` prefix. Other folder formats are looked up by SID but remain unresolved for preparation instead of being guessed or offered as editable IDs. Local profiles show **Local Account** and retain a separate username/SID. Numeric or p-prefixed local folders are never treated as SFSU IDs. Discovery logs exclusion counts by reason, including unsupported Entra SIDs, without adding excluded personal identifiers.

LDAP searches domain candidates by exact binary SID. Local SIDs are never sent to LDAP, and local-only discovery does not connect. The endpoint is `ad.sfsu.edu:389` by default, with explicit standard-account Kerberos authentication, required signing/sealing, eight-second limits, no referral chasing, and a two-result limit. No NTLM/default-credential fallback, LDAPS or StartTLS is configured. Returned SID and full account ID must match the source SID and inferred folder base ID before Directory verified is shown. A returned regular account cannot substitute for a p-prefixed profile; a standard technician credential can query either profile type. Conflicts cannot be bypassed by assigning a name. Exactly nine digits is not enforced until exceptions are confirmed.

The profile grid puts **Verified** between **SFSU ID** and **Name**, showing ✅ AD verified only for a directory-verified domain profile whose SID, folder ID/account ID, verification timestamp, and nonempty display name agree. Local classification and manually confirmed names do not receive an AD check mark. Assign Display Name clears any previous mark/text because the replacement name is manual. Tooltips explain the verification state, and the Identity column retains its readable status. This indicator says nothing about migration capture or restore success.

**SID** is the final profile column and contains the actual registered profile SID. The profile grid uses readable, user-resizable widths and a horizontal scrollbar. Leading columns remain frozen when space permits; larger text or a narrower window unfreezes later columns to retain access to the rest of the table. The full SID is also available in its cell tooltip. Restore uses horizontal scrolling for large text instead of compressing every column.

The GUI automatically opens **Authenticate to Active Directory**, with the larger, bold message **Enter your SFSU ID and password**. The account field is labeled **Standard SFSU ID (no p-accounts)**; full numeric @sfsu.edu logins remain supported. The short footer reads **AD resolves SFSU ID to Display Name.** **Authenticate** is at the bottom right, with **Continue without AD** immediately to its left where space permits. Enter authenticates; Escape or closing the dialog continues without AD and clears existing credentials, including during reauthentication. Larger fonts scale the heading and can wrap dialog content to keep it accessible.

Enter a standard numeric SFSU ID, optionally followed by `@sfsu.edu`. P-accounts are rejected before binding in both the UI and backend; they remain available as migration profiles. Username whitespace is trimmed, leading zeros are preserved, and bare IDs receive `@sfsu.edu`. Other email addresses show the SFSU ID hint. Invalid/empty usernames and empty passwords cannot start authentication. Passwords are not trimmed. Exactly nine digits is not enforced pending confirmation of account-format exceptions. Technician sign-in verifies the LDAP connection independently; each profile requires its own SID, complete ID and display-name verification.

Authenticate verifies the Kerberos-only protected LDAP connection and naming context in a background worker, independently of whether profiles exist. Failures keep the dialog open with a bounded 2-to-30-second retry cooldown or Continue without AD. The check has its own journal/report. Success starts discovery; credentials expire after ten minutes without directory activity, with active tasks protected until completion. **Directory credentials...** reopens the dialog. Plaintext conversion uses a direct .NET API rather than a cmdlet parameter, avoiding the reviewed module-logging path. App reports omit passwords/credential objects and record account-name strings. Endpoint-memory exposure remains a limitation. Share mapping remains separate.

Actual authentication/start/task failures display ⛔ before their readable error text, with the existing accessible status announcement. The symbol is generated from Unicode U+26D4 for Windows PowerShell 5.1 compatibility and remains paired with text in every theme. Input validation, authentication-in-progress and manual cancellation keep their own messages. Backend journal status strings remain unchanged. The former password/privacy paragraph has been replaced by the short identity-resolution purpose line; this copy change does not change credential storage or account-name logging behavior.

**Continue without AD** clears cached directory credentials and enters manual mode. Profile refresh reads registered profiles without LDAP or default-credential fallback. Each selected profile requires an explicitly confirmed nonempty display name; domain IDs are inferred and local profiles have no SFSU ID. **Refresh current names** opens authentication first while in manual mode; saved metadata remains readable offline. Cancelling active authentication interrupts its worker, discards the credential, and preserves unfinished logs as Incomplete.

Before each allowed LDAP connection, authentication, discovery and current-name refresh log the endpoint, Kerberos-only/signing/sealing policy, explicit credential source, supplied account and Windows execution identity. A successful Kerberos bind is reported as such; configured security settings are distinguished from packet-level evidence. Execution identity is context, not the outbound account. Developer discovery without `-DirectoryCredential` is LDAP-free. Unavailable Windows identity does not block lookup. Offline listing records no LDAP attempt. Passwords and credential objects are never serialized.

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

For the current share retest, close the app and copy the updated `Sfsu.Logging.psm1`, `Sfsu.Inventory.psm1`, `Sfsu.Ui.ps1`, and new `Sfsu.Appearance.psm1` into the share package's `App/Scripts/`, retaining existing Backups/Logs/App/Settings. Relaunch the unchanged CMD in the loaner/local-admin/mapped-share context. Test bare-ID/full-login entry, successful/failed authentication, retry, Continue without AD, required manual names, manual-mode refresh, reauthentication from both tabs, and Restore's offline listing. Confirm reports match journals. Keep new run folders on failure; historical reports will not update automatically. Live authentication with the new dialog remains unverified by Codex.

For the branding/authentication/defaultuser0 update on an existing D39 package, replace `Sfsu.Ui.ps1`, `Sfsu.Appearance.psm1`, and `Sfsu.Inventory.psm1` with the app closed. Check the maximized startup, exact title/attribution/button labels, keyboard/browser link activation, failed-authentication marker, bold heading and short purpose line under normal/large-text/high-contrast conditions. Verify that defaultuser0 is absent while ordinary local/domain profiles remain listed. Printer migration is deferred and has no UI or runtime implementation in this version.

Update the complete App/Scripts source set, including the appearance and maintenance modules, with the app closed; preserve App/Settings, Backups and Logs. Confirm bare/full/case-varied p-account AD login rejection, successful standard-account Kerberos binding, verification of p-prefixed and suffixed domain profiles, manual continuation, credential expiry/retry handling, metadata, offline listing/review and current-name refresh. Live standard-account Kerberos and directory read access still require a technician test. See SECURITY.md for native path protection, retention and permission-screening acceptance checks.

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

# Theme/text-size persistence, contrast, failure handling, keyboard routing,
# high-contrast palette injection, real separate-process reload and UI renders.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Appearance.ps1

# Native resize-event dispatch, deferred measurements, frozen-column event counts,
# maximize/restore, dialog moves/cancelled drags and font/programmatic changes.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-ResizeUi.ps1

# Existing renderer/journal regression checks; explicitly synthetic.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-Logging.ps1

# Synthetic report replacement/overwrite failures, retries, cleanup, and recovery.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-ReportWrites.ps1
```

Tests write only under ignored `tests/.work/`. UI screenshots use synthetic people. Live runtime logs and prepared metadata can contain employee identity/profile information and technician account names; they are excluded from Git along with Backups. Passwords and credential objects are not written into those records.

User field report on 2026-11-02: the discovery fix worked and AD authentication is functioning after the security changes. This supports the tested setup; exact host/account/protocol evidence and the broader environment/permissions/accessibility matrix were not supplied. No capture or restore result is implied.
