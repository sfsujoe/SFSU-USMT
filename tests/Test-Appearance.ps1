# Synthetic appearance/persistence/UI checks. No live profiles, LDAP or migration.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/appearance-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
foreach ($source in Get-ChildItem (Join-Path $repository 'App/Scripts') -File) { Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $testRoot 'App/Scripts') }
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Assets'))
Copy-Item -LiteralPath (Join-Path $repository 'App/Assets/SFSU Logo.png') -Destination (Join-Path $testRoot 'App/Assets')
Import-Module (Join-Path $testRoot 'App/Scripts/Sfsu.Appearance.psm1') -Force
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert-True $caught $Message }
function Get-Luminance($Color) {
    $channels=@($Color.R,$Color.G,$Color.B) | ForEach-Object { $value=$_/255.0; if ($value -le 0.04045) { $value/12.92 } else { [Math]::Pow(($value+0.055)/1.055,2.4) } }
    0.2126*$channels[0]+0.7152*$channels[1]+0.0722*$channels[2]
}
function Get-Contrast($A,$B) { $aLum=Get-Luminance $A; $bLum=Get-Luminance $B; ([Math]::Max($aLum,$bLum)+0.05)/([Math]::Min($aLum,$bLum)+0.05) }
function Save-FormImage($Form,[string]$Name) {
    $bitmap=New-Object Drawing.Bitmap($Form.Width,$Form.Height)
    try { $Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot $Name)) } finally { $bitmap.Dispose() }
}
function Get-AllControls($Parent) { foreach ($child in $Parent.Controls) { $child; Get-AllControls $child } }

