# SFSU USMT reporting

The reporting layer and portable application are implemented. The normal GUI now logs real profile discovery, signed/sealed LDAP lookup, backup-folder/metadata preparation, backup inventory, and restore-selection review. **Backup and restore engines are not connected.** See [Application testing](APP-TESTING.md). Live reports identify the actual operation and never claim that folder preparation captured employee data.

Developer-only headless samples remain for testing the report renderer. Samples never run ScanState, LoadState, UsmtUtils, account changes, or employee-data copies. A sample verifies only that its Backups folder accepts a temporary write; its capture/verification events and diagnostic file are synthetic.

## Try the reports

Open `sfsu-usmt.cmd` for the real discovery/preparation GUI. Use **Open latest report** or **Open Logs folder** after an action to find its actual journal and HTML report. Preparation reports are also copied into the prepared folders. The launcher applies execution-policy Bypass only to its PowerShell process; it does not change saved policies or elevate automatically.

For an explicitly synthetic developer sample without opening a window (Completed, Warnings, Failed, Cancelled, or Incomplete):

```powershell
.\sfsu-usmt.cmd -Headless -Scenario Failed
```

The command prints the report path. Its exit code indicates whether report generation succeeded; a deliberately simulated Failed outcome still returns zero when its report was generated successfully.

The launcher resolves App from its own location. The application resolves Backups and Logs from the package root. Neither depends on a particular drive letter or the launching working directory. Backups and Logs are created if missing; existing content is preserved. The destination access probe uses its own unique temporary file, deleted when closed. Local paths containing spaces, ampersands, and parentheses have been tested; elevated mappings, UNC shares, and physical removable-drive filesystems still require representative tests.

## Report layout

Each run receives a unique UTC timestamp/GUID identifier:

```text
Logs/<run-id>/
    report.html
    events.jsonl
    Raw/
        <original diagnostic logs>
```

- The overall result distinguishes Completed, Completed with warnings, Failed, Cancelled, and Incomplete.
- Step cards stay in their defined order and show results, durations, checkpoints, and next actions. Sorting the event table does not rearrange them.
- The event table supports sorting, severity filtering, text search, and reset. Sequence numbers restore the original event order. Time sorting uses UTC instants even across daylight-saving changes; displayed times use America/Los_Angeles with an explicit offset.
- Errors and warnings have exclamation marks, text labels, and color. Technical details can be expanded. Log content is HTML-escaped.
- Print includes all events in sequence, even when the screen was filtered; the previous view is restored afterward.
- The HTML embeds styling, scripting, and the logo when available. It makes no remote resource requests. All events remain readable when JavaScript is disabled; sorting/filtering require scripting permitted by the browser. No browser security settings are changed.
- Links to raw logs and the event journal are relative. Keep those files beside the report when moving it. The raw files retain their original bytes; a report never replaces engine diagnostics.

## Durable events and interruption recovery

Events are appended and flushed to `events.jsonl` before the HTML is refreshed. Only one writer should use a particular run; independent runs use separate directories. Successful completion requires an explicit terminal event and results for every declared step. Declared steps are currently required steps; skipped or unfinished steps cannot produce Completed. Recorded errors/warnings propagate to the final result and cannot be hidden by requesting Passed/Completed.

Until a final event is recorded, the report says **Incomplete** and explains that work may still be active or may have been interrupted. It is a snapshot; refresh or reopen it to read newer events. A stale or missing report can be regenerated without launching a migration:

```powershell
.\sfsu-usmt.cmd -RebuildReport "D:\SFSU-USMT\Logs\<run-id>"
```

Regeneration finds raw logs even if an interrupted process never registered them. Unreadable/out-of-sequence journal lines produce a visible diagnostic and an Incomplete result; damaged journals cannot be silently extended. Preserve the original journal for troubleshooting. If no readable run header remains, rebuilding fails explicitly.

HTML is replaced from a complete temporary file. Filesystems that reject atomic replacement fall back to overwriting from that completed file; interruption during that fallback may require regeneration from the journal. An inaccessible log destination is reported as an error. Startup failures before the module is available use a plain-text `Logs/startup-<id>.txt` fallback; if that is also unwritable, the error remains on the console.

## Logs that travel with a backup

`Export-SfsuLogSnapshot` copies an ended run into an existing `Backups/<backup-id>/Logs/<run-id>/` folder. It uses a fresh staging directory, then renames it into place. It never overwrites an existing snapshot or changes existing backup data. Root Logs remains the primary run record; backup copies are finalized snapshots. Future restore operations will have new run IDs and can add their own snapshots to the same backup.

```powershell
# $run is returned by New-SfsuLogRun; this requires an ended run.
Export-SfsuLogSnapshot -Run $run -BackupPath 'D:\SFSU-USMT\Backups\existing-backup'
```

A copy failure leaves the original root logs available, writes `snapshot-error.txt`, adds a warning banner to the root report, and raises an error to the caller. The final staging-folder rename receives up to three attempts with a short bounded backoff for temporary file locks; persistent failure is still reported. A partial copy may remain with a `.partial` suffix; it is not a finalized snapshot. No automatic cleanup/retention is implemented. Interrupted runs can be reviewed in root Logs but are not exported as finalized snapshots.

## Integrating future operations

`App/Scripts/Sfsu.Logging.psm1` exports:

| Function | Responsibility |
| --- | --- |
| `New-SfsuLogRun` | Create a unique run and its durable start record with an ordered list of steps. |
| `Start-SfsuLogStep` | Record the start of one defined step. |
| `Write-SfsuLogEvent` | Record information, warning/error messages, next actions, and technical details. |
| `Write-SfsuCheckpoint` | Record actual evidence as Passed, Warning, Failed, or NotRun. |
| `Complete-SfsuLogStep` | Record Passed, Warning, Failed, or Skipped; preserve higher recorded severities. |
| `Get-SfsuRawLogPath` | Supply a safe path inside Raw for an engine's original output. |
| `Add-SfsuRawLog` | Register an existing raw diagnostic file. |
| `Complete-SfsuLogRun` | Finalize a run with a result; enforce completion/severity rules. |
| `Update-SfsuLogReport` | Rebuild HTML from saved events without running USMT. |
| `Export-SfsuLogSnapshot` | Preserve finalized report/journal/raw-log copies alongside an existing backup. |

The caller remains responsible for performing the checks and supplying truthful evidence. The logging module does not execute or interpret USMT commands, verify stores, establish account mappings, or prove restore fidelity. Keep credentials and encryption keys out of all messages/details. Define backup identities, data coverage, engine return-code handling, and acceptance criteria before connecting migrations.

## Validation

Run the synthetic PowerShell suite with Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File tests/Test-Logging.ps1
```

The suite writes ignored artifacts under `tests/.work/`, tests portable CMD invocation, all five sample outcomes, result integrity, interruption recovery, HTML escaping, raw-log preservation, snapshot errors/collisions, and preservation of existing backup content.

`tests/Test-ReportBrowser.cjs` uses Playwright with installed Microsoft Edge. Supply a Failed sample HTML file and an artifact directory. It tests sorting, search, filters, printing, offline links/assets, narrow screens, and JavaScript-disabled reading. Test tools are development dependencies only; technicians need neither Node.js nor Playwright.

Runtime Backups, Logs, test artifacts, and the locally supplied `App/User State Migration Tool/` ADK payload are Git-ignored. The source includes the logo under `App/Assets/`; the reporting preview works without ADK binaries. Tool updates should replace the launcher and App without replacing Backups or Logs. No migration executable is run during report validation.
