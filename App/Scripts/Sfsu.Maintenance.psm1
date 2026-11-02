# Explicit package maintenance only. Never runs on startup or touches Backups.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Logging.psm1')

function Get-SfsuStorageAccessReview([string]$PackageRoot) {
    foreach ($name in @('Logs','Backups')) {
        $path=Join-Path $PackageRoot $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        [void](Assert-SfsuSafePath $path)
        $broad=@()
        foreach ($rule in (Get-Acl -LiteralPath $path).Access) {
            if ($rule.AccessControlType -ne 'Allow') { continue }
            $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($sid -in @('S-1-1-0','S-1-5-11','S-1-5-32-545','S-1-5-7')) {
                $broad+=($sid+': '+$rule.FileSystemRights)
            }
        }
        [pscustomobject]@{Path=$path;BroadAllowRules=$broad -join '; ';NeedsReview=($broad.Count -gt 0)
            Scope='Filesystem ACL screening only; verify effective user/group access, child ACLs and server-side SMB share permissions separately.'}
    }
}

function Get-SfsuRetentionTree([string]$Path) {
    # Validate before descending: never recurse through a link.
    [void](Assert-SfsuSafePath $Path)
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        [void](Assert-SfsuSafePath $item.FullName)
        if ($item.PSIsContainer) { Get-SfsuRetentionTree $item.FullName }
        $item
    }
}

function Remove-SfsuRetentionTree([string]$Path) {
    $guard=Enter-SfsuPathGuard $Path
    try {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
            [void](Assert-SfsuSafePath $item.FullName)
            if ($item.PSIsContainer) { Remove-SfsuRetentionTree $item.FullName }
            else { [IO.File]::Delete($item.FullName) }
        }
    } finally { $guard.Dispose() }
    # Nonrecursive removal cannot follow a newly substituted directory link.
    [IO.Directory]::Delete($Path,$false)
}

function Invoke-SfsuLogRetention {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$PackageRoot,
        [ValidateRange(1,3650)][int]$Days=30,[switch]$Apply,
        [DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    $logs=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'Logs')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $logs)) { return }
    [void](Assert-SfsuSafePath $logs)
    $guard=Enter-SfsuPathGuard $logs
    $cutoff=$Now.AddDays(-$Days)
    try {
        foreach ($folder in Get-ChildItem -LiteralPath $logs -Directory -Force) {
            $status='Preserved'; $reason='Unknown, active, damaged or recent run.'
            try {
                $path=[IO.Path]::GetFullPath($folder.FullName)
                if ([IO.Path]::GetDirectoryName($path) -ne $logs -or $folder.Name -notmatch '^\d{8}T\d{9}Z-[0-9a-f]{12}$') { throw 'Not a generated root log run.' }
                $tree=@(Get-SfsuRetentionTree $path)
                if (@($tree | Where-Object { $_.LastWriteTimeUtc -ge $cutoff.UtcDateTime }).Count -gt 0 -or $folder.LastWriteTimeUtc -ge $cutoff.UtcDateTime) { throw 'Recently changed files are preserved.' }
                # Reuse the bounded journal validator; no repair/render during cleanup.
                $logger=Get-Module Sfsu.Logging
                $journal=& $logger { param($p) Read-SfsuEvents (Get-SfsuRunHandle $p) } $path
                if ([IO.Path]::GetFullPath([string]$journal.Events[0].Data.PackageRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') -or $journal.Events[0].Data.RunId -ne $folder.Name) { throw 'Not an original root log run for this package; backup snapshots are preserved.' }
                $last=$journal.Events[-1]
                if ($journal.InvalidLines -or $last.Type -ne 'RunFinished' -or [DateTimeOffset]::Parse($last.TimeUtc) -ge $cutoff) { throw 'Only old finalized readable runs are eligible.' }
                $status='Eligible'; $reason='Finalized root log run older than '+$Days+' days.'
                if ($Apply -and $PSCmdlet.ShouldProcess($path,'Delete this finalized root diagnostic run')) {
                    # Recheck descendants immediately before deletion. Backups and
                    # their finalized snapshots are never candidates.
                    [void]@(Get-SfsuRetentionTree $path)
                    Remove-SfsuRetentionTree $path
                    $status='Removed'
                }
            } catch { $status='Preserved'; $reason=$_.Exception.Message }
            [pscustomobject]@{Path=$folder.FullName;Status=$status;Reason=$reason}
        }
    } finally { $guard.Dispose() }
}

Export-ModuleMember -Function Get-SfsuStorageAccessReview, Invoke-SfsuLogRetention
