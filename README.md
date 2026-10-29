# SFSU USMT

Project planning and development for a guided employee backup and restore toolkit using Windows User State Migration Tool (USMT).

The portable application discovers registered domain and local profile directories and prepares selected backup folders with identity metadata and real logs. Domain SFSU IDs come from profile folder names, with optional exact-SID LDAP name lookup. Local accounts retain their username/SID and require an assigned display name. Backup and restore engine integration is still pending; no USMT executable runs and no employee files are copied.

Open `sfsu-usmt.cmd`. The startup dialog accepts an SFSU ID/password or full SFSU Login for Active Directory authentication, or **Continue without AD** for manual identity confirmation. Every selected profile requires a name. The Backup tab lists profiles with checkboxes, directory/manual identity status, and **Prepare selected folders**. The Restore tab lists backup folders newest first, supports column sorting and checkboxes, and reviews the selected metadata without restoring anything. The SFSU logo appears in the header. App, Backups, and Logs are resolved from the launcher location; existing backups are preserved.

- [Project runbook](PROJECT-RUNBOOK.md): current state, decisions, milestones, validation, and next steps.
- [Current workflow review](docs/CURRENT-WORKFLOW-REVIEW.md): findings from the supplied scripts, binaries, and migration XML.
- [Reporting guide](docs/REPORTING.md): report features, durable events/recovery, backup log snapshots, development API, and validation commands.
- [Application testing guide](docs/APP-TESTING.md): discovery, directory credentials, manual identities, folder naming, metadata, and preparation/restore-review limits.
- [Project instructions](AGENTS.md): conventions for maintaining this project with Codex.

## Chat workflow

Use `$start-chat` to load project context and `$chat-closeout` to update the runbook. Both project-local skills live in `.agents/skills/`. Closeout includes a question about committing and pushing project changes; publishing requires the user's answer.

## Local reference archive

Legacy scripts, the UI mock-up and logo, and the supplied USMT toolsets are retained locally in `archive/legacy-and-mockup/`. That folder is ignored by Git and is not included in a clone of this repository. Links into it in the project records require the local reference copies.

The archived scripts operate on employee data and are reference material. They are not the new production toolkit.

The supplied logo under `App/Assets/` is included with the application source. User-supplied ADK files under `App/User State Migration Tool/` are Git-ignored and must be obtained separately when migration integration is implemented; this application works without them and never executes them. Runtime `Backups/`, `Logs/`, and `tests/.work/` are also Git-ignored. Keep the launcher and App together; preserve existing Backups and Logs when updating the application. Developer-only synthetic reports remain available with `sfsu-usmt.cmd -Headless -Scenario Failed`.
