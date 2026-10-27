# SFSU USMT project runbook

Last updated: 2026-10-27 (America/Los_Angeles)

## Project purpose

Improve the technician workflow for backing up and restoring employee files and settings before computer re-imaging or replacement. The existing toolchain wraps Windows User State Migration Tool (USMT). The intended experience has one clear entry point that guides the technician through Backup or Restore.

This is the maintained project record, not an approved procedure for performing a production migration. Keep current state and next steps near the top; preserve concise decision and session history below.

## Current state and handoff

- Phase: local foundation development. The portable launcher and logging/reporting layer are implemented; the original toolkit and UI prototype remain archived references. No replacement backup/restore engine or production migration integration exists yet.
- The user confirmed the portable `sfsu-usmt.cmd` / `App/` / `Backups/` layout and approved the logging recommendations on 2026-10-26. The reporting-preview launcher resolves its package root independently of the working directory, creates missing Backups/Logs folders, and preserves existing contents. Mapped-share/elevated/physical external-drive compatibility still needs representative tests.
- [sfsu-usmt.cmd](sfsu-usmt.cmd) opens a reporting-preview window with five sample outcomes and Open Report/Open Logs controls. Samples never invoke USMT, change accounts, or copy employee data; their destination write probe is real and their capture/verification events are explicitly simulated. [REPORTING.md](docs/REPORTING.md) documents headless samples, recovery, the module API, and test commands.
- [Sfsu.Logging.psm1](App/Scripts/Sfsu.Logging.psm1) implements durable JSON Lines events, preserved raw diagnostic files, self-contained sortable/filterable/searchable HTML reports, chronological step/checkpoint summaries, explicit error/warning labels, print/no-script views, incomplete-run recovery, and finalized per-backup log snapshots. Root Logs is the primary run record; snapshot copies remain with the backup.
- The user-supplied ADK folder `App/User State Migration Tool/` remains local and is Git-ignored; its contents were not modified, validated, or executed. Obtain that payload separately before future migration integration; the reporting preview works without it. The supplied `App/Assets/SFSU Logo.png` is included in the reporting source and embedded in reports when readable.
- New identity requirements (2026-10-26): resolve numeric SFSU IDs to display names and include both in the UI and future Backups directory names, regardless of domain membership/connectivity. On 2026-10-27 the user supplied ADUC screenshots and authorized a targeted LDAP lookup. The successful read-only query returned one exact sAMAccountName match with displayName, UPN, and SID, consistent with the screenshots. Windows authentication with LDAP signing/sealing worked from the current host outside the sandbox. The user reports ADWS has not been accessible; no ADWS dependency was used. A reusable identity module, cloud/offline fallback behavior, and folder-name format remain pending; other hosts/accounts and live cloud lookups remain untested.
- The preserved Windows Forms mock-up is [Migration-Wizard-Mockup.ps1](archive/legacy-and-mockup/Migration-Wizard-Mockup.ps1), launched by [Migration-Wizard-Mockup.cmd](archive/legacy-and-mockup/Migration-Wizard-Mockup.cmd). All 10 original files, both mock-up files, and the logo PNG are together in `archive/legacy-and-mockup/`.
- The mock-up has Backup/Restore choices, a working folder picker, editable network path, Back/Next navigation, a review screen, and a demo completion message. It does not run USMT, enumerate employee profiles, validate network access, or copy migration data.
- The user reported that the initial launcher was blocked. Adding process-scoped `-ExecutionPolicy Bypass` resolved that on the computer they tested. The cause of the original block was not independently diagnosed; no organization-wide compatibility claim has been established.
- The header now uses SFSU purple `#442C8B`, gold `#FFD24F`, and the supplied white PNG logo. The Next button also uses the purple. The user approved the appearance.
- Original script and prototype contents are unchanged; 13 files were relocated locally on 2026-10-23 and verified against their pre-move SHA-256 hashes. No production migrations, network-share cleanup, or deployment have been performed by Codex.
- [.gitignore](.gitignore) excludes `/archive/legacy-and-mockup/`. This is a local preservation folder, not a Git-backed archive: its contents will not be included in a future push or fresh clone unless the user later changes that decision. No files were deleted. The mock-up's sibling launcher/logo paths remain intact. The user subsequently supplied the deployed Scripts, Scripts-Fast, USMT32, USMT64, arm64, and a standalone restore workaround; these remain reference inputs, not an approved executable migration package.
- The expanded archive was reviewed on 2026-10-23: 580 files, 23 XML, and 12 executables. The main executables in all three architectures report `10.0.26100.1`. Deployed Scripts matches the previously reviewed 10 files exactly. Detailed evidence and coverage findings are in [CURRENT-WORKFLOW-REVIEW.md](docs/CURRENT-WORKFLOW-REVIEW.md).
- Important new findings: the x64 Config.xml disables the Office 16 parent and nests browser entries beneath it; browser detection uses old installation assumptions; the x86 folder lacks XML requested by standard commands; ARM64 binaries are not selected by the scripts; Fast changes collection/restore policy and can return to the standard Scripts path. Shared folders and fixed-drive document searches broaden scope beyond the selected profile.
- Project workflow setup is complete: this runbook, AGENTS.md, and the project-local start-chat/chat-closeout skills are installed. Skill content, metadata structure, and project links were checked. Skill discovery in a fresh chat has not yet been user-tested.
- Git was initialized at the user's request on 2026-10-23. The initial local branch is `main`; origin is [sfsujoe/SFSU-USMT](https://github.com/sfsujoe/SFSU-USMT.git). Repository-local author identity uses the name/email supplied by the user. The identity was not set globally.
- Before initialization and again before the first push, successful `git ls-remote` checks returned no HEAD or branch refs from origin. There was no existing remote history to integrate. The user subsequently authorized publication, and the initial commit `e50aa54` was successfully pushed on 2026-10-23. GitHub write access is now confirmed; main tracks origin/main.
- The initial local baseline comprises README.md, .gitignore, AGENTS.md, this runbook, the workflow review, and both skills plus their UI metadata. The ignored reference archive is excluded. Use Git history for the initial commit identifier; it is not embedded in its own runbook snapshot.
- Closeout publication (2026-10-27): the user explicitly authorized committing and pushing this chat's changes to origin/main. The reviewed set is the portable reporting launcher/module/template/logo, its tests and usage notes, this runbook, README, and ignore rules. Backups, generated logs/test artifacts, the reference archive, and local ADK payload are excluded. The pre-publication origin main check matched local commit f3df3ee; publication result is pending below.

