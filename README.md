# SFSU User State Migration Tool

Project planning and development for a guided employee backup and restore toolkit using Windows User State Migration Tool (USMT).

The portable application discovers registered domain and local profile directories and prepares selected backup folders with identity metadata and real logs. Domain IDs come from a configured AD attribute through exact-SID lookup, or explicit manual confirmation. IDs, Windows account names, UPNs and profile paths are separate. Local accounts retain their username/SID and require an assigned display name. Backup and restore engine integration is still pending; no USMT executable runs and no employee files are copied.

Open `sfsu-usmt.cmd`. The startup dialog accepts an **SFSU account login or full UPN and password**, or **Continue without AD** for manual identity confirmation. Letters, longer IDs and p-prefixed credentials are supported. Bare logins use the configured university suffix (currently `@sfsu.edu`). Kerberos-only signed/sealed LDAP refuses NTLM fallback and implicit Windows credentials. Credentials expire after ten minutes without directory activity. Every selected profile requires a name. The Backup tab lists profiles with checkboxes, directory/manual identity status, and **Prepare selected folders**. The Restore tab lists backup folders newest first, supports column sorting and checkboxes, and reviews the selected metadata without restoring anything. The SFSU logo appears in the header. App, Backups, and Logs are resolved from the launcher location; existing backups are preserved.

A normal launch with no arguments opens the graphical app/sign-in dialog and hides the PowerShell console; the CMD may appear briefly. The launcher returns after starting the app. Startup failures handled by the entry script display a message with the saved log path, or explain that a log could not be saved. Argument-based commands remain visible and synchronous. For visible GUI-startup troubleshooting, run `sfsu-usmt.cmd -LdapServer ad.sfsu.edu`. Window visibility does not change credentials, Kerberos, privileges, or saved execution policy.

Account renames and unrelated or suffixed profile-folder names are supported through the matching SID. SID/multiple-match conflicts remain blocked. See [Identity configuration](docs/IDENTITY.md) for the shared attribute/suffix policy, manual identity entry and schema-three metadata. Earlier development metadata versions are intentionally unsupported and remain visible as unrecognized. Exclusion counts explain unsupported/system/setup/missing/linked profiles. Runtime path guards reject filesystem links and protect directories during writes. See [Security and maintenance](docs/SECURITY.md) for permissions, bounded reporting, explicit log-retention commands, acceptance checks, and future encryption-key requirements. User-editable scripts are an accepted risk; the application does not provide a security boundary against an administrator or a compromised endpoint.

The main window starts maximized and is titled **SFSU User State Migration Tool**. Its **By Academic Technology at SF State** attribution links to [Academic Technology](https://at.sfsu.edu/). The startup AD dialog stays normal-sized and centered, emphasizes its sign-in instruction, explains that AD resolves SFSU ID to Display Name, and prefixes authentication failure messages with ⛔. Profile discovery excludes the Windows setup account `defaultuser0` by exact account or profile-folder name, ignoring case; its files and account are not modified.

**Theme & Font**, at the bottom right (Alt+T), previews SFSU Classic, Ocean, Forest, Warm, Dark Mode, or Windows system colors and offers 100–200% text sizes. **Use theme** saves the shared preference inside `App/Settings/appearance.json`; all technicians using that toolkit load it on their next launch. No per-computer or per-user preference file is written. Windows high contrast overrides custom colors automatically without changing the saved choice. Cancel/Escape restores the previous appearance. The main screen has no theme-name label. Keyboard access, readable verification text, accessible names/status notifications, wrapping actions, and resizable dialogs support accessibility; full assistive-technology/Windows contrast/DPI acceptance testing remains necessary before claiming compliance.

Printer migration is deferred as a future optional add-on. University printers are assumed to use onsite direct TCP/IP or IPP; personal printers can use uncontrolled installation methods. No printer inventory or restoration is implemented. The proposed scope and unresolved compatibility/user-context questions are recorded in the runbook.

- [Project runbook](PROJECT-RUNBOOK.md): current state, decisions, milestones, validation, and next steps.
- [Current workflow review](docs/CURRENT-WORKFLOW-REVIEW.md): findings from the supplied scripts, binaries, and migration XML.
- [Reporting guide](docs/REPORTING.md): report features, durable events/recovery, backup log snapshots, development API, and validation commands.
- [Application testing guide](docs/APP-TESTING.md): discovery, directory credentials, manual identities, folder naming, metadata, and preparation/restore-review limits.
- [LDAPS diagnostic](docs/LDAPS-DIAGNOSTIC.md): standalone TLS/Kerberos/SID test, optional 389 comparison, and required server-side channel-binding evidence.
- [Project instructions](AGENTS.md): conventions for maintaining this project with Codex.

## Chat workflow

Use `$start-chat` to load project context and `$chat-closeout` to update the runbook. Both project-local skills live in `.agents/skills/`. Closeout includes a question about committing and pushing project changes; publishing requires the user's answer.

## Local reference archive

Legacy scripts, the UI mock-up and logo, and the supplied USMT toolsets are retained locally in `archive/legacy-and-mockup/`. That folder is ignored by Git and is not included in a clone of this repository. Links into it in the project records require the local reference copies.

The archived scripts operate on employee data and are reference material. They are not the new production toolkit.

The supplied logo under `App/Assets/` is included with the application source. User-supplied ADK files under `App/User State Migration Tool/` are Git-ignored and must be obtained separately when migration integration is implemented; this application works without them and never executes them. Runtime `Backups/`, `Logs/`, `App/Settings/`, and `tests/.work/` are also Git-ignored. Keep the launcher and App together; preserve existing Backups, Logs, and App/Settings when updating the application. Developer-only synthetic reports remain available with `sfsu-usmt.cmd -Headless -Scenario Failed`.
