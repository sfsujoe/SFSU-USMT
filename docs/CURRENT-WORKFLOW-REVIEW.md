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

Update, 2026-11-04: the user has selected broad outside-profile document coverage with Defender/cloud-root/EXE/MSI exclusions. Office policy is still under review; see the coverage/exclusion follow-up at the end of this document.

1. Define required coverage: selected employee only versus shared and other-drive documents; explicit Downloads, EFS, and cloud-synced-folder expectations.
2. Decide which application settings matter, especially Office, Chrome, Firefox, and Edge. Establish the actual installed versions and layouts used for tests.
3. Select one consistent capture/restore policy and clearly separate optional choices from diagnostic workarounds. Preserve intentional exclusions after their purpose is confirmed.
4. Establish a small representative test profile and expected file/settings checklist, including a failure case and an existing destination profile. Gather normal operation logs and verification results.
5. Then implement a shared migration engine and guided UI with per-stage results, store verification, explicit account mapping, overwrite protection, and architecture-aware dependency checks.

## Follow-up: supplied normal migration logs, inspected 2026-11-04

The user supplied two text logs and a populated MigLog.xml in the ignored archive/legacy-and-mockup/log examples folder. This resolves the original review's lack of a normal scan/load pair. The earlier empty MigLog.xml observation applies to the original file, not this new sample. Codex inspected the supplied evidence without running migration tools or reading a live share. Personal account, machine and employee-file identifiers are omitted here.

- ScanState ran November 2, 09:53:36-10:07:02 as written in the log. It used the standard capture XML set, selected a profile SID, and specified /o and /efs:skip. It ended with Success and no migration errors recorded, alongside warning entries including duplicate manifests, invalid-context registry locations and a profile-hive unload problem. Log timestamps do not supply a timezone; the banner does not identify a full executable patch version.
- LoadState ran November 4, 08:10:03-08:22:44 as written, using the standard domain restore XML set, SID-to-domain-account mapping and /c. It ended with Success but explicitly reports 144 migration errors that would have been fatal without /c. The actual process exit status was not supplied; do not infer zero from the Success text or treat the trailing gle value as a process exit code.
- MigLog.xml confirms 112 failed File Create/Replace operations and 32 failed Registry Create/Replace operations, all under the system Security-Malware-Windows-Defender component. File failures affect Defender Definition Updates and Scans; registry failures affect Defender keys. The text summary groups these as access denied (Windows error 5). The capture's custom exclusion for Defender Platform does not cover those other locations, and a document-file exclusion alone does not control all built-in Windows-component migration.
- Other text diagnostics fall outside that 144-operation summary: Office missing-parent errors, a fatal error reported by the Offline Files cache import plugin, keyboard/input errors and failure to launch sleep 3. Some Office units nevertheless have successful XML operations under UNKNOWN parents. This means the archived Config.xml structure alone cannot establish that all Office settings were excluded in this supplied run; exact deployed rules and application fidelity need reconciliation. Component-level failure does not prove the whole process aborted or that ordinary documents were lost.
- Actual outside-profile apply evidence includes successful creation of C:\DumpStack.log, root INI files, Public-folder Adobe data, Dell/NVIDIA ProgramData files and a recovery configuration file. XML also records Windows-component file operations. Root/Public discovery is attributed to MigDocSystem; Dell/NVIDIA text-file operations are attributed to MigUser's system User Data component. Some destinations receive a (1) suffix. These are operation records, not a full-drive image or an independently verified unique-file inventory.
- Native USMT also reports 842 successful File Create/Replace operations under the selected profile's Downloads directory. This demonstrates native Downloads handling in this case, separately from the launcher's XCOPY stage. No XCOPY transcript or exit status was supplied.
- Subsequent EFS-focused inspection reports selected-user CAPI2-certs, Crypto-keys and dpapi-keys units with 83, 11 and 13 successful operations respectively and no Success=false operations. Nine Crypto-keys operations target software private-key storage paths; these are operation counts, not nine distinct EFS keys. This supports native user certificate/private-key/protection-data migration in the supplied run, even though /efs:skip omits encrypted files. No key contents, file-to-certificate association or successful decryption was inspected. The native /efs:copyraw recommendation, retaining those components and requiring a designated encrypted-file restore test, was subsequently approved under D48; implementation and testing remain pending.