## Recommended next steps

These are proposed follow-ups, not permission to perform migrations or deploy changes.

1. Define and implement the reusable identity resolver next: build on the successful bounded .NET LdapConnection proof, match source SID or exact SFSU ID, retrieve displayName/account identifiers, and agree saved identity metadata plus explicit offline/unresolved handling. This remains proposed next work, not completed functionality. Validate against designated representative accounts before UI integration.
2. Agree on the real Backup and Restore screen flows: employee/profile selection, account mapping, storage selection, prerequisites, result handling, and post-restore tasks.
3. Review the now-documented [deployed configuration findings](docs/CURRENT-WORKFLOW-REVIEW.md) with the team. Confirm why Office/browser exclusions exist and whether selected-profile, shared-folder, and fixed-drive document coverage is intended. Binary versions and static rule contents are now known; actual migration coverage still needs runtime tests. Downloads through USMT was discussed as an alternative to XCOPY; no migration-rule change has been approved or implemented.
4. Validate the reporting foundation on mapped shares, direct UNC paths, elevated sessions, and representative external-drive filesystems; test the preview window interactively. Settle dependency packaging and the update procedure; replacing App must preserve backup and log data.
5. Define backup identities/names, overwrite protection, verification, and retention before implementing data operations. Log placement/report design are approved and the reusable logging layer is implemented. Cloud provider/authentication and the new ADK payload/version still need review.
6. Implement migration integration incrementally against designated test profiles and stores, then validate on representative restricted computers before production rollout.

Optional next UI experiment: show simulated progress and stage indicators. Progress bars, animation, and elapsed time were discussed; none has been implemented or requested for implementation yet.

## Confirmed decisions and constraints

| ID | Date | Decision or constraint | Basis |
| --- | --- | --- | --- |
| D01 | 2026-10-23 | Work is based on a network share. Technicians currently enter its Scripts folder and launch SCANSTATE-LAUNCHER.bat or LOADSTATE-LAUNCHER.bat. | User description and directory screenshot. |
| D02 | 2026-10-23 | Aim for one guided Backup/Restore entry point. The current directory structure can be reconsidered. | User request; no final replacement structure approved. |
| D03 | 2026-10-23 | Some computers have strict execution controls. A self-contained executable may face team acceptance and policy hurdles. | User constraint; exact policies remain unknown. |
| D04 | 2026-10-23 | Build a UI-only PowerShell wizard first, including a functional directory picker. | User request; implemented. |
| D05 | 2026-10-23 | Launch the mock-up using process-scoped `-ExecutionPolicy Bypass`; do not change saved machine/user execution policy. | User requested the change and reported it worked. This is a prototype launch decision, not a production policy decision. |
| D06 | 2026-10-23 | Use `#442C8B` and `#FFD24F` in the header and the supplied PNG logo. | User specified the colors and asset; implementation accepted. |
| D07 | 2026-10-23 | Maintain a project runbook and provide start-chat and chat-closeout skills for continuity. | User request. |
| D08 | 2026-10-23 | At closeout, ask whether project changes should be committed and pushed to https://github.com/sfsujoe/SFSU-USMT.git. Prepare the runbook and change summary first; publish only after the user's answer authorizes it. | User supplied the repository URL and requested the closeout question. |
| D09 | 2026-10-23 | Move the original scripts and mock-up into a separate reference folder and ignore it in Git. | User requested cleanup and local preservation. Implemented as `archive/legacy-and-mockup/`, including the mock-up logo so it remains beside the script. Future reuse is undecided. |
| D10 | 2026-10-23 | Initialize local Git, connect origin to the supplied GitHub repository, and make the first local commit. | User request; user supplied the author name/email. Remote advertised no existing refs, so main was selected as the initial local branch. This request does not include pushing. |
| D11 | 2026-10-23 | Publish the initial baseline to GitHub and set main's upstream. | User explicitly requested the push after the local commit. The initial push succeeded; future publication continues to follow the closeout confirmation workflow. |
| D12 | 2026-10-26 | Use a minimal, portable launch directory: `sfsu-usmt.cmd`, `App/` for scripts/logo/USMT dependencies, and `Backups/`. Resolve paths from the package location so it can run under different mapped drive letters or from an external drive. | User requirement; implemented/tested locally for the reporting preview. Share/elevated/removable-drive validation and production packaging remain pending. This refines D02's previously open layout. |
| D13 | 2026-10-26 | Create Backups if absent; use it if present without deleting any existing backups. | User requirement; implemented in the reporting preview and checked against synthetic existing data. Backup identity, store overwrite policy, and retention remain to be designed before migration integration. |
| D14 | 2026-10-26 | Logs must be very human-readable, distinguish steps and checkpoints clearly, and mark errors with an exclamation mark. Use HTML with a sortable table. | User request, followed by explicit approval to implement the recommendations. Reporting implemented and locally tested; actual USMT interpretation/integration remains pending. |
| D15 | 2026-10-26 | Implement the recommended root Logs plus finalized per-backup copies; fixed-order step summaries, sortable/filterable detailed events, explicit outcomes and evidence-based checkpoints, preserved raw logs, durable events, and incomplete-run handling. | User explicitly said "Yes, I like your recommendations here. Make it so." Scope is the reporting/portable foundation, not production migration execution. |
| D16 | 2026-10-26 | Resolve SFSU ID numbers to Display Name; surface both in the UI and use both when naming future backup directories. | User requirement; lookup implementation and exact naming scheme are pending. |
| D17 | 2026-10-26 | Identity handling must support mixed connectivity/domain states rather than assuming a domain-joined machine with AD access. | User clarified that the tool should be flexible enough to work regardless. Offline operation cannot discover an unknown display name without a saved identity source. |
| D18 | 2026-10-27 | In Office365Users, the SFSU ID is the first nine characters of userPrincipalName. | User-reported cloud naming convention. ADUC screenshots and a subsequent authorized live LDAP query confirm SFSU ID in sAMAccountName and the UPN prefix, plus a populated displayName, for one on-premises account. Validate representative accounts and scope/format before applying the resolver broadly. |
| D19 | 2026-10-27 | Use direct LDAP for the on-premises AD identity provider; do not require ADWS/Get-ADUser. | User reports prior lack of ADWS access. An authorized direct LDAP lookup later succeeded from the current host using Windows authentication, signing, and sealing; ADWS itself was not probed. This supersedes the earlier Get-ADUser diagnostic/provider suggestion for this environment. |
| D20 | 2026-10-27 | Commit and push the reviewed reporting foundation and reconciled project handoff to the designated GitHub repository on main. | User explicitly invoked chat-closeout "With git commit and push." This supplies publication authorization without another confirmation; it does not authorize deployment or migrations. |

