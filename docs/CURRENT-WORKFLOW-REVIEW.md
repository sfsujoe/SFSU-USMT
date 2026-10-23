# Review of the supplied USMT workflow

Reviewed: 2026-10-23 (America/Los_Angeles).

This is a static review of the reference files supplied in `archive/legacy-and-mockup/`. No USMT executable or migration script was run, and no source/configuration file was changed. The archive is intentionally Git-ignored; this report preserves findings, not the source files themselves. Links into that archive work only where those local reference copies exist.

## Overall finding

The supplied workflow is understandable, but its data-selection policy differs between entry points. Several settings appear to do more or less than their names suggest. Establishing the intended coverage should precede connecting a new wizard to the commands.

## Inventory and versions

- 580 files inventoried: 23 XML, 12 EXE, 58 DLL, 410 migration manifests, and supporting scripts/data files. There are two logs, both dated January 2025.
- `Scripts/` contains the same 10 original files already reviewed: every file matches the earlier archived copy by SHA-256.
- `Scripts-Fast/` contains nine corresponding text/script files. Six match the standard versions; `scan.bat`, `load.bat`, and `loadstate.ps1` differ.
- ScanState, LoadState, UsmtUtils, and MigHost all report product version `10.0.26100.1` in each of USMT32, USMT64, and arm64. Inspected migcore/migstore DLLs report that version too.
- PE machine fields identify the supplied USMT32, USMT64, and arm64 binaries as x86, x64, and ARM64 respectively. ScanState signature checks returned Valid for all three, with Microsoft signers. This is not a check of every DLL or a runtime compatibility test.
- The copies of MigApp.xml, MigUser.xml, and MigDocs.xml are byte-identical across all three architectures. That does not establish that they match an unmodified Microsoft distribution.

## Actual paths through the scripts

| Entry point | Capture or restore behavior |
| --- | --- |
| Standard backup | `Scripts/SCANSTATE-LAUNCHER.bat` -> registry-sid.ps1 -> scan.bat. Copies Downloads separately, then runs ScanState with Config.xml, ExcludeSystemFolders.xml, MigUser, MigApp, and MigDocs. Uses /o and /efs:skip; does not pass /c. |
| Standard domain restore | `Scripts/LOADSTATE-LAUNCHER.bat` -> loadstate.ps1 -> load.bat. Uses Config.xml plus MigUser/MigApp/MigDocs, /mu account mapping, and /c. On zero exit code, copies Downloads and optionally invokes the local-admin helper. |
| Standard local restore | Same restore selector -> load-local.bat. Uses MigUser/MigApp and /lac with /c; omits Config.xml and MigDocs. Copies Downloads even after a nonzero LoadState result. |
| Fast backup | Same selection helper, but the fast scan command omits Config.xml and ExcludeSystemFolders.xml and adds /c. It still combines MigDocs/MigUser/MigApp and separately copies Downloads. |
| Fast domain restore | Suppresses the local-account choice and confirmation of an automatically inferred ID. Uses Config.xml and MigUser/MigApp, omitting MigDocs. The local-admin prompt is commented out. Restart behavior falls through to the standard Scripts workflow. |

Sources: [standard capture](../archive/legacy-and-mockup/Scripts/scan.bat), [standard restore](../archive/legacy-and-mockup/Scripts/load.bat), [local restore](../archive/legacy-and-mockup/Scripts/load-local.bat), [fast capture](../archive/legacy-and-mockup/Scripts-Fast/scan.bat), [fast restore](../archive/legacy-and-mockup/Scripts-Fast/load.bat), [fast selector](../archive/legacy-and-mockup/Scripts-Fast/loadstate.ps1).

## Findings that change our understanding

### 1. The active configuration excludes the Office 16 parent, not just Outlook and OneNote

[USMT64/Config.xml](../archive/legacy-and-mockup/USMT64/Config.xml), lines 4-20, sets the Microsoft Office 16 parent component to `migrate="no"`. Excel, Word, PowerPoint, and other children saying `yes` do not override that parent exclusion. Microsoft explicitly documents that excluding a parent also excludes its children.