The samples support narrowing unnecessary collection through an agreed native XML/Config policy and retaining both structured and text diagnostics in future reports. They do not authorize a policy change. Source/destination content comparison, store-integrity verification, intended application settings, EFS/cloud-file completeness and behavior of the new application's separate payload remain unverified. The archived raw logs remain local and Git-ignored.

## Coverage requirements and exclusion review, 2026-11-04

User-confirmed requirements (D47): retain useful outside-profile/shared/legacy document locations; exclude all Windows Defender data, cloud-storage directories (Box Drive, Box Sync, Dropbox, OneDrive and similar providers), and .exe/.msi files. The user reports exclusive Microsoft 365 Apps for enterprise deployment. Settings/content restored through sign-in need not be captured. A blanket Office exclusion or removal of local user-created Office artifacts has not been approved. These are requirements for future integration, not implemented migration rules.

Subsequent EFS decision (D48, 2026-11-04): the user approves native /efs:copyraw with user certificate/private-key/DPAPI migration retained, within the agreed scope/exclusions. A controlled restore must establish that the intended user can decrypt an EFS file. This supersedes the earlier unresolved EFS recommendation; the archived commands remain historical reference and the new engine is not implemented yet.

### Existing legacy exclusions and their limits

| Exclusion | Actual scope/status |
| --- | --- |
| Other user profiles | Both capture commands use /ue:*\\* and /ui:selected-SID. System-context/shared discovery remains in scope; these are not profile-path-only collection switches. |
| EFS-encrypted files | Both archived capture commands specify /efs:skip. This excludes Windows EFS files, not BitLocker-protected drives generally. D48 rejects carrying this skip forward: the new engine must use /efs:copyraw, preserve user key/certificate/DPAPI components and validate decryption after restoration. Not implemented yet. |
| .exe and .msi | All three dload-exclude.txt copies contain .exe and .msi followed by backslashes. Only the separate Downloads XCOPY consumes them. They do not reliably match ordinary installer filenames or constrain USMT elsewhere. D47 requires proper future global file exclusions. |
| *.tmp on fixed drives | Requested by ExcludeSystemFolders.xml in standard capture and ExcludeSystemFolders2.xml in experimental restore. Fast capture omits this XML. This is an extension rule, not an exclusion of every Temp/cache directory. Prior custom XML schema concerns still apply. |
| Defender Platform | Standard capture requests exclusion of C:/ProgramData/Microsoft/Windows Defender/Platform. It does not cover all Defender files, registry data or built-in migration components; the sample restore establishes the gap. Fast capture omits it. |
| Office settings | Active Config.xml marks the Office 16 parent, OneNote 16 and Outlook 2016 no; other Office children say yes and browsers are incorrectly nested. Standard capture/domain restore use it; Fast capture and local restore do not. Sample XML nevertheless reports Office operations under UNKNOWN parents. Intent and observed behavior remain distinct. |
| Dropbox installation folder | ExcludeSystemFolders2.xml targets C:/Program Files (x86)/Dropbox and TMP files, used by experimental load - Copy.bat. It does not target user Dropbox content and is not in the normal capture path. |
| Windows-component exclusions | The WindowsComponents section is commented out, including apparent Defender, printing, credential/security and other no entries. They are inactive. |
| Alternative configuration files | Config_AppsOnly.xml, Config_SettingsOnly.xml, Config_AppsAndSettings.xml and defender.xml are not referenced by normal scripts. Their exclusions have no effect on those commands. |
| Built-in document discovery | MigUser's drive-wide extension-search component avoids profiles and Windows/Program Files paths in that search; other components handle profiles/shared/Windows settings separately. MigDocs generates its own include/exclude rules. These are not universal bans: the sample contains Windows/ProgramData operations from other components. |
| Application-specific exceptions | Bundled MigApp.xml contains 77 exclude/unconditionalExclude blocks across apps/versions. Examples: Chrome Cache; Firefox cache/crash reports/pluginreg.dat; Outlook 2010/2013/2016 OST files; Office 16 network-status/open-find registry caches; older app-specific machine/path values. These depend on component detection and do not establish global exclusions or modern browser coverage. |
| Separate Downloads hidden/system behavior | XCOPY lacks /H, so that stage omits hidden/system files by default. Native USMT coverage is independent. No reliable broad cloud-root exclusion was found in the normal policy. |

### Recommended Office policy, awaiting user evaluation

