Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Logging.psm1')
$script:PolicyVersion='2026.11.07.1'

function Read-SfsuSmallText([string]$Path) {
    $info=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($info.Length -gt 1MB -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe or oversized provider configuration.' }
    $file=[Sfsu.SafeFiles]::Open($Path,$false,$false)
    $reader=New-Object IO.StreamReader($file)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Expand-SfsuProfileLocation([string]$Value,$Profile,[switch]$CloudRoot) {
    $path=$Profile.ProfilePath
    $values=@{USERPROFILE=$path;LOCALAPPDATA=(Join-Path $path 'AppData/Local');APPDATA=(Join-Path $path 'AppData/Roaming');USERNAME=([IO.Path]::GetFileName($path));HOMEDRIVE=[IO.Path]::GetPathRoot($path).TrimEnd('\');HOMEPATH=$path.Substring(2)}
    foreach ($name in $values.Keys) { $Value=[regex]::Replace($Value,'%'+$name+'%',([Text.RegularExpressions.MatchEvaluator]{param($m) $values[$name]}.GetNewClosure()),[Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    $Value=[Environment]::ExpandEnvironmentVariables($Value)
    if ($Value -match '[%*?\x00-\x1f]' -or -not [IO.Path]::IsPathRooted($Value) -or $Value -match '^\\[^\\]') { throw 'Provider path is unresolved, relative or contains unsupported pattern characters.' }
    $full=[IO.Path]::GetFullPath($Value).TrimEnd('\')
    if ($full -ieq $path.TrimEnd('\')) { throw 'A cloud exclusion cannot be the entire employee profile.' }
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        if (-not $CloudRoot -or $full -ieq $env:SystemDrive -or $full -ieq [IO.Path]::GetPathRoot($path).TrimEnd('\')) { throw 'A cloud exclusion cannot be a whole volume containing Windows or the employee profile.' }
        $full+='\' # A dedicated cloud mount can occupy a separate volume.
    }
    $full
}

function Get-SfsuLocationReview($Profile) {
    $roots=New-Object Collections.Generic.List[object]
    $browsers=New-Object Collections.Generic.List[object]
    $issues=New-Object Collections.Generic.List[string]
    $redirected=New-Object Collections.Generic.List[string]
    $seen=@{}
    $addRoot={param([string]$value,[string]$source)
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        try {
            $path=Expand-SfsuProfileLocation $value $Profile -CloudRoot
            if (-not $seen.ContainsKey($path)) { $seen[$path]=$true; $roots.Add([pscustomobject]@{Path=$path;Source=$source}) }
            if ([IO.Directory]::Exists($path)) {
                try {
                    $final=Expand-SfsuProfileLocation ([Sfsu.Engine.Locations]::FinalDirectory($path)) $Profile -CloudRoot
                    if (-not $seen.ContainsKey($final)) { $seen[$final]=$true; $roots.Add([pscustomobject]@{Path=$final;Source=($source+' resolved target')}) }
                } catch { $issues.Add($source+': confirm any redirected/junction target manually.') }
            }
        } catch { $issues.Add($source+': location could not be represented safely; review the provider configuration.') }
    }
    # Defaults are explicit exclusions even if a provider is currently uninstalled.
    foreach ($relative in @('OneDrive','Box','Box Sync','Dropbox','iCloudDrive','iCloud Drive','Google Drive','AppData/Local/Box','AppData/Roaming/Box','AppData/Local/Dropbox','AppData/Roaming/Dropbox','AppData/Local/Google/DriveFS','AppData/Local/Microsoft/OneDrive')) {
        & $addRoot (Join-Path $Profile.ProfilePath $relative) 'Known provider root/cache'
    }
    foreach ($parent in @(Get-ChildItem -LiteralPath $Profile.ProfilePath -Directory -Force -ErrorAction SilentlyContinue | Where-Object Name -Like 'OneDrive*')) { & $addRoot $parent.FullName 'OneDrive default family' }
    foreach ($base in @('AppData/Local/Dropbox/info.json','AppData/Roaming/Dropbox/info.json')) {
        $jsonPath=Join-Path $Profile.ProfilePath $base
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $json=ConvertFrom-Json (Read-SfsuSmallText $jsonPath)
                foreach ($entry in $json.PSObject.Properties) {
                    if ($entry.Value.PSObject.Properties['path']) { & $addRoot ([string]$entry.Value.path) 'Dropbox info.json' }
                }
            } catch { $issues.Add('Dropbox configuration could not be read; confirm its actual root manually.') }
        }
    }
    $hive=$null
    try {
        $hive=[Microsoft.Win32.Registry]::Users.OpenSubKey($Profile.ProfileSid)
        if ($null -eq $hive) {
            $hivePath=Join-Path $Profile.ProfilePath 'NTUSER.DAT'
            # Reject a linked hive/ancestor without requiring source file-list access.
            $inspection=Get-Item -LiteralPath $hivePath -Force -ErrorAction Stop
            if ($inspection.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked user hive.' }
            $hive=[Sfsu.Engine.Accounts]::OpenHive($hivePath)
        }
        $accounts=$hive.OpenSubKey('Software\Microsoft\OneDrive\Accounts')
        if ($accounts) { try { foreach ($name in $accounts.GetSubKeyNames()) { $key=$accounts.OpenSubKey($name); try { & $addRoot ([string]$key.GetValue('UserFolder','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) 'OneDrive account UserFolder' } finally { $key.Dispose() } } } finally { $accounts.Dispose() } }
        $shell=$hive.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders')
        if ($shell) { try { foreach ($name in $shell.GetValueNames()) { $value=[string]$shell.GetValue($name,'',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if ($value) { $redirected.Add($name+': '+$value) } } } finally { $shell.Dispose() } }
        foreach ($browser in @(@('Chrome','Software\Policies\Google\Chrome'),@('Edge','Software\Policies\Microsoft\Edge'))) {
            foreach ($registry in @($hive,[Microsoft.Win32.Registry]::LocalMachine)) {
                $key=$registry.OpenSubKey($browser[1])
                if ($key) { try {
                    $value=[string]$key.GetValue('UserDataDir','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($value) { try { $browsers.Add([pscustomobject]@{Browser=$browser[0];Path=(Expand-SfsuProfileLocation $value $Profile)}) } catch { $issues.Add($browser[0]+' custom UserDataDir needs manual review.') } }
                } finally { $key.Dispose() } }
            }
        }
    } catch { $issues.Add('The user registry could not be fully inspected. Review cloud roots, redirected folders and custom browser data locations manually.') }
    finally { if ($hive) { $hive.Dispose() } }
    # SyncRootManager includes provider/user SID registrations, including roots
    # outside the selected profile that broad system-document discovery could see.
    foreach ($base in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager')) {
        $manager=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base)
        if ($manager) { try {
            foreach ($provider in $manager.GetSubKeyNames()) {
                $key=$manager.OpenSubKey($provider+'\UserSyncRoots')
                if ($key) { try { foreach ($value in $key.GetValueNames()) { & $addRoot ([string]$key.GetValue($value,'',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) ('Windows SyncRootManager: '+$provider) } } finally { $key.Dispose() } }
            }
        } finally { $manager.Dispose() } }
    }
    foreach ($boxKey in @('SOFTWARE\Box\Box','SOFTWARE\WOW6432Node\Box\Box')) {
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($boxKey)
        if ($key) { try { $parent=[string]$key.GetValue('CustomBoxLocation','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if ($parent) { & $addRoot ($parent.TrimEnd('\')+'\Box') 'Box Drive CustomBoxLocation' } } finally { $key.Dispose() } }
    }
    $firefox=Join-Path $Profile.ProfilePath 'AppData/Roaming/Mozilla/Firefox/profiles.ini'
    if (Test-Path -LiteralPath $firefox) {
        try {
            $section=@{}
            foreach ($line in @((Read-SfsuSmallText $firefox) -split '\r?\n')+@('[end]')) {
                if ($line -match '^\s*\[') {
                    if ($section.ContainsKey('Path')) {
                        $location=[string]$section.Path
                        if ($section['IsRelative'] -ne '0') { $location=Join-Path ([IO.Path]::GetDirectoryName($firefox)) $location }
                        $browsers.Add([pscustomobject]@{Browser='Firefox';Path=(Expand-SfsuProfileLocation $location $Profile)})
                    }
                    $section=@{}
                } elseif ($line -match '^\s*(Path|IsRelative)\s*=\s*(.*?)\s*$') { $section[$Matches[1]]=$Matches[2] }
            }
        } catch { $issues.Add('Firefox custom profiles need manual review.') }
    }
    $issues.Add('Review custom Box Sync, Google Drive mirror/stream, relocated caches, portable browsers and other provider locations not represented by registrations. No cloud sync-status audit is performed.')
    [pscustomobject]@{Profile=$Profile;CloudRoots=$roots.ToArray();BrowserRoots=$browsers.ToArray();RedirectedFolders=$redirected.ToArray();Issues=$issues.ToArray();Reviewed=$false;AdditionalCloudRoots=@();AdditionalBrowserRoots=@()}
}

function Add-SfsuXmlPattern($Document,$ObjectSet,[string]$Type,[string]$Value) {
    $node=$Document.CreateElement('pattern'); $node.SetAttribute('type',$Type); $node.InnerText=$Value; [void]$ObjectSet.AppendChild($node)
}

function New-SfsuMigrationPolicy {
    param([string]$Path,$Review,[string]$PackageRoot,[string[]]$OtherProfiles=@())
    if (-not $Review.Reviewed) { throw 'Review cloud and custom browser locations before capture.' }
    $document=New-Object Xml.XmlDocument
    $migration=$document.CreateElement('migration'); $migration.SetAttribute('urlid','https://sfsu.edu/usmt/policy/'+$script:PolicyVersion); [void]$document.AppendChild($migration)
    $profile=$Review.Profile
    $cloud=@(foreach ($location in @($Review.CloudRoots | ForEach-Object Path)+@($Review.AdditionalCloudRoots)) {
        $resolved=Expand-SfsuProfileLocation $location $profile -CloudRoot
        $resolved
        if ([IO.Directory]::Exists($resolved)) {
            $target=Expand-SfsuProfileLocation ([Sfsu.Engine.Locations]::FinalDirectory($resolved)) $profile -CloudRoot
            if ($target -ine $resolved) { $target }
        }
    })
    $browserRoots=@(
        [pscustomobject]@{Browser='Edge';Path=(Join-Path $profile.ProfilePath 'AppData/Local/Microsoft/Edge/User Data')},
        [pscustomobject]@{Browser='Chrome';Path=(Join-Path $profile.ProfilePath 'AppData/Local/Google/Chrome/User Data')},
        [pscustomobject]@{Browser='Firefox';Path=(Join-Path $profile.ProfilePath 'AppData/Roaming/Mozilla/Firefox/Profiles')}
    )+@($Review.BrowserRoots)+@($Review.AdditionalBrowserRoots)
    foreach ($context in @('User','System')) {
        $component=$document.CreateElement('component'); $component.SetAttribute('type','Documents'); $component.SetAttribute('context',$context); [void]$migration.AppendChild($component)
        $display=$document.CreateElement('displayName'); $display.InnerText='SFSU policy '+$context; [void]$component.AppendChild($display)
        $role=$document.CreateElement('role'); $role.SetAttribute('role','Data'); [void]$component.AppendChild($role)
        $rules=$document.CreateElement('rules'); [void]$role.AppendChild($rules)
        $exclude=$document.CreateElement('unconditionalExclude'); [void]$rules.AppendChild($exclude)
        $objects=$document.CreateElement('objectSet'); [void]$exclude.AppendChild($objects)
        foreach ($extension in @('exe','msi','ost','tmp')) { Add-SfsuXmlPattern $document $objects File ('* [*.'+$extension+']') }
        $excluded=@($cloud)+@($OtherProfiles)+@($PackageRoot)+@(
            '%WINDIR%\Temp','%WINDIR%\SoftwareDistribution\Download',
            '%CSIDL_COMMON_APPDATA%\Microsoft\Windows Defender','%CSIDL_COMMON_APPDATA%\Microsoft\Windows Defender Advanced Threat Protection',
            '%PROGRAMFILES%\Windows Defender','%PROGRAMFILES%\Windows Defender Advanced Threat Protection',
            '%CSIDL_LOCAL_APPDATA%\Temp'
        )
        foreach ($root in @($excluded | Where-Object { $_ } | Sort-Object -Unique)) {
            $base=$root.TrimEnd('\'); if ($base -match '^[A-Za-z]:$') { $base+='\' }
            Add-SfsuXmlPattern $document $objects File ($base+' [*]')
            Add-SfsuXmlPattern $document $objects File ($root.TrimEnd('\')+'\* [*]')
        }
        foreach ($key in @('HKLM\SOFTWARE\Microsoft\Windows Defender','HKLM\SOFTWARE\Microsoft\Windows Advanced Threat Protection','HKCU\SOFTWARE\Microsoft\Windows Defender','HKLM\SYSTEM\CurrentControlSet\Services\WinDefend','HKLM\SYSTEM\CurrentControlSet\Services\WdNisSvc','HKLM\SOFTWARE\Policies\Microsoft\Windows Defender')) {
            Add-SfsuXmlPattern $document $objects Registry ($key+' [*]'); Add-SfsuXmlPattern $document $objects Registry ($key+'\* [*]')
        }
        foreach ($browser in $browserRoots) {
            $root=Expand-SfsuProfileLocation $browser.Path $profile
            if ($context -eq 'User' -and $root.StartsWith($profile.ProfilePath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $root='%CSIDL_PROFILE%'+$root.Substring($profile.ProfilePath.TrimEnd('\').Length) }
            foreach ($cache in @('Cache','Code Cache','GPUCache','cache2','startupCache','shader-cache','Service Worker\CacheStorage')) {
                foreach ($suffix in @(('\'+$cache),('\*\'+$cache))) { Add-SfsuXmlPattern $document $objects File ($root+$suffix+'\* [*]') }
            }
            if ($context -eq 'User') {
                if ($browser.Browser -notin @('Edge','Chrome','Firefox')) { throw 'Custom browser roots must identify Edge, Chrome or Firefox.' }
                $include=$document.CreateElement('include'); [void]$rules.AppendChild($include)
                $files=$document.CreateElement('objectSet'); [void]$include.AppendChild($files)
                $names=@('Bookmarks','Bookmarks.bak','History','History-wal','History-shm')
                if ($browser.Browser -eq 'Firefox') { $names=@('places.sqlite','places.sqlite-wal','places.sqlite-shm','favicons.sqlite','favicons.sqlite-wal','favicons.sqlite-shm') }
                foreach ($name in $names) { Add-SfsuXmlPattern $document $files File ($root+' ['+$name+']'); Add-SfsuXmlPattern $document $files File ($root+'\* ['+$name+']') }
                if ($browser.Browser -eq 'Firefox') { Add-SfsuXmlPattern $document $files File ($root+'\*\bookmarkbackups [*]'); Add-SfsuXmlPattern $document $files File ($root+'\*\bookmarkbackups\* [*]') }
            }
        }
        if ($context -eq 'User') {
            $include=$document.CreateElement('include'); [void]$rules.AppendChild($include); $files=$document.CreateElement('objectSet'); [void]$include.AppendChild($files)
            foreach ($name in @('profiles.ini','installs.ini')) { Add-SfsuXmlPattern $document $files File ('%CSIDL_APPDATA%\Mozilla\Firefox ['+$name+']') }
        }
    }
    Write-SfsuAtomicText $Path $document.OuterXml
    [pscustomobject]@{Version=$script:PolicyVersion;CloudRoots=@($cloud | Sort-Object -Unique);BrowserRoots=$browserRoots;AssumesCloudUploadsComplete=$true;Efs='copyraw';EncryptedStore=$false}
}

function Set-SfsuGeneratedConfig([string]$Path) {
    $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing='Prohibit'; $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($Path,$settings)
    $document=New-Object Xml.XmlDocument; $document.XmlResolver=$null
    try { $document.Load($reader) } finally { $reader.Dispose() }
    if ($document.DocumentElement.Name -ne 'Configuration') { throw 'USMT did not generate a Configuration document.' }
    $defender=0; $crypto=@{}
    foreach ($component in $document.SelectNodes('//component')) {
        $text=$component.GetAttribute('ID')+' '+$component.GetAttribute('displayname')
        if ($text -match '(?i)defender|antimalware') { $component.SetAttribute('migrate','no'); $defender++ }
        foreach ($name in @('capi2-certs','crypto-keys','dpapi-keys')) {
            if ($text -match [regex]::Escape($name)) {
                $crypto[$name]=$true; $node=$component
                while ($node -is [Xml.XmlElement] -and $node.Name -eq 'component') { $node.SetAttribute('migrate','yes'); $node=$node.ParentNode }
            }
        }
    }
    if ($crypto.Count -ne 3) { throw 'Generated USMT configuration lacks required user certificate/private-key/DPAPI components. Capture is stopped to protect EFS recoverability.' }
    # /c continues native nonfatal errors; disk-full errors remain fatal. Every
    # bypassed error is retained and prevents a clean-success/reimage claim.
    $policies=$document.SelectSingleNode('/Configuration/Policies')
    if (-not $policies) { $policies=$document.CreateElement('Policies'); [void]$document.DocumentElement.AppendChild($policies) }
    $old=$policies.SelectSingleNode('ErrorControl'); if ($old) { [void]$old.ParentNode.RemoveChild($old) }
    $errors=$document.CreateElement('ErrorControl'); [void]$policies.AppendChild($errors)
    $fileError=$document.CreateElement('fileError'); [void]$errors.AppendChild($fileError)
    foreach ($code in @('112','39')) { $fatal=$document.CreateElement('fatal'); $fatal.SetAttribute('errorCode',$code); $fatal.InnerText='* [*]'; [void]$fileError.AppendChild($fatal) }
    Write-SfsuAtomicText $Path $document.OuterXml
    $defender
}

Export-ModuleMember -Function Get-SfsuLocationReview,New-SfsuMigrationPolicy,Set-SfsuGeneratedConfig,Expand-SfsuProfileLocation