## Milestones

| Milestone | Status | Evidence or remaining work |
| --- | --- | --- |
| Review existing scripts | Complete, 2026-10-23 | All 10 original files inspected without executing migration operations. Findings documented below. |
| Compare packaging approaches | Complete, 2026-10-23; refined 2026-10-26 | Original executable/script comparison was followed by the confirmed portable CMD/App/Backups layout. Production dependency packaging/release procedure remains open. |
| Build UI prototype | Complete, 2026-10-23 | Three-step wizard with folder picker and review. User confirmed it launched after Bypass was added. |
| Apply SFSU branding | Complete, 2026-10-23 | User colors and logo integrated; header rendering inspected; user accepted appearance. |
| Establish runbook and chat skills | Complete, 2026-10-23 | Runbook, AGENTS.md, and both project-local skills installed; content and relative links checked. Fresh-chat discovery remains to be user-tested. |
| Clean up local project directory | Complete, 2026-10-23 | Moved 13 original/prototype/asset files to a Git-ignored reference folder; contents verified unchanged; current file links and project instructions updated. |
| Inspect expanded deployed toolkit | Complete, 2026-10-23, static review only | Inventory/version/architecture checks, source comparisons, XML and script parsing, rule tracing, and two historical log reviews documented in docs/CURRENT-WORKFLOW-REVIEW.md. No migrations run. |
| Establish initial Git baseline | Complete, 2026-10-23 | Commit e50aa54 on local main; configured origin and author, nine documentation/skill files, and verified archive exclusion. |
| First GitHub publication | Complete, 2026-10-23 | User-authorized push of e50aa54 succeeded; main tracks origin/main. The reference archive remains excluded. |
| Implement portable reporting foundation | Complete locally, 2026-10-26 | CMD/PowerShell reporting preview, reusable logging module, HTML template, usage notes, synthetic PowerShell and offline Edge tests. Share/external-drive and interactive-window tests remain pending. No USMT migration ran. |
| Prove direct LDAP identity lookup | Complete for one account/context, 2026-10-27 | User-authorized signed/sealed Windows-authenticated LDAP query returned one exact account with matching displayName/account/UPN and SID. Reusable resolver, off-domain/cloud/offline paths, and representative-account tests are not implemented/validated. |
| Integrate USMT and production checks | Not started | Requires agreed coverage/workflow, resolution of the configuration findings, and designated test data. |
| Pilot and deploy replacement workflow | Not started | Requires successful backup/restore tests and policy compatibility checks. |

## Project files and operating context

Local development folder: `C:/Users/909272551/src/USMTScripts`.

### Portable package and reporting foundation

Confirmed requirements; implemented for the reporting preview, with real migration integration pending:

- `sfsu-usmt.cmd`: the single technician entry point.
- `App/`: scripts, logo, USMT toolsets and their dependencies, and migration rules.
- `Backups/`: created when missing; existing backups must be preserved.
- The whole package can be placed on a mapped share or external drive without a hard-coded drive letter or reliance on the launching working directory. Elevated share access still needs a deliberate design and testing because drive mappings can differ after elevation.

