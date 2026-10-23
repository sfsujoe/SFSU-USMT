# SFSU USMT

Project planning and development for a guided employee backup and restore toolkit using Windows User State Migration Tool (USMT).

The project is currently in discovery. No production replacement implementation is included in this baseline.

- [Project runbook](PROJECT-RUNBOOK.md): current state, decisions, milestones, validation, and next steps.
- [Current workflow review](docs/CURRENT-WORKFLOW-REVIEW.md): findings from the supplied scripts, binaries, and migration XML.
- [Project instructions](AGENTS.md): conventions for maintaining this project with Codex.

## Chat workflow

Use `$start-chat` to load project context and `$chat-closeout` to update the runbook. Both project-local skills live in `.agents/skills/`. Closeout includes a question about committing and pushing project changes; publishing requires the user's answer.

## Local reference archive

Legacy scripts, the UI mock-up and logo, and the supplied USMT toolsets are retained locally in `archive/legacy-and-mockup/`. That folder is ignored by Git and is not included in a clone of this repository. Links into it in the project records require the local reference copies.

The archived scripts operate on employee data and are reference material. They are not the new production toolkit.
