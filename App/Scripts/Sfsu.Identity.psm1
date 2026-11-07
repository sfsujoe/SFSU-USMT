# Shared, read-only identity policy for the application and standalone diagnostic.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-SfsuIdentityPolicy {
    $path=Join-Path $PSScriptRoot 'Sfsu.Identity.psd1'
    $item=Get-Item -LiteralPath $path -Force
    if ($item.Length -gt 4096 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Identity configuration must be a regular file of at most 4 KB.' }
    $policy=Import-PowerShellDataFile -LiteralPath $path
    if ($policy.Count -ne 3 -or $policy.IdAttribute -isnot [string] -or $policy.IdAttribute -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,63}$') { throw 'Invalid identity attribute configuration.' }
    $suffixes=@($policy.AllowedLoginSuffixes)
    if ($suffixes.Count -lt 1 -or $suffixes.Count -gt 32) { throw 'Configure between one and 32 login suffixes.' }
    foreach ($suffix in @($policy.DefaultLoginSuffix)+$suffixes) {
        if ($suffix -isnot [string] -or $suffix.Length -gt 253 -or $suffix -notmatch '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') { throw 'Invalid login suffix configuration.' }
    }
    if ($policy.DefaultLoginSuffix -notin $suffixes) { throw 'The default login suffix must be allowed.' }
    $policy
}
$script:IdentityPolicy=Get-SfsuIdentityPolicy

function Test-SfsuIdentityText($Value) {
    # IDs are opaque text, never filesystem paths or interpolated LDAP filters.
    $Value -is [string] -and $Value.Length -ge 1 -and $Value.Length -le 256 -and $Value -notmatch '[\s\p{C}]'
}

function ConvertTo-SfsuLogin([string]$UserName) {
    $value=$UserName.Trim()
    $parts=$value.Split('@')
    if ($parts.Count -gt 2 -or -not (Test-SfsuIdentityText $parts[0]) -or $parts[0] -match '["/\\:;<>\[\]|,=]') { throw 'Enter your SFSU account login or full UPN without spaces or path characters.' }
    if ($parts.Count -eq 1) { return ($value+'@'+$script:IdentityPolicy.DefaultLoginSuffix) }
    if ($parts[1] -notin @($script:IdentityPolicy.AllowedLoginSuffixes)) { throw 'Use a login suffix allowed by the toolkit identity configuration.' }
    $value
}

Export-ModuleMember -Function Get-SfsuIdentityPolicy, Test-SfsuIdentityText, ConvertTo-SfsuLogin