The log recommendation was subsequently approved and implemented: root `Logs/<run-id>/` contains `report.html`, `events.jsonl`, and `Raw/`. The module exports finalized snapshots into an existing `Backups/<backup-id>/Logs/<run-id>/` without replacing existing snapshots or backup data. Copy failures raise an error and add a warning to the primary report; partial staging folders can remain explicitly suffixed `.partial`. The preview offers Open Logs and Open Report. Startup failures before module initialization use a plain-text fallback; an unwritable Logs destination produces a console error. Log retention remains undecided.

Implemented HTML behavior: overall outcome, ordered step cards with durations/checkpoints, and a separate sortable event table with sequence, Pacific time/offset, step, severity, message/details, and next action. Error/warning markers combine exclamation marks, text, and color. Search, severity filtering, reset, full chronological printing, and no-script reading work locally in Edge. Styling/scripts/logo are embedded without remote resources. Messages/details are escaped. Explicit completion and step results are required; errors/warnings propagate to outcomes. Interrupted/damaged journals remain Incomplete and can rebuild HTML without running migration commands. The logging caller must supply truthful checkpoint evidence; capture, verification, and restore tests are separate. Actual USMT logs have not yet been integrated.

Implemented safeguards for reporting: unique run IDs, existing-folder preservation, exclusive temporary write probes, refusal to overwrite log snapshots, and durable flushed events before HTML refresh. Atomic report replacement has an overwrite fallback for filesystems that reject replacement; interruption during that fallback can require journal-based regeneration. Backup IDs, migration-store overwrite protection, and pre-migration checks remain future work. Updating the tool should replace App and the launcher without replacing Backups or Logs. Runtime Logs, Backups, and synthetic test artifacts are Git-ignored.

### Identity lookup design (proposed)

The user requires display name plus SFSU ID in the UI and backup folder names, with flexibility across domain-connected, off-domain, and offline scenarios. The on-premises provider must use direct LDAP because ADWS is reported unavailable. Cloud authentication/fallback behavior and the naming convention remain to be settled.

- Recommend one identity resolver with direct Windows/.NET DirectorySearcher LDAP queries for AD when reachable with an authorized identity; optional Microsoft Graph for Entra users when internet/authentication/permissions are available; and identity metadata already saved with a backup for offline restore lists. The earlier Get-ADUser suggestion is superseded by the reported ADWS restriction: RSAT installation alone would not address that dependency. Exchange Online is not technically required for directory display-name lookup; its recipient commands cover mail-enabled objects and would add a cloud/module dependency.
- Recommend saving SFSU ID, display name, source SID, lookup source/time, and capture details in backup metadata. Preserve the saved identity label when showing older backups; live lookups can supplement it without silently changing historical identity or renaming backup folders.
- When no live or saved source can resolve an ID, show Name unavailable and preserve the known ID/SID. Any technician-supplied name must be labeled as manually entered, not directory-verified. Whether capture may proceed with an unresolved name and how manual confirmation works remain decisions to settle.
- Cloud mapping is now user-reported: first nine characters of userPrincipalName in Office365Users. That connector exposes Entra user profiles through Microsoft Graph; it is not a separate employee directory. Validate the expected internal account pattern before extracting an ID, and use the full returned UPN/object identity for lookups rather than constructing an email address. Compare a known account's AD sAMAccountName, userPrincipalName, employeeID/employeeNumber, displayName, and SID to establish the on-premises mapping; cloud/on-premises UPNs need not be identical. Ambiguous/conflicting results must not silently select an account.
- The user's ADUC Account/General screenshots confirm the SFSU ID in sAMAccountName, `<SFSU-ID>@sfsu.edu` as UPN, and a populated displayName for that account. Prefer testing exact sAMAccountName lookup (or source SID when available) and reading displayName, userPrincipalName, and objectSid; a separate employeeID attribute is not needed if this account-name convention holds. This is screenshot evidence for one account, not a live query or campus-wide validation; do not copy the personal account number, display name, email, or telephone into project records.
- Proposed directory label: sanitized/length-limited SFSU ID and display name, plus source computer, capture timestamp, and a unique capture identifier. Read authoritative identity/account mapping from metadata, not by parsing directory names. Exact naming and handling of duplicate/changed/unresolved names remain pending.

The reusable resolver remains design work. A subsequent authorized proof of connectivity used the built-in .NET System.DirectoryServices.Protocols LdapConnection with Windows Negotiate authentication, LDAP signing/sealing, and bounded timeouts against ad.sfsu.edu. RootDSE discovery and an exact sAMAccountName query returned one matching user with the expected displayName/UPN and a SID attribute. This test used LdapConnection rather than the previously proposed DirectorySearcher. No PowerShell modules were installed or directory data modified, and no personal account values were saved in project records. Cloud authentication, explicit-credential/off-domain operation, and offline fallback remain untested.

The screenshot showed `V:` mapped to the `backup$` share on `qml.ad.sfsu.edu`, inside `Migration v2`. Its visible folders were `arm64`, `Completed`, `Logs`, `Migration_Data`, `Scripts`, `Scripts-Fast`, `USMT32`, and `USMT64`. It also showed a migration ZIP, a troubleshooting BAT, marker/instruction text files, and `.DS_Store`. This is a screenshot inventory, not a live audit or authority to delete anything. The exact UNC deployment path and permissions should be confirmed before implementation.

