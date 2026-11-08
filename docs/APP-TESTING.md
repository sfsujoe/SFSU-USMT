# Application testing

The GUI now connects native capture and restore. Read the [migration guide](MIGRATION.md) for prerequisites, exact policies and controlled VM acceptance. Earlier discovery/UI field reports and synthetic tests do not establish a successful native migration.

## Technician flow

Keep sfsu-usmt.cmd with the complete App folder, including the new engine C# source and policy/UI modules. Preserve Backups, Logs and App/Settings. Normal GUI startup requests UAC before AD sign-in and hides the console, with a possible brief CMD flash. Already elevated launches skip UAC; cancellation stops startup. A mapped entry path resolves to UNC, but the elevated account still needs share access. No drives/SMB credentials or saved policies are changed. For visible startup diagnostics, run the entry script from an already elevated PowerShell console. Headless/maintenance/BuildUiOnly commands retain caller privileges and synchronous behavior.

The main window remains maximized with the SFSU logo, title and linked Academic Technology attribution; AD sign-in stays normal-sized and centered. Explicit Kerberos-only signed/sealed LDAP, generalized numeric/alphabetic/p-prefixed logins, manual mode, ten-minute inactivity expiry and bounded retry/cancellation are unchanged. Folder spelling remains independent of SID verification. Manual domain identity requires confirmed ID/name; local profiles require a display name. Restricted source metadata access is reported instead of misclassified as a link. System/setup/missing/linked profiles remain excluded. See [identity configuration](IDENTITY.md).

Select signed-out profiles, then choose **Back up selected profiles**. Each profile has a location dialog listing cloud roots/caches, redirected folders and unresolved-provider notes. Add missing cloud/custom browser locations and confirm review before capture. Uploads are assumed complete; this is not a sync-status audit. The engine estimates size, captures one unique compressed unencrypted store per profile, and verifies each store without per-file prompts. No existing backup is overwritten or merged.

The Restore tab shows verified captures alongside PreparedOnly/incomplete folders. Only verified schema-four native captures restore. Choose **Restore selected backups**. Every target is checked before account/data changes; any local account or employee profile/folder collision stops all targets. For each local account, enter/confirm its masked password, explicitly choose enabled/disabled and choose Administrators membership (default No). Cancelling any prompt clears retained secrets and makes no account/data changes. The final summary excludes passwords. Accounts are created disabled, data applied and final settings verified. Failure preserves partial data and disables only accounts created by that run. Domain identity remains the original SID.

Progress describes the current native command. **Cancel task** stops its job and descendants without rollback or deletion. **Open latest report** and **Open Logs folder** expose native evidence and acceptance limitations. Store verification is not an exhaustive content comparison or intended-user EFS decryption test. Retain sources until the designated restore/coverage/decryption acceptance is complete.

## Appearance and accessibility

**Theme & Font** (Alt+T) offers six shared themes and 100/125/150/200% text. Use theme saves only App/Settings/appearance.json; Cancel restores the prior selection. There is no endpoint-local setting or main-screen theme-name label. Windows contrast colors override custom themes without changing preferences. Preserve Settings during updates.

Account/location dialogs use shared fonts, accessible names, masked password fields, keyboard access and measured/scrollable layout. Local-account dropdowns use themed owner drawing with native contrast-mode fallback; multiline location fields scroll. Interactive border dragging defers custom layout while native docking/painting continue. Validate actual keyboard focus, grid selection/sorting, status/error announcements, all contrast themes, real DPI/200%-text, mouse resizing and Narrator/NVDA. Synthetic contrast/render checks are not compliance certification.

## Synthetic validation

Run with Windows PowerShell 5.1. Fixture writes stay in Git-ignored tests/.work. Native path-guard suites need an ordinary Windows context when the sandbox denies parent-directory handles. New engine tests replace all USMT/profile/account services with synthetic fixtures. Native-process tests start harmless PowerShell children, never vendor executables. UI fixtures do not click live migration actions with real profiles.

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Engine.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-EngineNative.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-LiveNativeReporting.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-MigrationUi.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Inventory.ps1 -IncludeUi
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-ProfileDiscoveryAccess.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Security.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-AuthenticationUi.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Appearance.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-ResizeUi.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Logging.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-ReportWrites.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-Elevation.ps1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File tests/Test-GuiLauncher.ps1
```

Read-only real profile discovery remains an intentional developer command: sfsu-usmt.cmd -DiscoverProfiles writes runtime identity logs and does not run USMT; no explicit directory credential means LDAP-free discovery. -Headless -Scenario Failed generates synthetic report samples. -BuildUiOnly builds the UI without automatic elevation, credentials, discovery or migration.

User field evidence: the user reported working discovery/AD authentication on 2026-11-02 and manually elevated VM mapped-drive access on 2026-11-07 with the preceding app. Neither report validates the new automatic elevation/UNC relaunch, account provisioning, real native migration or the full host/share/architecture matrix. Follow the controlled acceptance cases in MIGRATION.md before employee migration/re-imaging.

November 8 VM capture stopped on the first of five profiles after a sharing exception during live reporting; native capture reached 14% and no store verification ran. The fix is local: close the app, replace Sfsu.Logging.psm1 and Sfsu.Engine.psm1 in App/Scripts, then relaunch before another controlled VM capture. Restart is required because the guarded-file helper is compiled into the PowerShell process. Preserve existing Backups/Logs/Settings and retain the failed run. Test that capture proceeds through repeated live report refreshes, closes normally and reaches UsmtUtils verification. The 32-check live-native-reporting suite exercises actual open/exclusive writers, blocked reports, warning retention, required-report failure after process completion, cancellation/nonzero exit and unchanged link/write guards using harmless child processes. It does not establish that a real VM capture now completes.