Superseded by D52 (2026-11-04): the user chooses default USMT Office migration behavior except an explicit Outlook OST exclusion. The detailed local/cloud allowlist and add-in/security exceptions below are historical recommendations, not the current selected design. Do not require a bespoke Office questionnaire or claim that USMT defaults guarantee every modern Office feature.

Update (D51, 2026-11-04): the user confirms the governing rule: capture only Office items not recovered by signing into Office. Local-only preferences/customizations can qualify along with files. The recommendations below describe how to realize that rule; the add-in/security exceptions and exact restore behavior remain for evaluation. Classic/new Outlook and actual roaming/signature policies must be mapped on representative installations rather than inferred from the Microsoft 365 product name alone.

- Retain local documents and archives regardless of the Office version that created them, including macro-enabled documents and local PST archives, subject to cloud-root and EXE/MSI exclusions. Application-settings exclusions must not become document-extension exclusions. Microsoft distinguishes [local PST data from rebuildable OST mailbox copies](https://support.microsoft.com/en-us/outlook/create-an-outlook-data-file-pst-to-save-your-information).
- Avoid bulk Office registry/profile migration, activation/license tokens, authentication caches, Office/Outlook caches, OST files and security/trust-policy restoration. Reinstall/activate the managed suite and reconnect the account. Preserve migration support for other applications; do not remove MigApp.xml merely to suppress Office.
- Preserve selected local user-created artifacts through small native migration rules: Word templates/Normal.dotm, Excel PERSONAL.XLSB and templates, custom dictionaries, local signatures and local notebooks/backups holding unique work. Exact allowlist and restore behavior require approval and tests; do not copy entire Office AppData trees or automatically restore every add-in/security preference. See Microsoft's [Normal.dotm documentation](https://support.microsoft.com/en-us/word/change-the-normal-template-normal-dotm) and [personal macro workbook guidance](https://support.microsoft.com/en-us/excel/create-and-save-all-your-macros-in-a-single-workbook).
- Office sign-in does not guarantee every customization returns. Microsoft's [Outlook roaming documentation](https://support.microsoft.com/en-us/outlook/outlook-roaming-options) lists non-roaming Language, Ribbon, Quick Access Toolbar, Add-ins and Trust Center categories. Prefer a reviewable local-artifact policy to indiscriminate legacy registry replay. Campus policies, Outlook flavor and roaming success are unverified. Office version 16.0 identifiers alone do not prove obsolete Office 2016: Microsoft 365 Apps also uses 16.0, as documented in [upgrade guidance](https://learn.microsoft.com/en-us/microsoft-365-apps/end-of-support/plan-upgrade-older-versions-office).
- Establish OneNote sync before relying on the service; Microsoft explicitly calls for preserving [unsynced recent notes](https://support.microsoft.com/en-us/onenote/onenote-help-and-learning/fix-issues-when-you-can-t-sync-onenote). Recovery handling for failed sync is a recommendation, not approval to capture excluded cloud roots.

### Recommended native exclusions and cloud-root handling

Use Config.xml component exclusions for Defender, reinforced by file/registry exclusions where needed. Use small versioned XML rules with unconditionalExclude for identified cloud roots/caches and global .exe/.msi exclusions so other document/application includes cannot reintroduce them. Microsoft documents [cross-component precedence](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-conflicts-and-precedence). Exact component names and coverage must be tested against the current App payload.

Exclude hydrated/offline-available cloud files as well as placeholders, all identified personal/business accounts and custom locations outside user profiles. Avoid matching every folder named Box or treating a generic reparse flag as proof of cloud ownership. A bounded discovery layer can resolve provider configuration and known-folder paths and give USMT exact paths to exclude. Unknown roots need visible review; no universal provider detector is implemented or validated. Box documents [custom Drive locations](https://support.box.com/hc/en-us/articles/360043697454-Configuring-the-Default-Box-Drive-Folder-Location-Windows-Only) and [caches separate from the mounted folder](https://support.box.com/hc/en-us/articles/360043695894-Technical-Information-for-Box-Drive-Administrators); Dropbox supports [relocated sync roots](https://help.dropbox.com/installs/move-dropbox-folder).

An excluded root can contain redirected Desktop/Documents/Pictures or synced SharePoint libraries, so a familiar folder label cannot override the cloud exclusion. See [OneDrive Known Folder Move](https://learn.microsoft.com/en-us/sharepoint/redirect-known-folders). List excluded roots and reasons. Under D49 below, completed sync is assumed; the earlier recommendation for mandatory sync-status verification/gating was not selected. This discussion changes project records only, not native policy, runtime sources or endpoint state.

### Custom-location detection and completed-sync assumption (D49)

On 2026-11-04 the user explicitly instructed us to assume cloud data is fully synchronized. This is a design/operating assumption, not a field test result. Do not add automatic cloud-status checks or readiness gating merely from earlier assistant recommendations; OneNote's documented unsynced-data concern above remains background information, not a selected verification requirement.

Discovery sources for the design approved under D50, not an implemented detector:

| Provider/source | Detectable information and limits |
| --- | --- |
| Windows registered providers, including OneDrive | [SyncRootManager registration](https://learn.microsoft.com/en-us/windows/win32/shell/integrate-cloud-storage) associates disk paths with provider, Windows SID and account ID; the [GetCurrentSyncRoots API](https://learn.microsoft.com/en-us/uwp/api/windows.storage.provider.storageprovidersyncrootmanager.getcurrentsyncroots?view=winrt-26100) enumerates registered roots. Registration coverage, call context and all-user/unloaded-profile behavior must be tested; one account root must not stand for every SharePoint library or account. |
| Dropbox | Vendor-documented [info.json](https://help.dropbox.com/installs/locate-dropbox-folder) under the employee's roaming or local Dropbox AppData contains personal/business path values, including relocated roots. Read the employee's profile, not the technician's AppData environment. |
| Box Drive | The documented machine CustomBoxLocation specifies the parent directory; Box appends Box. Cross-check effective registration/location because Box documents fallback to the default when the custom location conflicts. The visible root and internal cache are separate exclusion targets; do not infer that moving one moves the other across all client generations. |
| Box Sync | The vendor documents customizable folder location/name, but the reviewed primary documentation did not establish a stable programmatic current-location field. A version-specific configuration/Explorer-registration resolver needs validation; otherwise propose technician selection of the actual root. |

Resolve relevant employee-profile and machine-wide settings and account for other registered cloud roots that broad system-context discovery could collect. Resolve redirected known folders, distinguish mounted data from internal caches, normalize/deduplicate exact paths, and record source/provider evidence in the runtime report without tokens/config dumps. Native USMT unconditional exclusions can then prevent re-inclusion through other components. Do not exclude an entire parent drive merely because a custom parent value points there. Stale/missing configuration, removed clients, unsupported cache relocation and aliases require explicit uncertainty; arbitrary orphaned copies cannot be reliably identified by folder names alone. These are recommendations pending implementation and representative version/profile tests.

Approval clarification (D50, 2026-11-04): the user accepts the preceding cloud-location recommendations, including manual unresolved-location review and exact-path native enforcement. Implementation and representative tests remain pending; completed cloud sync remains an assumption rather than a result obtained by the application.

### Remaining policy decisions after D50-D51

Historical decision list: D52-D58 below resolve or defer most of these questions. Use the simplified current choices rather than re-opening these earlier recommendations automatically.

- Office: classic/new Outlook support and environment-specific roaming/signature behavior; whether locally installed add-ins are recreated through managed installation and whether managed security/trust settings are intentionally excluded even though sign-in may not restore them. Recommend preserving local user customization, templates/macros/dictionaries, local signatures/PST/notebooks where eligible, with a tested allowlist; avoid bulk registry replay and blindly restoring add-in activation or security policy.
- Other scope: non-Office application/browser settings, Windows user versus machine/service state, the legacy TMP exclusion and any additional cache/temporary exclusions. Broad useful outside-profile documents, cloud/Defender/EXE/MSI exclusions and native EFS handling are already decided; printers remain deferred.
- Restore: supported source-to-destination identities, missing local-account creation/enablement and any admin-membership step, plus existing/newer target-file and shared-data conflict behavior. Recommend defaulting to the verified same identity, requiring deliberate remapping, and exposing destination conflicts.
- Store protection: compression/encryption and key storage/recovery responsibility across technician sessions and removable/share deployment. Recommend encrypted compressed stores with a defined recoverable key process; EFS private keys and migration-store encryption keys are separate concerns.
- Outcomes: stop/continue policy for unapproved errors, treatment of skipped items and criteria for re-imaging readiness. Recommend native store verification for each accepted capture, visible reviewed warnings and controlled restore/EFS validation before release. No blanket /c acceptance policy is agreed.
- Initial support and rollout: required Windows/CPU targets and designated source/destination test systems. Inventory/version/rule checks and process lifecycle/log/metadata integration are engineering tasks; they should not be converted into unnecessary user decisions. Backup retention/release ownership remain deployment questions; no automatic deletion is authorized.

### Simplified current choices (D52-D58, 2026-11-04)

Current correction (D59-D60, 2026-11-04): backup minimum is Windows 10, not Windows 7. Restore only to Windows 11 on applicable x64/ARM64. Domain profiles restore only to their original domain identity, local accounts are always recreated, and a collision must stop the entire restore before migration/account changes. Earlier unresolved account/Windows 7 discussion below is superseded.

- Office: use default native Office migration rules except explicitly exclude OST. Retire the bespoke sign-in-recovery item classification. Preserve the approved general document/cloud/installer rules and EFS key support.
- Restore: assume fresh employee-data destinations and one restore run; a general merge/conflict UI is not needed. Account mapping remains to be explained/selected. Same AD account on another computer differs from a different AD account or a new computer-local account; a local username alone does not preserve the old machine's SID. User selection/sign-in to LDAP is separate from the employee identity receiving the restore. [Native account mapping and local-account options](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-loadstate-syntax) can support deliberate exceptions; no account creation, enablement, mapping or admin-group change is yet approved.
- Backup protection: no store encryption and no store-key prompts. This is separate from EFS file encryption and its migrated user keys. Compression can remain native/default; it does not imply encryption.
- Execution: hands-off after initial choices, without a technician responding to every skipped file. Design native retries/continue/error classification and automatic verification/reporting accordingly. Fatal failure/corruption must still produce a clear failed/incomplete result; the exact /c/ErrorControl policy is engineering work, not a confirmed ignore-all-errors policy.
- Exclusions and browsers: no browser caches, Windows temporary data or *.tmp. Preserve browsing history/bookmarks from Edge, Chrome and Firefox. Static current-payload MigApp inspection still finds Firefox 3 and early Chrome detection, with no explicit modern Edge component. Use small native XML additions/exclusions where necessary and validate current browser profiles/database consistency; these outcomes are not already implemented by default.
- Platform requirement: Windows 7 and later for capture; Windows 11 only for restore; x64 and ARM64 where available. [USMT requirements](https://learn.microsoft.com/en-us/windows/deployment/usmt/usmt-requirements) list Windows 7/8 capture and Windows 10/11 capture/restore, but this does not validate the current app/payload against every OS/architecture. The [PowerShell runtime differs on older Windows](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_5.1); current PowerShell/.NET/WinForms/native APIs and the exact USMT build need prerequisite/version/architecture testing. No x86 requirement or Windows 7 ARM64 system is implied. Use the [ADK guidance](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) when establishing tool compatibility; no dependency replacement is authorized merely by the requirement.
- Retention: deferred; no automatic backup deletion. Release ownership means who approves a tested toolkit version and arranges its copy to the technician share. It is deployment coordination, not a prerequisite for continuing local design or a request for a new approval workflow.

All are design requirements/assumptions for the new engine, not a report of implementation, migration coverage or source publication.

### Restore identity and preflight rules (D59-D60)

- Domain: retain the original domain account identity; no mapping to a different domain account. A domain account existing in AD is expected. An employee profile already registered or present on the destination is an unexpected collision under the proposed operational interpretation; do not mistake AD existence for destination-profile presence.
- Local: recreate the original local account on the new computer. Any matching destination local account is a collision, even if unused or without a profile. No local-to-domain conversion or reuse of an existing local account is in scope. Local password/enablement/admin-group choices are not specified by recreation alone.
- Before starting any restore: validate all selected account/profile targets for collisions, including registered profiles and conflicting destination profile folders. On a collision, stop the whole operation, identify the conflicting target to the technician and retain the report; do not start LoadState, create accounts, overwrite data, invent a suffix or silently choose another identity. This is a planning requirement, not implemented behavior.
- Platform: Windows 10 and later capture; Windows 11-only restore; x64/ARM64 where supported. D60 supersedes the Windows 7 minimum and removes the earlier Windows 7 prerequisite/adaptation work. Existing Win10/11/ARM64 tool/runtime/browser/EFS validation is still pending.