### Archived prototype (local reference only)

- [Migration-Wizard-Mockup.cmd](archive/legacy-and-mockup/Migration-Wizard-Mockup.cmd): starts Windows PowerShell with `-NoLogo -NoProfile -STA -ExecutionPolicy Bypass`, resolves the PS1 relative to the launcher, and keeps startup errors visible.
- [Migration-Wizard-Mockup.ps1](archive/legacy-and-mockup/Migration-Wizard-Mockup.ps1): Windows Forms UI. Typed paths are deliberately accepted without network validation. The picker selects existing folders and does not offer creation of a new folder.
- Logo: `documents_d7be78a49a8_be78a49a8fc_SFSU Identity_Primary_White_rgb_1743527167975_2500x2500.png`. The decoded image is 1401 x 1401 pixels despite its filename. Keep it beside the PS1; loading is relative to `$PSScriptRoot`. The image is cloned to avoid locking the supplied file, and disposed when the form closes. A missing/unreadable logo does not intentionally prevent the wizard from opening.

### Legacy toolchain

All files in this table now live in `archive/legacy-and-mockup/`. They are preserved unchanged as references; their prior production layout is described for context, not recreated by this local archive.

| File | Purpose |
| --- | --- |
| SCANSTATE-LAUNCHER.bat | Starts registry-sid.ps1. |
| registry-sid.ps1 | Lists profiles, prompts for a selection, stores its SID, and calls scan.bat. |
| scan.bat | Copies Downloads separately, then invokes ScanState. |
| LOADSTATE-LAUNCHER.bat | Starts loadstate.ps1. |
| loadstate.ps1 | Lists migration folders and routes to domain or local restore. |
| load.bat | Domain restore, separate Downloads copy, optional local admin addition, and closing reminders. |
| load-local.bat | Local-account restore using /lac, separate Downloads copy, and account-enablement reminder. |
| locadmin.ps1 | Adds an SFSU account to the local Administrators group. |
| dload-exclude.txt | XCOPY exclusion strings intended to omit EXE/MSI files from Downloads. |
| load - Copy.bat | Experimental domain restore variant referencing ExcludeSystemFolders2.xml; comments identify Dropbox-exclusion testing. |

The scripts expect sibling USMT32/USMT64, Migration_Data, Logs, and XML files such as config.xml and ExcludeSystemFolders.xml. The later supplied snapshot now includes all three architecture toolsets and both deployed script directories, but no migration stores or normal per-user ScanState/LoadState log pair. Config.xml and the custom exclusion files exist only in USMT64, leaving the standard x86 path incomplete. The arm64 folder contains ARM64 binaries, but the legacy selection logic only distinguishes process pointer sizes and never selects it.

## Findings and improvement backlog

The following findings came from source review. They are not implemented fixes.

| Priority | Finding | Proposed direction |
| --- | --- | --- |
| High | Capture reuses a profile-named store and passes /o, allowing replacement of existing store data. | Unique computer/user/capture identity; deliberate overwrite handling. |
| High | Downloads copy exit codes are not checked; load-local.bat reaches Downloads copying after LoadState failure. | Track each stage, stop dependent operations on failure, and distinguish success, partial results, cancellation, and failure. |
| High | Main capture/domain restore combine MigUser.xml and MigDocs.xml; local restore uses a different rule/config set. | Inspect deployed XML, choose a documented migration policy, and test consistent capture/restore behavior. Microsoft advises against combining these two discovery files. |
| High | Active x64 Config.xml disables the Office 16 parent while several child entries say yes; Firefox/Chrome are nested under that disabled Office branch. | Confirm intended app-setting exclusions and create correctly structured rules; validate with representative Office and browser installations. Document files are a separate coverage question. |
| High | Standard x86 capture lacks Config.xml and ExcludeSystemFolders.xml; standard/Fast x86 domain restore lacks Config.xml. ARM64 is not routed by the selectors. | Define supported architectures and validate complete, consistent dependencies before selecting an engine. |
| High | Fast capture drops Config.xml/custom exclusions and adds /c; Fast restore changes its XML set and can restart into standard Scripts. | Replace implicit mode changes with one documented policy and explicit technician options. |
| High | dload-exclude.txt has .exe and .msi each followed by a backslash, which does not match ordinary installer.exe or installer.msi filenames. | Correct and test exclusions; consider integrating Downloads into migration rules. |
| High | No store verification is performed before re-imaging readiness is implied. | Verify compressed stores with UsmtUtils /verify; also test actual restores and coverage. |
| Medium | Object-to-string parsing and assumed C:\Users account folder names are fragile. Selection and destination-account validation are limited. | Use structured profile/account properties, actual profile paths, and explicit source-to-destination mapping. |
| Medium | Relative paths and cd transitions depend on the working directory; failed domain-restore restart can remain in the USMT directory. | Resolve paths from the toolkit root and validate resources before starting. |
| Medium | /efs:skip excludes EFS-encrypted files; backup protection and separate Downloads protection are not defined here. | Make skipped data visible and agree encryption/key/access policy before production changes. |
| Medium | No common manifest records source machine, account, capture time, tool/rule versions, and stage results. Folder LastWriteTime is used as a capture-date proxy. | Store migration metadata and per-run logs. |
| Medium | Current document rules include Public/shared folders and system-context extension searches across fixed drives. | Decide intended file scope before narrowing or reproducing collection. A selected employee does not itself guarantee profile-only data. |
| Medium | Custom exclusion files and MigApp.xml produce diagnostics against the supplied XSD; similarly named unused configuration variants differ across architectures. | Resolve rule-validation concerns with engine tests; do not assume every schema diagnostic predicts runtime failure or that unused XML changes the active workflow. |
| Medium | UI work could freeze if migration operations block the UI event loop. | Launch long-running work separately and update the UI from real progress signals. |
| Medium | Drive mappings may not exist after elevation; script and application controls vary by machine. | Prefer configured UNC paths, test share access under the executing identity, and pilot on restricted machines. |
| Low | Production, experimental, archived, and troubleshooting artifacts are mixed on the share. | Separate versioned toolkit releases, migration data, and archives; retain known-good versions. |