Firefox and Chrome entries are nested inside Office SmartTags, itself inside that disabled Office branch. This is inconsistent with their independent MigApp component identities and should not be treated as a reliable browser migration configuration. The documented parent rule implies they are suppressed as nested children; confirm behavior with a designated test before promising browser coverage.

These are application settings exclusions. They do not establish that Word documents, PSTs, or other user files are excluded: separate document rules can still collect those files.

Reference: [Microsoft: Config.xml parent/child behavior](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-customize-xml-files).

### 2. Browser rule names do not demonstrate support for today's browser installations

The shared MigApp.xml contains Firefox detection for a `Mozilla Firefox 3.*` registry key, and Chrome detection under `%CSIDL_LOCAL_APPDATA%\Google\Chrome\Application`, including a `1.*` directory check. Its Chrome rule includes User Data files and excludes cache; its Firefox rule includes profile data and excludes certain cache/crash-report files.

These are older installation/detection assumptions. Whether they trigger on the organization's current per-user or machine-wide installations requires testing. No explicit modern Chromium Edge application component was found in this MigApp.xml. This does not prove that no browser-related files/settings can migrate by any other mechanism.

### 3. The supported architecture paths are incomplete or disconnected

| Command | x64 supplied dependencies | x86 supplied dependencies |
| --- | --- | --- |
| Standard capture | All named XML present | Missing Config.xml and ExcludeSystemFolders.xml |
| Standard domain restore | All named XML present | Missing Config.xml |
| Local restore | All named XML present | All named XML present |
| Fast capture | All named XML present | All named XML present |
| Fast domain restore | All named XML present | Missing Config.xml |

ARM64 binaries exist, but the scripts only select USMT32 or USMT64 based on PowerShell process pointer size. None of the supplied entry points selects the arm64 folder. A 32-bit PowerShell process on a 64-bit OS can also choose the wrong architecture path under this logic.

### 4. Fast is a different policy, not merely fewer clicks

Fast capture bypasses the main component exclusions and the Defender/TMP exclusion file. Fast restore then applies the main Config.xml exclusions again, so collecting settings is not evidence they will be restored through that route.

The fast capture restart changes directory to `..\Scripts`. Fast domain restore also changes to `..\Scripts`, and its restart condition/prompt are commented out while the restart body remains active. The result can switch the technician back to the standard workflow, including after a restore failure. On early Downloads-copy failure, capture also reaches restart code from a different working directory than after USMT runs.

Omitting MigDocs from restore should not be described as automatically discarding every file captured through MigDocs. Microsoft's documentation says stored data can still be restored while the omitted XML's rules no longer apply. The mismatch is nevertheless an unsupported assumption about consistent behavior and should be resolved.

Reference: [Microsoft: XML sets at capture and restore](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-customize-xml-files).

### 5. The selected employee does not fully define file scope

MigUser.xml includes employee known folders, shared/Public folders, and a system-context User Data component generating extension patterns across fixed drives. Those patterns include Word/Excel/PowerPoint formats, CSV/TXT, PST, OneNote, Access, and other document types. MigDocs.xml also includes system and user document discovery with its system-drive-only flag set to FALSE.

Consequently, this is not simply a selected-profile-folder copy. Shared and drive-wide data may enter each store, subject to runtime discovery and conflict/exclusion rules. Actual file lists have not been collected in this review. Decide whether that breadth is intentional before narrowing or reproducing it.

Both capture paths combine MigUser and MigDocs; Microsoft advises against this combination. Both also skip EFS-encrypted files. Downloads is copied separately with literal exclusions ending in a backslash that do not filter ordinary EXE/MSI filenames. Fixing that separate copy alone would not define what other USMT rules can collect from the same locations.

Reference: [Microsoft: USMT best practices](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-best-practices).

### 6. Several configuration names are misleading or inactive