$preference=Read-SfsuAppearancePreference $testRoot
Assert-True ($preference.ThemeId -eq 'Classic' -and -not $preference.Warning) 'An absent preference defaults to Classic.'
Assert-True (-not (Test-Path (Join-Path $testRoot 'App/Settings'))) 'Reading defaults creates no file or directory.'
Assert-Throws { Save-SfsuAppearancePreference $testRoot 'Unknown' } 'Unknown theme saves are rejected.'
$path=Join-Path $testRoot 'App/Settings/appearance.json'
foreach ($theme in @(Get-SfsuThemeCatalog)) {
    Save-SfsuAppearancePreference $testRoot $theme.Id
    Assert-True ((Read-SfsuAppearancePreference $testRoot).ThemeId -ceq $theme.Id) ('Preference round trip: '+$theme.Id)
    $data=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    Assert-True (@($data.PSObject.Properties.Name).Count -eq 3 -and $data.SchemaVersion -eq 1 -and $data.TextScale -eq 100) 'Settings contain only version, theme ID, and text size.'
    if ($theme.Id -ne 'System') {
        $p=Get-SfsuThemePalette $theme.Id $false
        foreach ($pair in @(@('Foreground','Background'),@('Foreground','Surface'),@('WarningText','Warning'),@('HeaderText','Header'),@('Title','Header'),@('AccentText','Accent'))) {
            Assert-True ((Get-Contrast $p.($pair[0]) $p.($pair[1])) -ge 4.5) ($theme.Id+' text contrast '+($pair -join '/'))
        }
        foreach ($surface in @('Background','Surface')) { Assert-True ((Get-Contrast $p.Border $p.$surface) -ge 3.0) ($theme.Id+' control boundary contrast on '+$surface) }
    }
}
Assert-True (@(Get-ChildItem (Split-Path $path) -Force).Count -eq 1) 'Successful saves leave only appearance.json in toolkit settings.'
foreach ($invalid in @('{bad','{"SchemaVersion":2,"ThemeId":"Dark"}','{"SchemaVersion":1,"ThemeId":"Unexpected"}','{"SchemaVersion":1,"ThemeId":"Dark","TextScale":999}',('x'*4097))) {
    [IO.File]::WriteAllText($path,$invalid)
    $read=Read-SfsuAppearancePreference $testRoot
    Assert-True ($read.ThemeId -eq 'Classic' -and $read.Warning) 'Malformed/unknown/oversized settings fall back safely.'
}
Save-SfsuAppearancePreference $testRoot 'Dark'
foreach ($scale in @(125,150,200)) {
    Save-SfsuAppearancePreference $testRoot Dark $scale
    Assert-True ((Read-SfsuAppearancePreference $testRoot).TextScale -eq $scale) 'Shared text size round trips without a local setting.'
}
Assert-Throws { Save-SfsuAppearancePreference $testRoot Dark 999 } 'Unsupported text size is rejected.'
Save-SfsuAppearancePreference $testRoot Dark
$hash=(Get-FileHash $path).Hash
$held=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try { Assert-Throws { Save-SfsuAppearancePreference $testRoot 'Ocean' } 'A write failure is surfaced instead of writing a local preference.' } finally { $held.Dispose() }
Assert-True ((Get-FileHash $path).Hash -eq $hash) 'A denied save preserves the existing preference.'
Assert-True (@(Get-ChildItem (Split-Path $path) -Force).Count -eq 1) 'Failed saves clean temporary and lock files.'
$held=New-Object IO.FileStream((Join-Path (Split-Path $path) 'appearance.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
try { Assert-Throws { Save-SfsuAppearancePreference $testRoot 'Forest' } 'Concurrent shared saves have bounded lock handling.' } finally { $held.Dispose() }
Assert-True ((Read-SfsuAppearancePreference $testRoot).ThemeId -eq 'Dark') 'A concurrent blocked save leaves the current preference intact.'

# Reuse the real writer with a synthetic unsupported Replace call, as encountered
# by the earlier reporting share test. All paths stay under this isolated package.
$faultSource=[IO.File]::ReadAllText((Join-Path $testRoot 'App/Scripts/Sfsu.Appearance.psm1')).Replace('[IO.File]::Replace($temporary,$path,[NullString]::Value)','Invoke-SyntheticReplace')
$faultSource+="`r`nfunction Invoke-SyntheticReplace { throw (New-Object UnauthorizedAccessException('Synthetic share Replace denial.')) }`r`n"
$faultPath=Join-Path $testRoot 'AppearanceFaultFixture.psm1'; [IO.File]::WriteAllText($faultPath,$faultSource)
$faultModule=Import-Module $faultPath -Force -PassThru
$faultRoot=Join-Path $testRoot 'fallback-package'
& $faultModule { param($root) Save-SfsuAppearancePreference $root Classic; Save-SfsuAppearancePreference $root Ocean } $faultRoot
Assert-True ((Read-SfsuAppearancePreference $faultRoot).ThemeId -eq 'Ocean') 'A share-style Replace denial falls back to a successful toolkit-only overwrite.'
Assert-True (@(Get-ChildItem (Join-Path $faultRoot 'App/Settings') -Force).Count -eq 1) 'The replacement fallback cleans its temporary and lock files.'
Remove-Module $faultModule

$probePath=Join-Path $testRoot 'ReadTheme.ps1'
[IO.File]::WriteAllText($probePath,@'
param([string]$Root)
$form=. (Join-Path $Root 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
try { Write-Output ('Theme='+$script:SfsuUi.ThemeId); Write-Output ('Scale='+$script:SfsuUi.TextScale) } finally { $form.Dispose() }
'@)
$freshOutput=& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $probePath -Root $testRoot
Assert-True ($LASTEXITCODE -eq 0 -and $freshOutput -contains 'Theme=Dark') 'A separate app process loads the saved shared theme.'

$main=. (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
$main.ShowInTaskbar=$false; $main.StartPosition='Manual'; $main.Location=New-Object Drawing.Point(-30000,-30000)
$main.Show(); [Windows.Forms.Application]::DoEvents(); $script:SfsuUi.AppearanceTimer.Stop()
try {
    Assert-True ($script:SfsuUi.ThemeId -eq 'Dark' -and $main.BackColor -eq (Get-SfsuThemePalette Dark $false).Background) 'The saved toolkit preference is applied before startup authentication.'
    Assert-True ($script:SfsuUi.ChooseTheme.Visible -and $script:SfsuUi.ChooseTheme.Right -gt $script:SfsuUi.Cancel.Right -and $chooseTheme.Text -ceq 'Theme & Font' -and -not $chooseTheme.UseMnemonic) 'Theme & Font displays its literal ampersand at the right of the footer.'
    Assert-True ($main.Text -eq 'SFSU User State Migration Tool' -and $title.Text -eq $main.Text) 'Window and header use the requested tool title.'
    Assert-True ($subtitle -is [Windows.Forms.LinkLabel] -and $subtitle.Text -eq 'By Academic Technology at SF State' -and $subtitle.Links[0].LinkData -ceq 'https://at.sfsu.edu/' -and $subtitle.TabStop) 'The attribution is an accurately targeted keyboard-accessible link.'
    $script:OpenedAtUrl=''
    function Start-Process { param($FilePath,$ErrorAction) $script:OpenedAtUrl=$FilePath }
    try {
        $linkEvent=New-Object Windows.Forms.LinkLabelLinkClickedEventArgs($subtitle.Links[0])
        $linkMethod=[Windows.Forms.LinkLabel].GetMethod('OnLinkClicked',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$linkMethod.Invoke($subtitle.PSObject.BaseObject,[object[]]@($linkEvent.PSObject.BaseObject))
        Assert-True ($script:OpenedAtUrl -ceq 'https://at.sfsu.edu/' -and $subtitle.Links[0].Visited) 'Activating the attribution opens the intended browser target without a real browser launch in tests.'
    } finally { Remove-Item function:Start-Process }
    Assert-True (-not ((Get-AllControls $main | Where-Object { $_ -is [Windows.Forms.Label] }).Text -match '^Theme:')) 'The main screen has no chosen-theme label.'
    Assert-True ($profiles.StandardTab -and $backups.StandardTab -and $profiles.AccessibleName -and $backups.AccessibleName) 'Tables have accessible names and Tab exits the grid.'
    $status.Text='Synthetic task completed.'
    Assert-True ($status.AccessibleName -eq $status.Text -and $status.AccessibleRole -eq 'StatusBar' -and $status.LiveSetting -eq 'Polite') 'Status changes expose current text and polite live-region semantics.'
    $profile=[pscustomobject]@{AccountType='Domain';AccountName='p000000123';SfsuId='p000000123';SfsuIdSource='LDAP';SfsuIdAttribute='sAMAccountName';ManualConfirmed=$false;DisplayName='Synthetic Power User';ProfilePath='C:\Users\p000000123';ProfileSid='S-1-5-21-1-2-3-1001';DirectorySid='S-1-5-21-1-2-3-1001';SamAccountName='p000000123';IdentitySource='LDAP';IdentityStatus='Directory verified';VerifiedAtUtc='2026-11-01T12:00:00Z'}
    $manual=$profile.PSObject.Copy(); $manual.IdentitySource='Manual'; $manual.IdentityStatus='Manually entered (confirmed)'
    Set-SfsuProfileRows @($profile,$manual)
    Assert-True ($profiles.Rows[0].Cells['Verified'].Value -match 'AD verified') 'Verification has readable text alongside the symbol.'
    $profiles.CurrentCell=$profiles.Rows[0].Cells['DisplayName']
    $sortKey=New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::F3)
    $keyMethod=[Windows.Forms.Control].GetMethod('OnKeyDown',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$keyMethod.Invoke($profiles.PSObject.BaseObject,[object[]]@($sortKey.PSObject.BaseObject))
    Assert-True ($profiles.SortedColumn.Name -eq 'DisplayName' -and $sortKey.Handled) 'F3 sorts a text column without requiring a mouse.'
    foreach ($theme in @(Get-SfsuThemeCatalog)) {
        $script:SfsuUi.ThemeId=$theme.Id
        Update-SfsuAppearance -Palette (Get-SfsuThemePalette $theme.Id $false)
        $palette=$script:SfsuUi.Palette
        Assert-True ($subtitle.LinkColor -eq $palette.HeaderText -and $subtitle.VisitedLinkColor -eq $palette.HeaderText -and $subtitle.LinkBehavior -eq 'AlwaysUnderline') 'Attribution stays readable and underlined in each theme.'
        Assert-True ($profiles.DefaultCellStyle.ForeColor -eq $palette.Foreground -and $profiles.DefaultCellStyle.SelectionForeColor -eq $palette.AccentText) 'Grid foreground and selection colors follow the palette.'
        Assert-True ($profiles.Rows[1].DefaultCellStyle.BackColor -eq $palette.Warning -and $profiles.Rows[1].DefaultCellStyle.ForeColor -eq $palette.WarningText) 'Manual rows retain explicit foreground/background pairs.'
        Save-FormImage $main ('main-'+$theme.Id+'.png')
        $auth=New-SfsuAuthenticationDialog
        try {
            $auth.ShowInTaskbar=$false; $auth.StartPosition='Manual'; $auth.Location=New-Object Drawing.Point(-30000,-30000); $auth.Show(); [Windows.Forms.Application]::DoEvents()
            Assert-True ($auth.BackColor -eq $palette.Background -and $auth.Tag.User.BackColor -eq $palette.Background) 'Authentication and input colors match the main window.'
            Assert-True ($auth.Tag.User.AccessibleName -and $auth.Tag.Password.AccessibleName -and $auth.Tag.User.TabIndex -lt $auth.Tag.Password.TabIndex) 'Credential inputs have labels and logical tab order.'
            $auth.Font=New-Object Drawing.Font('Segoe UI',20)
            $auth.ClientSize=New-Object Drawing.Size(640,$auth.ClientSize.Height)
            Update-SfsuDialogLayout $auth
            Assert-True ($auth.Tag.Heading.Font.Bold -and $auth.Tag.Heading.Font.SizeInPoints -gt 20) 'The emphasized instruction follows enlarged dialog fonts.'
            $controls=@($auth.SfsuLayout.Rows | ForEach-Object Control)
            $overlap=$false
            for ($i=1;$i -lt $controls.Count;$i++) { if ($controls[$i].Top -lt $controls[$i-1].Bottom) { $overlap=$true } }
            Assert-True (-not $overlap -and $auth.AutoScroll) 'Authentication rows reflow at 200 percent font size without overlap.'
            Assert-True (@($auth.Controls | Where-Object { $_.Right -gt $auth.ClientSize.Width-14 }).Count -eq 0) 'Large-text dialog controls retain a visible right margin.'
            Save-FormImage $auth ('authentication-'+$theme.Id+'-large.png')
        } finally { $auth.Dispose() }
    }
    $script:SfsuUi.ThemeId='Dark'; Update-SfsuAppearance
    $chooser=New-SfsuThemeDialog
    try {
        $chooser.ShowInTaskbar=$false; $chooser.StartPosition='Manual'; $chooser.Location=New-Object Drawing.Point(-30000,-30000)
        $cancelDriver=New-Object Windows.Forms.Timer; $cancelDriver.Interval=50
        $cancelDriver.Add_Tick({
            $cancelDriver.Stop(); $chooser.Tag.Choice.SelectedIndex=1
            $chooser.Tag.TextSize.SelectedIndex=3
            $script:PreviewSeen=$script:SfsuUi.PreviewTheme -eq 'Ocean' -and $main.BackColor -eq (Get-SfsuThemePalette Ocean $false).Background
            $chooser.Tag.Cancel.PerformClick()
        })
        $cancelDriver.Start()
        try { $cancelResult=$chooser.ShowDialog($main) } finally { $cancelDriver.Dispose() }
        Assert-True $script:PreviewSeen 'The chooser previews on the main window.'
        Assert-True ($cancelResult -eq 'Cancel' -and -not $script:SfsuUi.PreviewTheme -and -not $script:SfsuUi.PreviewTextScale -and $main.Font.SizeInPoints -eq 10 -and $script:SfsuUi.ThemeId -eq 'Dark' -and (Read-SfsuAppearancePreference $testRoot).ThemeId -eq 'Dark') 'Modal Cancel/escape-button wiring restores theme and text size without saving the preview.'
    } finally { $chooser.Dispose() }
    $chooser=New-SfsuThemeDialog
    $chooser.ShowInTaskbar=$false; $chooser.Location=New-Object Drawing.Point(-30000,-30000)
    try {
        $chooser.Show(); [Windows.Forms.Application]::DoEvents()
        $chooser.Tag.Choice.SelectedIndex=2
        $chooser.Tag.Apply.PerformClick()
        Assert-True ($script:SfsuUi.ThemeId -eq 'Forest' -and (Read-SfsuAppearancePreference $testRoot).ThemeId -eq 'Forest') 'Use theme saves the shared preference and applies it.'
    } finally { $chooser.Dispose() }
    $chooser=New-SfsuThemeDialog
    try {
        $chooser.ShowInTaskbar=$false; $chooser.Show(); [Windows.Forms.Application]::DoEvents(); $chooser.Tag.Choice.SelectedIndex=4
        $held=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $chooser.Tag.Apply.PerformClick() } finally { $held.Dispose() }
        Assert-True ($chooser.Visible -and $chooser.Tag.Error.Text -match 'could not be saved' -and $script:SfsuUi.ThemeId -eq 'Forest') 'A failed save leaves the dialog open with a readable error and unchanged saved choice.'
        Assert-True (@($chooser.Controls | Where-Object { $_.Right -gt $chooser.ClientSize.Width-14 }).Count -eq 0) 'The chooser retains a right margin after reflow.'
        Save-FormImage $chooser 'theme-save-error.png'
        $chooser.Close()
    } finally { $chooser.Dispose() }
    $chooser=New-SfsuThemeDialog
    try {
        $auth=New-SfsuAuthenticationDialog
        try {
            Update-SfsuAppearance -Palette (Get-SfsuThemePalette Dark $true)
            Assert-True ($main.BackColor -eq [Drawing.SystemColors]::Window -and $auth.BackColor -eq [Drawing.SystemColors]::Window -and $chooser.BackColor -eq [Drawing.SystemColors]::Window) 'High contrast overrides every open toolkit form using actual system colors.'
            Assert-True ($profiles.Rows[1].DefaultCellStyle.BackColor -eq [Drawing.SystemColors]::Window -and $profiles.Columns['Verified'].DefaultCellStyle.ForeColor -eq [Drawing.SystemColors]::WindowText) 'High contrast removes hard-coded warning and verification colors.'
            Assert-True ($tabs.DrawMode -eq 'Normal' -and -not $logoBox.Visible -and $textLogo.Visible) 'High contrast restores native tabs and provides readable text branding.'
            Assert-True ($chooser.Tag.Contrast.Text -match 'contrast mode' -and (Read-SfsuAppearancePreference $testRoot).ThemeId -eq 'Forest') 'High contrast explains the override only in the chooser without changing the preference.'
            Save-FormImage $main 'system-contrast-colors.png'
            Update-SfsuAppearance -Palette (Get-SfsuThemePalette Forest $false)
            Assert-True ($main.BackColor -eq (Get-SfsuThemePalette Forest $false).Background -and $tabs.DrawMode -eq 'OwnerDrawFixed') 'Leaving high contrast restores the selected app palette.'
        } finally { $auth.Dispose() }
    } finally { $chooser.Dispose() }
    Assert-True ($script:SfsuUi.Dialogs.Count -eq 0) 'Disposed dialogs release their theme tracking.'
    $main.ClientSize=New-Object Drawing.Size(760,560); $main.PerformLayout(); [Windows.Forms.Application]::DoEvents()
    Assert-True ($chooseTheme.Visible -and $chooseTheme.Right -le $footer.ClientSize.Width -and $prepare.Visible -and $profiles.Height -gt 0) 'Main actions wrap and the theme chooser remains reachable at the minimum window size.'
    Save-FormImage $main 'main-minimum.png'
    $main.Font=New-Object Drawing.Font('Segoe UI',20); $main.ClientSize=New-Object Drawing.Size(1120,850); $main.PerformLayout(); [Windows.Forms.Application]::DoEvents()
    Assert-True ($profiles.RowTemplate.Height -gt 0 -and $profiles.Rows[0].Height -ge $profiles.Font.Height+12 -and $chooseTheme.Visible) 'Main grid rows grow with text and the theme chooser stays visible at 200 percent font size.'
    Assert-True ($profiles.Columns['SfsuId'].Width -ge 250 -and -not $profiles.Columns['DisplayName'].Frozen) 'Large-text columns grow while later identity columns remain horizontally reachable.'
    Save-FormImage $main 'main-large-text.png'
    # Programmatic mnemonic routing exercises the same Alt+T handler as the keyboard.
    $script:ThemeShortcutSeen=$false; $savedChooser=${function:Show-SfsuThemeChooser}
    function Show-SfsuThemeChooser { $script:ThemeShortcutSeen=$true }
    try {
        $key=New-Object Windows.Forms.KeyEventArgs([Windows.Forms.Keys]::Alt -bor [Windows.Forms.Keys]::T)
        $method=[Windows.Forms.Control].GetMethod('OnKeyDown',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$method.Invoke($main.PSObject.BaseObject,[object[]]@($key.PSObject.BaseObject))
        Assert-True ($script:ThemeShortcutSeen -and $key.Handled) 'Alt+T activates the theme chooser.'
    } finally { Set-Item function:Show-SfsuThemeChooser $savedChooser }
    # The actual chooser drives text scaling, not just a programmatic font test.
    $main.Font=New-Object Drawing.Font('Segoe UI',10)
    Update-SfsuAppearance
    $chooser=New-SfsuThemeDialog
    try {
        $chooser.ShowInTaskbar=$false; $chooser.StartPosition='Manual'; $chooser.Location=New-Object Drawing.Point(-30000,-30000); $chooser.Show(); [Windows.Forms.Application]::DoEvents()
        $chooser.Tag.TextSize.SelectedIndex=3
        Assert-True ($main.Font.SizeInPoints -eq 20 -and $chooser.Font.SizeInPoints -eq 20 -and $chooser.AutoScroll) 'The chooser offers a usable 200 percent text preview on all forms.'
        Save-FormImage $chooser 'theme-large-text.png'
        $chooser.Tag.Apply.PerformClick()
        Assert-True ((Read-SfsuAppearancePreference $testRoot).TextScale -eq 200 -and $script:SfsuUi.TextScale -eq 200) 'Use theme also persists the selected shared text size.'
    } finally { $chooser.Dispose() }
    $freshOutput=& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $probePath -Root $testRoot
    Assert-True ($LASTEXITCODE -eq 0 -and $freshOutput -contains 'Scale=200') 'A separate app process also loads the saved 200 percent text size.'
    $main.ClientSize=New-Object Drawing.Size(760,560); $main.PerformLayout(); [Windows.Forms.Application]::DoEvents()
    Assert-True ($main.VerticalScroll.Visible -and $profiles.Height -ge 100) 'At minimum size with 200 percent text, the main window scrolls instead of collapsing its data grid.'
    $main.AutoScrollPosition=New-Object Drawing.Point(0,0)
    Save-FormImage $main 'main-minimum-large-text.png'
    $manualDriver=New-Object Windows.Forms.Timer; $manualDriver.Interval=50
    $script:ManualDialogChecks=$false
    $manualDriver.Add_Tick({
        $window=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assign Display Name')
        if (-not $window.Count) { return }
        $manualDriver.Stop(); $dialogWindow=$window[0]
        $confirm=@($dialogWindow.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] })[0]
        $script:ManualDialogChecks=$dialogWindow.Font.SizeInPoints -eq 20 -and $confirm.Height -ge $confirm.Font.Height*2
        Save-FormImage $dialogWindow 'manual-name-large-text.png'
        $dialogWindow.CancelButton.PerformClick()
    })
    $manualDriver.Start()
    try { Show-SfsuManualIdentity } finally { $manualDriver.Dispose() }
    Assert-True $script:ManualDialogChecks 'Manual name confirmation remains readable with the saved 200 percent text size.'
} finally { $main.Dispose() }
Assert-True (-not $script:SfsuUi.AppearanceTimer.Enabled) 'Closing the main form stops appearance monitoring.'
Assert-True (@(Get-ChildItem (Join-Path $testRoot 'App/Settings') -Force).Count -eq 1) 'All preference artifacts stay inside the toolkit settings directory.'
Write-Output ("PASS: $script:Assertions assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