## Validation evidence and limits

- Identity screenshots (2026-10-27): inspected the user's supplied ADUC Account and General tabs and checked Microsoft's UI-to-attribute mapping. They show SFSU ID as sAMAccountName and the UPN prefix, plus a populated displayName, for one account. Other accounts were not checked and no employee-directory query was performed by Codex. ADWS unavailability is user-reported historical experience, not a current probe. Personal account values were omitted from this record.
- Live LDAP proof (2026-10-27): at the user's explicit request, queried only their exact sAMAccountName. The first sandboxed domain-discovery attempt could not reach the server; the outside-sandbox retry required correcting request construction before the final lookup succeeded. Built-in .NET LdapConnection to ad.sfsu.edu:389, Windows Negotiate authentication, signing/sealing, RootDSE partition discovery, a two-result limit, and bounded connection/search timeouts returned one exact account with displayName, sAMAccountName, userPrincipalName, and objectSid. Display name/account/UPN matched the supplied screenshots. No ADWS, Exchange/Graph/RSAT module, directory write, or migration was used. This validates one account on this host/network/authentication context only; the returned personal values and SID were not saved in the runbook or source files.
- Reporting foundation (2026-10-26): 50 synthetic assertions passed on Windows PowerShell 5.1, covering result propagation, unfinished/skipped-step protection, escaping, raw-log bytes, interrupted/truncated-journal recovery, snapshot collisions/failure reporting, preservation of existing backup data, all five sample outcomes, and CMD launch from another working directory through a path containing spaces, ampersands, and parentheses. Offline headless Edge checks passed for sorting, search, filters/reset, fixed step summaries, printing/restoring filtered views, relative raw-log links, no remote resources, narrow-screen layout, and JavaScript-disabled readability. Desktop and narrow-screen report renders were visually inspected. These are reporting tests with synthetic data; no engine, share, physical external drive, elevated mapping, or end-to-end migration was tested. The Windows Forms preview was parsed but not interactively exercised.
- Initial mock-up: PowerShell parser validation passed. Headless construction and Backup/Restore/review state checks passed. These checks did not manually exercise the folder dialog.
- User test: the initial launcher was blocked; the modified process-scoped Bypass launcher worked and the user liked the interface. No detailed OS, policy, or network-access results were supplied.
- Branding update: PowerShell syntax, logo loading, and header/title color checks passed. The header was rendered offscreen and visually inspected. An attempted full hidden-form render was blank and is not visual QA of the complete wizard.
- No real ScanState, LoadState, Downloads-copy, store-verification, account-creation, or local-admin operation has been run by Codex. No end-to-end migration result has been established.
- Progress bars and animation remain discussion only. USMT progress-log support was identified as a possible input to a future progress display; usable percentage reporting has not been tested against the deployed version.
- Workflow setup: both installed skills match their prepared sources; frontmatter, names, UI metadata structure/lengths, scaffold removal, and relative project links were checked. All local Markdown links in this runbook resolved. The bundled quick_validate.py could not run because its Python environment lacks PyYAML; direct checks were used instead. Automatic discovery and skill-driven behavior in a fresh chat have not yet been exercised.
- Local cleanup: all 13 moved files matched their pre-move SHA-256 hashes and no longer existed at their old root locations. No script contents were edited or executed as part of this move. Git metadata did not yet exist at the initial cleanup; archive ignore behavior was subsequently checked after Git initialization as recorded below.
- Expanded snapshot review: all 23 XML files were well-formed, all 10 PS1 files parsed, and all 10 deployed standard files matched the earlier copies. Twelve primary EXEs and sampled core DLLs report product version 10.0.26100.1; PE machine fields match the folder architectures. Three ScanState signatures checked Valid. MigXML.xsd diagnostics and runtime limits are documented in the detailed review. No binary or migration script was executed.
- The two supplied historical logs show an incomplete ScanState generation command (code 11) and a successful UsmtUtils extraction (code 0), not a normal end-to-end migration. No employee identifiers or raw personal paths were copied into the tracked project records.
- Git setup: repository initialized on main, origin URL checked, local author identity confirmed, and `git check-ignore -v` verified that representative legacy scripts, binaries, and logs in the archive are excluded. Initial commit review covers documentation/skill changes only; no migration-runtime tests are applicable to this baseline. Remote read access and the subsequent user-authorized initial push both succeeded, confirming write access.

## Open questions

