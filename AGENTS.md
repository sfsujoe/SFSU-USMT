# USMT project workflow

- Read [PROJECT-RUNBOOK.md](PROJECT-RUNBOOK.md) at the beginning of a new project chat. It contains the current state, decisions, validation evidence, and next steps.
- Use `$start-chat` to load and summarize the project context. Use `$chat-closeout` to reconcile this chat into the runbook. Their project-local definitions live in `.agents/skills/`.
- At closeout, after updating the runbook and preparing a reviewable change summary, ask whether project changes should be committed and pushed to `https://github.com/sfsujoe/SFSU-USMT.git`. Do not treat closeout itself as permission to publish. Include any required Git setup in the question; report when there is nothing new to push.
- Keep the runbook current when substantive project work or decisions change. Avoid entries for routine questions with no lasting impact. A closeout should add only information not already captured.
- Separate user-confirmed decisions, implemented behavior, recommendations, and unknowns. Discussion of a feature is not approval to implement it. Preserve superseded decisions with a short explanation.
- Record what was actually validated, by whom, and any limits. A successful mock-up launch is not evidence that USMT backup or restore works.
- Use dates in America/Los_Angeles for project records. Keep credentials, encryption keys, employee data, and unneeded personal identifiers out of the runbook.
- The legacy scripts and UI-only wizard are retained as local reference material in `archive/legacy-and-mockup/`, which is ignored by Git. No active migration implementation exists yet. Use the runbook's current file locations; an absent local archive in a fresh clone is expected. Do not execute the legacy scripts as a UI test or revive archived code unless the task calls for it.
- Make local development changes within the user's request. A runbook update or closeout does not authorize deployment to the share, moving backups, running migrations, changing saved execution policies, or archiving the chat.
- Git was initialized on the user's request on 2026-10-23. The initial branch is `main`, with origin `https://github.com/sfsujoe/SFSU-USMT.git`. Check the current status, branch, and remotes before Git work. The initial commit was requested locally; publishing still requires user authorization.
