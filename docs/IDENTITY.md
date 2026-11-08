# Identity configuration and verification

University IDs, Windows account names, UPNs and source-profile paths are separate values. The registered profile SID anchors domain-account verification. An account rename or unrelated profile-folder name does not invalidate a matching SID. A different SID is never accepted as the original domain account. The connected [native engine](MIGRATION.md) selects exact source SIDs; recreated local accounts are the explicitly supported new-SID exception under the same local name.

## Shared configuration

Ship these files together under `App/Scripts/`:

- `Sfsu.Identity.psd1`: university attribute and login-suffix settings.
- `Sfsu.Identity.psm1`: shared validation/normalization for the application and standalone LDAP diagnostic.

The default configuration is:

```powershell
@{
    IdAttribute = 'sAMAccountName'
    DefaultLoginSuffix = 'sfsu.edu'
    AllowedLoginSuffixes = @('sfsu.edu')
}
```

`IdAttribute` names the single-valued AD attribute containing the university ID. It currently uses the established campus `sAMAccountName` convention. If the university moves IDs to an attribute such as `employeeID`, update this mapping after confirming that attribute is populated correctly. The application requests the attribute in its existing exact-SID search. It never searches an entire directory for a similar name or interpolates an ID into an LDAP filter. A missing, multivalued or invalid ID remains unresolved; there is no fallback to another attribute or the folder name.

`DefaultLoginSuffix` is appended to a bare technician account login. `AllowedLoginSuffixes` controls accepted full UPN suffixes and must include the default. For example, multiple suffixes can coexist during a university transition. A university ID need not be an account login; use the actual account login/UPN when they differ. Passwords and credentials never belong in this file.

Missing, malformed, oversized (over 4 KB), linked or inconsistent configuration fails explicitly. It is not replaced silently with default rules. Attribute names and DNS suffix syntax are validated. Update the configuration with the app closed, then relaunch it; active modules keep the policy loaded at import. The configuration is a maintained source file, separate from runtime `App/Settings/appearance.json`.

## Accepted text and sign-in

IDs are text of 1–256 UTF-16 code units, with no whitespace, control or format characters. Letters, digits, leading zeros, dots, hyphens and other printable punctuation are preserved. There is no numeric-length rule or special meaning assigned to a `p` prefix. Account login input is trimmed, bounded to 256 code units before the suffix, and rejects whitespace, path characters and multiple `@` signs. Full logins must use a configured suffix. These are application safety bounds, not a claim that AD accepts every spelling or length.

P-prefixed credentials are permitted. The app still requires explicitly supplied credentials and uses Kerberos only, signed/sealed LDAP, bounded timeouts and no NTLM/default-credential fallback. Directory permissions and the server determine whether a supplied account can authenticate and read the required attributes. Existing credential expiry, retry cooldowns and manual continuation remain.

## Discovery and manual identity

Domain candidates start with no inferred university ID or account name. AD verification requires one exact returned SID matching the registered profile SID, valid ID text from the configured attribute, a Windows account name and a display name. The verified row and metadata keep the ID, ID attribute, SAM account name, full UPN and SID separately. Folder spelling does not participate in verification. Local profiles remain classified using the current machine's SAM SID prefix and never receive an SFSU ID or an AD check mark. Other-machine/orphaned S-1-5-21 profiles can still be labeled domain candidates before verification; Entra profiles remain unsupported.

Without AD, **Assign Display Name** asks for an explicitly confirmed domain ID and display name, tied to the selected profile SID/path. It does not guess either value from the folder name. Local accounts show a read-only account name and require only a display name. Manual assignment clears previous AD evidence and the verification mark. Actual SID or multiple-match conflicts cannot be bypassed by manual assignment.

The optional current-name refresh follows the saved directory SID even if the account name/ID has changed. It updates displayed name and Formerly known as only, preserving saved metadata/folders. Native domain restore retains the saved SID. Local restore checks all target collisions, recreates accounts disabled with individual technician-entered passwords, maps only the original local name to the same destination name, and verifies final enabled/Administrators choices. Existing local accounts are never reused; no local-to-domain conversion exists.

## Metadata and folder labels

New preparation folders use `backup.json` schema version **3**, with separate ID, ID attribute/source, Windows account name, UPN and source/directory SID fields. They remain `PreparedOnly`, with `HasMigrationData=false`.

Native capture uses schema **4**, preserving those identity fields and adding source OS/architecture, tool/rule hashes, native results, capture state and store-verification evidence. Only CapturedVerified/CapturedWithWarnings with HasMigrationData=true restore; Capturing/CaptureFailed/CaptureCancelled remain blocked. EfsDecryptionVerified stays false without intended-user acceptance. Passwords and restore credential objects are never saved. Version-three PreparedOnly records remain readable and cannot restore.

Versions 1 and 2 from earlier development tests are intentionally unsupported. Those folders remain visible as unrecognized; nothing is converted or deleted. Legacy-script USMT stores are not imported or recognized as usable backups by this change.

Backup folder labels still use ID/name/computer/Pacific timestamp components. Invalid filesystem characters are replaced and labels are shortened to leave room for preparation-log staging on Windows PowerShell 5.1. Exact identity text stays in metadata. Shortened/sanitized labels can coincide; atomic reservation refuses an existing timestamped destination and never overwrites or merges it. A package path too long for the required label/log space fails explicitly.

## Standalone diagnostic

`tools/Test-SfsuLdaps.ps1` uses the same shared login policy, including p-prefixed and alphabetic logins. Keep it in the package's `tools/` folder with the shared identity module/configuration under `App/Scripts/`. Its `-ExpectedAccountId` remains an expected **SAM account name**, not the configured university-ID attribute. Credential-account testing searches the escaped literal UPN, reads the actual SAM name/SID, and then verifies that SID; it does not derive a SAM name from the UPN prefix. CredentialUpnMatches replaces the former convention-based UPN check and is null for an explicitly supplied profile target. Transport, single-DC behavior and evidence limits are otherwise unchanged. This change does not resume LDAPS/CBT investigation or change the app's LDAP transport.