- Cloud UPN-prefix mapping is user-reported and on-premises sAMAccountName/UPN/displayName mapping is evidenced for one account. Does that mapping hold for representative employee accounts, what exceptions exist, and which LDAP endpoints/authentication and optional Graph access are permitted? Should capture proceed with an unresolved name, and what confirmation is required for a technician-supplied label? Offline restore listings should use saved backup identity metadata; implementation is pending.
- Which Windows versions, CPU architectures, PowerShell restrictions, and application-control policies must the production toolkit support?
- Supplied main tool versions are now known (10.0.26100.1); why is this version marked as known-good, and which production scenarios have actually been validated?
- Are the Office 16 parent exclusion, browser nesting, old browser-detection paths, Defender/TMP exclusions, and broad shared/fixed-drive document collection deliberate? Which should the replacement retain?
- What data must be included or excluded: Downloads, cloud-synced folders, encrypted files, browser/application settings, and files outside standard profile folders?
- Which restore targets are required: same domain account, renamed domain account, existing local account, or a newly created local account?
- Should local admin membership remain available, and how should account enablement and BitLocker follow-up be handled?
- What backup retention, encryption, key handling, access permissions, and completion criteria should apply?
- Who owns releases? Local main now tracks origin/main and the first publication succeeded. Continue checking remote history and obtaining the user's publication decision during future closeouts.

## Chat workflow

- Start a project chat with `$start-chat`. Read the runbook, inspect relevant current files, distinguish historical claims from fresh evidence, and give a short grounded handoff. Loading context alone does not start implementation.
- Keep substantive changes and confirmed decisions current as work progresses. Before leaving a chat, invoke `$chat-closeout` to reconcile the latest state, milestones, evidence, and next actions and add a concise dated session entry.
- Both skills are installed project-scoped under `.agents/skills/`: [start-chat](.agents/skills/start-chat/SKILL.md) and [chat-closeout](.agents/skills/chat-closeout/SKILL.md). If the picker has not refreshed, ask Codex to read the corresponding SKILL.md directly. Official guidance says skill changes are detected automatically; restart Codex if they do not appear.
- Closeout first updates project records, reviews the intended changed files, and records available validation. Then ask whether to commit and push project changes to the supplied GitHub repository. If Git is not configured, explain the setup needed in that same question. If there is nothing new to publish, report that instead of asking to push an empty change. A clear answer can authorize the agreed commit/push work; no response is not approval.
- Closeout alone does not close/archive the chat, commit/push changes, deploy to the network share, or execute outstanding implementation tasks. Record the result of an approved push or a decision to defer it without implying later local notes are already published.
- Use America/Los_Angeles dates; distinguish user reports from direct checks; do not store secrets or employee data. Do not duplicate a closeout entry when nothing material changed.

## Session history

### 2026-10-27 - Closeout and publication

- The user explicitly authorized commit and push with the closeout request. Reviewed the reporting source/launcher/logo, tests, usage notes, and reconciled runbook; confirmed main tracks the designated origin and its advertised head matches the local baseline f3df3ee.
- Kept runtime Backups/Logs/test artifacts and the reference archive excluded; added an ignore rule for the user-supplied ADK payload so vendor binaries/configuration are not staged accidentally. The reporting preview remains usable from a clone without that payload, and the included logo remains with the source.
- Reconciled the implemented reporting foundation, one-account direct LDAP proof, and their validation limits. Next proposed development is a reusable LDAP identity resolver with metadata/offline handling; no migration engine or identity provider was implemented during closeout, and no directory lookup was repeated.
- Publication is authorized and prepared; actual commit/push result will be recorded after verification. No production deployment, migration, account change, or chat archival is part of this closeout.

### 2026-10-27 - Cloud identity mapping clarification

- The user identified the Office365Users convention: the first nine characters of userPrincipalName contain the SFSU ID. Recorded this as user-reported evidence, distinct from runtime validation or confirmation of AD attributes.
- Explained that Office365Users accesses Entra profiles via Graph and proposed a targeted, read-only comparison of a known account's AD fields to establish the local-domain mapping. No directory query, module installation, authentication, or resolver implementation was performed.
- The user then supplied an ADUC Account-tab screenshot. Confirmed the account's sAMAccountName is the SFSU ID and its on-premises UPN uses that ID with the sfsu.edu suffix. Display Name was not shown. Recorded only the mapping and evidence limits, without the personal account number; no directory-wide validation was performed.
- A subsequent General-tab screenshot confirms displayName is populated for the same account. The user also reported historical inability to access ADWS and reliance on LDAP. Recorded direct LDAP as the on-premises requirement and superseded the Get-ADUser suggestion. No directory connection was attempted and no personal screenshot values were copied into the runbook.
- The user then explicitly requested a lookup of their own account. After an unsuccessful sandboxed discovery and correction of an outside-sandbox request-construction issue, the read-only direct LDAP query succeeded with one exact match and the expected displayName/account/UPN plus SID. Recorded connectivity/authentication evidence and its one-host/one-account limits without saving personal results. No reusable resolver implementation, module install, directory write, deployment, or migration occurred.

### 2026-10-26 - Portable package requirements

