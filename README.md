# SFSU USMT

Project planning and development for a guided employee backup and restore toolkit using Windows User State Migration Tool (USMT).

The portable reporting foundation is implemented locally. Backup and restore engine integration is still pending; the current launcher generates clearly labeled sample reports and never runs USMT.

Open `sfsu-usmt.cmd` for the reporting preview, or use `sfsu-usmt.cmd -Headless -Scenario Failed` to generate a sample without a window. App, Backups, and Logs are resolved from the launcher location. Existing backups are preserved.

- [Project runbook](PROJECT-RUNBOOK.md): current state, decisions, milestones, validation, and next steps.
- [Current workflow review](docs/CURRENT-WORKFLOW-REVIEW.md): findings from the supplied scripts, binaries, and migration XML.
- [Reporting guide](docs/REPORTING.md): report features, durable events/recovery, backup log snapshots, development API, and validation commands.
- [Project instructions](AGENTS.md): conventions for maintaining this project with Codex.

## Chat workflow

Use `$start-chat` to load project context and `$chat-closeout` to update the runbook. Both project-local skills live in `.agents/skills/`. Closeout includes a question about committing and pushing project changes; publishing requires the user's answer.

## Local reference archive

Legacy scripts, the UI mock-up and logo, and the supplied USMT toolsets are retained locally in `archive/legacy-and-mockup/`. That folder is ignored by Git and is not included in a clone of this repository. Links into it in the project records require the local reference copies.

The archived scripts operate on employee data and are reference material. They are not the new production toolkit.

The supplied logo under `App/Assets/` is included with the reporting source. User-supplied ADK files under `App/User State Migration Tool/` are Git-ignored and must be obtained separately when migration integration is implemented; the reporting preview works without them and never executes them. Runtime `Backups/`, `Logs/`, and `tests/.work/` are also Git-ignored. Deploy the launcher and App together; preserve existing Backups and Logs when updating the application.