- ExcludeSystemFolders.xml targets the Windows Defender Platform path and fixed-drive TMP patterns. It is not a general exclusion of all system folders.
- ExcludeSystemFolders2.xml targets `C:\Program Files (x86)\Dropbox` and TMP patterns. That targets an application installation location, not an employee's usual Dropbox data directory. Only the experimental `load - Copy.bat` references it.
- Both custom exclusion files share the same migration urlid. They are used separately in the supplied commands; combining them later would need distinct identities and validation.
- The WindowsComponents list in Config.xml is inside an XML comment. Its apparent yes/no settings are inactive. An omitted component is not automatically excluded, so the comment is not a reliable way to disable all Windows settings migration.
- Config.xml's ProfileControl examples and ErrorControl content are also comments; no active custom account/group mapping or fine-grained error policy is configured there.
- No supplied launcher/script references Config_AppsOnly.xml, Config_SettingsOnly.xml, Config_AppsAndSettings.xml, or defender.xml. Their presence does not affect these flows.
- The unused Config_SettingsOnly.xml differs materially by architecture: all 22 listed components say yes in x64, while the corresponding x86/ARM64 components say no. This is dormant configuration drift, not a demonstrated current-flow failure.

### 7. The standalone 71 fix is a Default-profile modification

[1-DRIVE-LOADSTATE-71-FIX.bat](../archive/legacy-and-mockup/1-DRIVE-LOADSTATE-71-FIX.bat) changes into `C:\Users\Default\AppData\Local\Microsoft\Windows` and renames UsrClass.dat to UsrClass.bak. It has no precondition checks, failure handling, or rollback, and is not called by the supplied launchers.

Its name is not evidence that this is a general OneDrive solution or the cause of every return-code-71 failure. Keep it as documented troubleshooting history until the exact failure it addressed is understood; do not run it automatically during ordinary restore.

### 8. The available logs are useful, but do not validate the normal workflow

- scanstate.log records an incomplete `/genmigxml` command and return code 11. It also names `migapps.xml`, whereas the supplied file is MigApp.xml. It is not a successful employee capture log.
- usmtutils.log records a successful manual extraction with return code 0. That establishes one extraction operation succeeded; it is not a LoadState result or verification of a current migration store.
- MigLog.xml is an empty log document, not an active migration rule.
- No representative successful/failed normal ScanState and LoadState log pair was supplied. Raw employee/account/path details from the logs are intentionally not repeated here.

## Validation performed and its limits

- Inventory, SHA-256 comparisons, PE architecture fields, version resources, and three ScanState signature checks were read without launching USMT.
- All 23 XML files were well-formed according to the XML parser. All 10 archived PS1 files parsed without PowerShell syntax errors.
- Against the supplied MigXML.xsd, MigUser and MigDocs passed for all three architectures; defender.xml also passed. Each custom ExcludeSystemFolders file produced four schema diagnostics, including an undeclared component id attribute, lowercase data role, uppercase Exclude, and a related identity constraint failure.
- The supplied MigApp.xml also produced three identical schema diagnostics on every architecture, including destinationCleanup placement and two empty objectSet elements. The XSD itself notes that some engine values are accepted more loosely than the schema allows. Therefore schema diagnostics are validation concerns, not proof that a deployed migration has failed. Config.xml uses a different format and was checked for well-formedness/active structure, not against MigXML.xsd. MigLog.xml is a log, so its root is not a migration-rule schema target.
- No migration-store integrity, actual file coverage, account mapping, application-setting fidelity, cloud-file hydration, or performance was tested. No executable runtime support claim is made from versions alone.

## Decisions to settle before implementation

1. Define required coverage: selected employee only versus shared and other-drive documents; explicit Downloads, EFS, and cloud-synced-folder expectations.
2. Decide which application settings matter, especially Office, Chrome, Firefox, and Edge. Establish the actual installed versions and layouts used for tests.
3. Select one consistent capture/restore policy and clearly separate optional choices from diagnostic workarounds. Preserve intentional exclusions after their purpose is confirmed.
4. Establish a small representative test profile and expected file/settings checklist, including a failure case and an existing destination profile. Gather normal operation logs and verification results.
5. Then implement a shared migration engine and guided UI with per-stage results, store verification, explicit account mapping, overwrite protection, and architecture-aware dependency checks.