- The user specified a minimal launcher/App/Backups layout, independence from mapped drive letters, external-drive support, and preservation of existing backups when initializing the backup folder.
- Initially recommended a visible root Logs folder plus finalized per-backup log copies and human-readable HTML. The user subsequently approved the recommendations and requested implementation; that approval supersedes their earlier proposal-only status.
- Implemented `sfsu-usmt.cmd`, a Windows PowerShell reporting-preview window/headless samples, reusable logging module, embedded HTML report template, usage notes, and synthetic validation suites. Reports distinguish completed, warning, failed, cancelled, and incomplete results; use clear step/checkpoint summaries and bang-marked errors; retain raw/structured evidence and support log snapshots beside backups.
- Runtime Backups/Logs and local test artifacts are ignored by Git. No backup store was created, no USMT executable or legacy script ran, no deployment occurred, and no commit or push was performed. Preview samples and validation outputs are local ignored artifacts.
- The user subsequently required display name plus SFSU ID for UI/backup naming and clarified that identity handling must work across connectivity/domain states. Compared AD/.NET, RSAT/Get-ADUser, Graph, and Exchange lookup options against Microsoft documentation; proposed saved identity metadata and explicit unresolved/manual states. Provider selection and runtime implementation remain pending; no employee-directory queries or module installs were performed.
- Before implementing the reporting foundation, inventoried the newly supplied App folder with its USMT payload and logo. The reporting source was added afterward; no binaries were executed or version-validated, and no toolkit deployment or migration was performed.

### 2026-10-23 - Initial review and UI prototype

- Reviewed all original scripts and discussed reliability issues and executable versus share-based toolkit packaging.
- Built the non-operational PowerShell/Windows Forms wizard and functional directory picker.
- Added process-scoped Bypass after the user's launch was blocked; the user confirmed it worked.
- Discussed progress indicators and branding, then implemented the requested purple/gold header and supplied white logo. The user accepted the branded mock-up.
- Created this runbook and AGENTS.md, and installed start-chat/chat-closeout under `.agents/skills/` after sandbox approval. Checked the skill sources, installed contents, invocation metadata, and local links; the bundled validator was unavailable because PyYAML is missing. Fresh-chat discovery remains untested.
- The new skills appeared in the next supplied skill catalog, confirming discovery in this ongoing chat. A separate fresh-chat invocation has not yet been tested.
- The user supplied https://github.com/sfsujoe/SFSU-USMT.git and added a requirement to ask about committing/pushing project changes at closeout. Updated the runbook, project instructions, and installed closeout skill. Checked its frontmatter and reviewed the publishing/approval sequence. Confirmed that the local folder still has no Git metadata; no Git initialization, commit, remote change, or push was performed.
- At the user's request, moved the 10 original files, two mock-up files, and the supplied logo to `archive/legacy-and-mockup/`. Verified identical SHA-256 hashes after the move. Added a root `.gitignore` entry for that folder and updated the runbook/current project guidance. The archive is local-only; no production code was changed, no migration ran, and no Git operation or share deployment occurred.
- Next discussion after the initial prototype: agree technician workflows and inspect the then-missing USMT/XML dependencies. The subsequent snapshot review below resolves the source-inventory gap, but runtime coverage remains untested.

### 2026-10-23 - Expanded deployed-toolkit review

- The user supplied Scripts, Scripts-Fast, x86/x64/ARM64 USMT folders, a standalone LoadState-71 workaround, and two historical logs under the ignored archive.
- Inventoried 580 files; inspected versions and PE architectures; compared standard/alternate scripts and XML; checked XML well-formedness and schema diagnostics; parsed PS1 files; read historical logs without running migration commands.
- Recorded the actual entry-point differences, Office/browser configuration issues, incomplete architecture routing/dependencies, broad document selection, inactive/commented configuration, and Default-profile workaround behavior in [CURRENT-WORKFLOW-REVIEW.md](docs/CURRENT-WORKFLOW-REVIEW.md).
- Updated this runbook to replace the stale missing-dependency assumption with the inspected facts. No production source/configuration was edited, no migration was run, and no Git or share operation was performed.
- Next action: agree intentional data/application coverage and use designated test profiles to validate one consistent migration policy before UI integration.

### 2026-10-23 - Initial Git baseline

- The user requested Git setup and the first local commit, and supplied the commit author identity.
- Read origin refs successfully after the initial sandbox network block; origin advertised no HEAD or branches. Initialized local main, configured the designated origin, and set the supplied identity only in this repository.
- Added a root README describing the project records, chat skills, and local-only archive. Updated the runbook and project instructions to reflect Git setup.
- The initial baseline contains nine documentation/skill files. Representative archive paths were confirmed ignored; source tools, migration stores, logs, and the UI prototype are outside the commit scope.
- No GitHub push or deployment was requested or performed. The commit identifier is available from Git history after this baseline is committed.

### 2026-10-23 - First GitHub push

- The user explicitly requested publication of the initial commit. Rechecked the clean local main branch, origin URL, and remote refs before publishing.
- `git push --set-upstream origin main` succeeded for initial commit e50aa54 and configured main to track origin/main. GitHub write access is confirmed.
- Updated this runbook to record the authorization and successful first publication. The reference archive is still excluded, and no migration or share deployment occurred.

## Reference links

These supported the initial review; recheck documentation when implementation depends on current behavior.

- [Microsoft: USMT best practices](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-best-practices)
- [Microsoft: ScanState syntax](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-scanstate-syntax)
- [Microsoft: LoadState syntax](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-loadstate-syntax)
- [Microsoft: USMT return codes](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/usmt-return-codes)
- [Microsoft: compressed-store verification](https://learn.microsoft.com/en-us/windows/deployment/usmt/verify-the-condition-of-a-compressed-migration-store)
- [Microsoft: PowerShell execution policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)
- [Microsoft: mapped drives and elevation](https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/mapped-drives-not-available-from-elevated-command)
- [OpenAI: build and discover skills](https://learn.chatgpt.com/docs/build-skills)
