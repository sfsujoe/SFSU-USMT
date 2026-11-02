# Loaded by Start-SfsuUsmt.ps1. UI tasks run in a separate PowerShell runspace.
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Inventory.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Appearance.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$appearancePreference=Read-SfsuAppearancePreference $packageRoot
$script:SfsuUi = @{ Root=$packageRoot; Worker=$null; Pending=$null; Credential=$null; UseDirectory=$false; LatestReport=''; CloseWhenDone=$false; Cancelled=$false; Logo=$null
    ThemeId=$appearancePreference.ThemeId; TextScale=$appearancePreference.TextScale; PreferenceWarning=$appearancePreference.Warning; PreviewTheme=''; PreviewTextScale=0; Palette=$null; AppearanceSignature=''
    Dialogs=(New-Object 'Collections.Generic.List[Windows.Forms.Form]'); GridFontScale=0
    MainLayout=[pscustomobject]@{Interactive=$false;Busy=$false;Signature=''} }

function Update-SfsuAppearance {
    param($Palette=$null)
    $textScale=$script:SfsuUi.TextScale
    if ($script:SfsuUi.PreviewTextScale) { $textScale=$script:SfsuUi.PreviewTextScale }
    if ([Math]::Abs($script:SfsuUi.Form.Font.SizeInPoints-(10*$textScale/100.0)) -gt 0.01) {
        $oldFont=$script:SfsuUi.Form.Font
        $newFont=New-Object Drawing.Font('Segoe UI',([single](10*$textScale/100.0)))
        $script:SfsuUi.Form.Font=$newFont
        foreach ($openDialog in $script:SfsuUi.Dialogs.ToArray()) { if (-not $openDialog.IsDisposed) { $openDialog.Font=$newFont } }
        $oldFont.Dispose()
    }
    $theme=$script:SfsuUi.ThemeId
    if ($script:SfsuUi.PreviewTheme) { $theme=$script:SfsuUi.PreviewTheme }
    if ($null -eq $Palette) { $Palette=Get-SfsuThemePalette $theme }
    $script:SfsuUi.Palette=$Palette
    Set-SfsuControlPalette $script:SfsuUi.Form $Palette
    foreach ($dialog in @($script:SfsuUi.Dialogs.ToArray())) {
        if (-not $dialog.IsDisposed) {
            Set-SfsuControlPalette $dialog $Palette
            if ($dialog.Name -eq 'ThemeChooser') {
                $dialog.Tag.Contrast.Text=''
                if ($Palette.HighContrast) { $dialog.Tag.Contrast.Text='Windows contrast mode is active. Your chosen theme will appear when it is turned off.' }
                Update-SfsuDialogLayout $dialog
            }
        }
    }
}

function Register-SfsuThemedDialog($Dialog) {
    $script:SfsuUi.Dialogs.Add($Dialog)
    $Dialog.Add_SystemColorsChanged({ Update-SfsuAppearance })
    $Dialog.Add_Disposed({param($sender,$event) [void]$script:SfsuUi.Dialogs.Remove($sender)})
    Set-SfsuControlPalette $Dialog $script:SfsuUi.Palette
}

function New-SfsuThemeDialog {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Name='ThemeChooser'; $dialog.Text='Theme & Font'; $dialog.ClientSize=New-Object Drawing.Size(570,430)
    $dialog.StartPosition='CenterParent'; $dialog.Font=$script:SfsuUi.Form.Font; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $label=New-Object Windows.Forms.Label; $label.Text='&Theme'; $dialog.Controls.Add($label)
    $choice=New-Object Windows.Forms.ComboBox; $choice.Name='ThemeChoice'; $choice.DropDownStyle='DropDownList'
    $choice.DrawMode='OwnerDrawFixed'
    $choice.Add_DrawItem({
        param($sender,$event)
        $palette=$script:SfsuUi.Palette
        $bg=$palette.Background; $fg=$palette.Foreground
        if ($event.State -band [Windows.Forms.DrawItemState]::Selected) { $bg=$palette.Accent; $fg=$palette.AccentText }
        $brush=New-Object Drawing.SolidBrush($bg)
        try { $event.Graphics.FillRectangle($brush,$event.Bounds) } finally { $brush.Dispose() }
        if ($event.Index -ge 0) { [Windows.Forms.TextRenderer]::DrawText($event.Graphics,[string]$sender.Items[$event.Index],$sender.Font,$event.Bounds,$fg,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter)) }
        if ($event.State -band [Windows.Forms.DrawItemState]::Focus) { [Windows.Forms.ControlPaint]::DrawFocusRectangle($event.Graphics,$event.Bounds,$fg,$bg) }
    })
    $choice.Add_FontChanged({param($sender,$event) $sender.ItemHeight=$sender.Font.Height+6})
    $choice.ItemHeight=$choice.Font.Height+6
    $choice.AccessibleName='Theme'; $choice.AccessibleDescription='Shared toolkit appearance. Use arrow keys to preview; choose Use theme to save.'
    $catalog=@(Get-SfsuThemeCatalog)
    foreach ($theme in $catalog) { [void]$choice.Items.Add($theme.Name) }
    $choice.SelectedIndex=[array]::IndexOf(@($catalog | ForEach-Object Id),$script:SfsuUi.ThemeId)
    $dialog.Controls.Add($choice)
    $sizeLabel=New-Object Windows.Forms.Label; $sizeLabel.Text='Text &size'; $dialog.Controls.Add($sizeLabel)
    $sizeChoice=New-Object Windows.Forms.ComboBox; $sizeChoice.Name='TextSizeChoice'; $sizeChoice.DropDownStyle='DropDownList'; $sizeChoice.AccessibleName='Text size'
    $sizeChoice.AccessibleDescription='Shared toolkit text size. Use arrow keys to preview.'
    foreach ($value in @('100%','125%','150%','200%')) { [void]$sizeChoice.Items.Add($value) }
    $sizeChoice.SelectedIndex=[array]::IndexOf(@(100,125,150,200),$script:SfsuUi.TextScale)
    $sizeChoice.DrawMode='OwnerDrawFixed'; $sizeChoice.ItemHeight=$sizeChoice.Font.Height+6
    # Both selectors use the same native owner-draw treatment in custom themes.
    $sizeChoice.Add_DrawItem({
        param($sender,$event)
        $palette=$script:SfsuUi.Palette; $bg=$palette.Background; $fg=$palette.Foreground
        if ($event.State -band [Windows.Forms.DrawItemState]::Selected) { $bg=$palette.Accent; $fg=$palette.AccentText }
        $brush=New-Object Drawing.SolidBrush($bg)
        try { $event.Graphics.FillRectangle($brush,$event.Bounds) } finally { $brush.Dispose() }
        if ($event.Index -ge 0) { [Windows.Forms.TextRenderer]::DrawText($event.Graphics,[string]$sender.Items[$event.Index],$sender.Font,$event.Bounds,$fg,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter)) }
        if ($event.State -band [Windows.Forms.DrawItemState]::Focus) { [Windows.Forms.ControlPaint]::DrawFocusRectangle($event.Graphics,$event.Bounds,$fg,$bg) }
    })
    $sizeChoice.Add_FontChanged({param($sender,$event) $sender.ItemHeight=$sender.Font.Height+6})
    $dialog.Controls.Add($sizeChoice)
    $preview=New-Object Windows.Forms.Panel; $preview.Name='ThemeHeader'; $dialog.Controls.Add($preview)
    $previewTitle=New-Object Windows.Forms.Label; $previewTitle.Name='ThemeTitle'; $previewTitle.Text='SFSU User State Migration Tool'; $previewTitle.Dock='Fill'; $previewTitle.TextAlign='MiddleCenter'; $preview.Controls.Add($previewTitle)
    $description=New-Object Windows.Forms.Label
    $description.Text='This choice is shared by all technicians using this toolkit. Windows contrast settings always take priority.'; $dialog.Controls.Add($description)
    $contrast=New-Object Windows.Forms.Label; $dialog.Controls.Add($contrast)
    $errorLabel=New-Object Windows.Forms.Label; $dialog.Controls.Add($errorLabel); Initialize-SfsuAccessibleStatus $errorLabel 'Alert'
    $cancel=New-SfsuButton $dialog 'Cancel' 0 120; $cancel.DialogResult='Cancel'
    $apply=New-SfsuButton $dialog 'Use theme' 0 120; $apply.Name='PrimaryAction'
    $dialog.AcceptButton=$apply; $dialog.CancelButton=$cancel
    $dialog.Tag=[pscustomobject]@{Choice=$choice;TextSize=$sizeChoice;Catalog=$catalog;Contrast=$contrast;Error=$errorLabel;Apply=$apply;Cancel=$cancel}
    Initialize-SfsuDialogLayout $dialog @(
        @{Control=$label;Kind='Label';Lines=1},@{Control=$choice;Kind='Input'},@{Control=$sizeLabel;Kind='Label';Lines=1},@{Control=$sizeChoice;Kind='Input'},@{Control=$preview;Kind='Preview'},
        @{Control=$description;Kind='Label';Lines=2},@{Control=$contrast;Kind='Label';Lines=1;HideWhenEmpty=$true},@{Control=$errorLabel;Kind='Label';Lines=1;HideWhenEmpty=$true}
    ) @($cancel,$apply)
    $choice.Add_SelectedIndexChanged({
        param($sender,$event)
        $s=$sender.FindForm().Tag; $script:SfsuUi.PreviewTheme=$s.Catalog[$sender.SelectedIndex].Id; $s.Error.Text=''; Update-SfsuAppearance
    })
    $sizeChoice.Add_SelectedIndexChanged({
        param($sender,$event)
        $script:SfsuUi.PreviewTextScale=@(100,125,150,200)[$sender.SelectedIndex]
        $sender.FindForm().Tag.Error.Text=''; Update-SfsuAppearance
    })
    $apply.Add_Click({
        param($sender,$event)
        $dialogWindow=$sender.FindForm(); $s=$dialogWindow.Tag; $id=$s.Catalog[$s.Choice.SelectedIndex].Id
        try {
            $scale=@(100,125,150,200)[$s.TextSize.SelectedIndex]
            Save-SfsuAppearancePreference -PackageRoot $script:SfsuUi.Root -ThemeId $id -TextScale $scale
            $script:SfsuUi.ThemeId=$id; $script:SfsuUi.TextScale=$scale; $script:SfsuUi.PreferenceWarning=''
            $dialogWindow.DialogResult='OK'; $dialogWindow.Close()
        } catch {
            $s.Error.Text='The theme could not be saved in the toolkit. Check write access or retry. No local preference was created.'
            $s.Error.AccessibleDescription=$_.Exception.Message
            Update-SfsuDialogLayout $dialogWindow
        }
    })
    $dialog.Add_FormClosing({$script:SfsuUi.PreviewTheme=''; $script:SfsuUi.PreviewTextScale=0; Update-SfsuAppearance})
    Register-SfsuThemedDialog $dialog
    if ($script:SfsuUi.Palette.HighContrast) { $contrast.Text='Windows contrast mode is active. Your chosen theme will appear when it is turned off.'; Update-SfsuDialogLayout $dialog }
    $dialog
}

function Show-SfsuThemeChooser {
    $dialog=New-SfsuThemeDialog
    try { [void]$dialog.ShowDialog($script:SfsuUi.Form) } finally { $script:SfsuUi.PreviewTheme=''; $script:SfsuUi.PreviewTextScale=0; $dialog.Dispose(); Update-SfsuAppearance }
    $script:SfsuUi.ChooseTheme.Focus() | Out-Null
}

function New-SfsuButton($Parent, [string]$Text, [int]$Left, [int]$Width, [int]$Top=12) {
    $control = New-Object Windows.Forms.Button
    $control.Text=$Text; $control.SetBounds($Left,$Top,$Width,34)
    $control.AccessibleName=$Text; $control.AutoSize=$true; $control.AutoSizeMode='GrowAndShrink'
    $control.MinimumSize=New-Object Drawing.Size($Width,34); $control.Padding=New-Object Windows.Forms.Padding(8,4,8,4)
    $control.Add_Paint({
        param($sender,$event)
        if ($sender.Enabled -or $null -eq $script:SfsuUi.Palette -or $script:SfsuUi.Palette.Native) { return }
        # Native disabled text can become black on a dark custom surface.
        # Preserve the native disabled state while repainting a readable label.
        $bounds=$sender.ClientRectangle; $bounds.Inflate(-2,-2)
        $brush=New-Object Drawing.SolidBrush($sender.BackColor)
        try { $event.Graphics.FillRectangle($brush,$bounds) } finally { $brush.Dispose() }
        $foreground=$script:SfsuUi.Palette.Border
        if ($sender.Name -eq 'PrimaryAction') { $foreground=$script:SfsuUi.Palette.AccentText }
        $flags=[Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter
        if (-not $sender.UseMnemonic) { $flags=$flags -bor [Windows.Forms.TextFormatFlags]::NoPrefix }
        [Windows.Forms.TextRenderer]::DrawText($event.Graphics,$sender.Text,$sender.Font,$bounds,$foreground,$flags)
    })
    $Parent.Controls.Add($control)
    $control
}

function New-SfsuGrid($Parent, [object[]]$Definitions) {
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'; $grid.BackgroundColor=[Drawing.Color]::White; $grid.BorderStyle='None'
    $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false
    $grid.AllowUserToResizeRows=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect'
    $grid.MultiSelect=$false; $grid.RowTemplate.Height=32; $grid.ColumnHeadersHeight=38
    $grid.AutoSizeRowsMode='AllCells'; $grid.ColumnHeadersHeightSizeMode='AutoSize'
    $grid.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(0,6,0,6)
    $grid.StandardTab=$true; $grid.AccessibleDescription='Use arrow keys to move between cells, Space to toggle Select, and Tab to leave the table. Column headers support sorting.'
    $grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#ECE8F5')
    foreach ($definition in $Definitions) {
        if ($definition.Id -eq 'Selected') { $column=New-Object Windows.Forms.DataGridViewCheckBoxColumn; $column.ReadOnly=$false; $column.SortMode='NotSortable' }
        else { $column=New-Object Windows.Forms.DataGridViewTextBoxColumn; $column.ReadOnly=$true; $column.SortMode='Automatic' }
        $column.Name=$definition.Id; $column.HeaderText=$definition.Title; $column.FillWeight=$definition.Weight
        $column.MinimumWidth=55
        [void]$grid.Columns.Add($column)
    }
    $grid.Add_CurrentCellDirtyStateChanged({
        param($sender,$event)
        if ($sender.IsCurrentCellDirty) { [void]$sender.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $grid.Add_KeyDown({
        param($sender,$event)
        if ($event.KeyCode -ne 'F3' -or $null -eq $sender.CurrentCell) { return }
        $column=$sender.Columns[$sender.CurrentCell.ColumnIndex]
        if ($column.SortMode -ne 'Automatic') { return }
        $direction=[ComponentModel.ListSortDirection]::Ascending
        if ($sender.SortedColumn -eq $column -and $sender.SortOrder -eq 'Ascending') { $direction=[ComponentModel.ListSortDirection]::Descending }
        $sender.Sort($column,$direction); $event.Handled=$true; $event.SuppressKeyPress=$true
    })
    $grid.AccessibleDescription+=' Press F3 to sort the current text column.'
    $Parent.Controls.Add($grid)
    $grid
}

function Test-SfsuProfileVerified($Profile) {
    $Profile.AccountType -eq 'Domain' -and $Profile.IdentitySource -eq 'LDAP' -and
        $Profile.IdentityStatus -eq 'Directory verified' -and $Profile.VerifiedAtUtc -and
        $Profile.DirectorySid -eq $Profile.ProfileSid -and $Profile.SfsuId -match '^p?\d{1,32}$' -and
        $Profile.SfsuId -ceq $Profile.SamAccountName -and $Profile.SfsuId -ceq (Split-Path $Profile.ProfilePath -Leaf) -and
        -not [string]::IsNullOrWhiteSpace($Profile.DisplayName)
}

function Set-SfsuProfileRows([object[]]$Profiles) {
    $grid=$script:SfsuUi.Profiles; $grid.Rows.Clear()
    foreach ($profile in $Profiles) {
        $idLabel=$profile.SfsuId
        if ($profile.AccountType -eq 'Local') { $idLabel='Local Account' }
        $verified=''
        if (Test-SfsuProfileVerified $profile) { $verified=([string][char]0x2705)+' AD verified' }
        $index=$grid.Rows.Add([object[]]@($false,$idLabel,$verified,$profile.DisplayName,$profile.ProfilePath,$profile.IdentityStatus,$profile.ProfileSid))
        $grid.Rows[$index].Tag=$profile
        $grid.Rows[$index].Cells['Sid'].ToolTipText=$profile.ProfileSid
        $verificationHint='Not verified against Active Directory.'
        if ($verified) { $verificationHint='AD verified: profile SID, SFSU ID, and display name.' }
        elseif ($profile.AccountType -eq 'Local') { $verificationHint='Local account; AD verification does not apply.' }
        elseif ($profile.IdentitySource -eq 'Manual') { $verificationHint='Display name assigned manually; not verified against AD.' }
        $grid.Rows[$index].Cells['Verified'].ToolTipText=$verificationHint
    }
    Set-SfsuControlPalette $grid $script:SfsuUi.Palette
}

function Set-SfsuBackupRows([object[]]$Backups) {
    $grid=$script:SfsuUi.Backups; $grid.Rows.Clear()
    foreach ($backup in $Backups) {
        $time=$null
        if ($backup.CreatedUtc -ne [DateTimeOffset]::MinValue) { $time=$backup.CreatedUtc.UtcDateTime }
        $idLabel=$backup.SfsuId
        if ($backup.AccountType -eq 'Local') { $idLabel='Local Account' }
        $index=$grid.Rows.Add([object[]]@($false,$idLabel,$backup.AccountName,$backup.DisplayName,$time,$backup.SourceComputer,$backup.Status,$backup.FormerName))
        $grid.Rows[$index].Tag=$backup
    }
    $grid.Sort($grid.Columns['Timestamp'],[ComponentModel.ListSortDirection]::Descending)
    Set-SfsuControlPalette $grid $script:SfsuUi.Palette
}

function Get-SfsuCheckedRows($Grid) {
    [void]$Grid.EndEdit()
    foreach ($row in $Grid.Rows) { if ($row.Cells['Selected'].Value -eq $true) { $row.Tag } }
}

function Show-SfsuMessage([string]$Text) {
    [void][Windows.Forms.MessageBox]::Show($script:SfsuUi.Form,$Text,'SFSU USMT','OK','Information')
}

function Start-SfsuUiTask([string]$Action, [object[]]$Items=@()) {
    if ($null -ne $script:SfsuUi.Worker) { return }
    if ($Action -eq 'Refresh current names' -and -not $script:SfsuUi.UseDirectory) { Show-SfsuDirectoryCredentials; return }
    $script:SfsuUi.Tabs.Enabled=$false; $script:SfsuUi.Cancel.Enabled=$true; $script:SfsuUi.Cancelled=$false
    $script:SfsuUi.Status.Text='Working: ' + $Action + '. You can cancel; interrupted work remains documented as incomplete.'
    $script:SfsuUi.Action=$Action
    $worker=[PowerShell]::Create()
    $task={
        param($root,$action,$items,$credential,$server,$useDirectory)
        $ErrorActionPreference='Stop'
        Import-Module (Join-Path $root 'App/Scripts/Sfsu.Logging.psm1') -Force
        Import-Module (Join-Path $root 'App/Scripts/Sfsu.Inventory.psm1') -Force
        switch ($action) {
            'Discover profiles' { Invoke-SfsuProfileDiscovery -PackageRoot $root -Server $server -Credential $credential -SkipDirectoryLookup:(-not $useDirectory) }
            'Prepare folders' { Invoke-SfsuBackupPreparation -PackageRoot $root -Profiles $items }
            'List backups' { Invoke-SfsuBackupInventory -PackageRoot $root }
            'Refresh current names' { Invoke-SfsuBackupInventory -PackageRoot $root -LookupNames -Server $server -Credential $credential }
            'Review restore selection' { Invoke-SfsuRestoreReview -PackageRoot $root -Backups $items }
        }
    }
    [void]$worker.AddScript($task.ToString()).AddArgument($script:SfsuUi.Root).AddArgument($Action).AddArgument($Items).AddArgument($script:SfsuUi.Credential).AddArgument($LdapServer).AddArgument($script:SfsuUi.UseDirectory)
    $script:SfsuUi.Worker=$worker
    try { $script:SfsuUi.Pending=$worker.BeginInvoke(); $script:SfsuUi.Timer.Start() }
    catch { $worker.Dispose(); $script:SfsuUi.Worker=$null; $script:SfsuUi.Tabs.Enabled=$true; $script:SfsuUi.Cancel.Enabled=$false; throw }
}

function Set-SfsuAuthenticationFailure($State,[string]$Message) {
    $State.Hint.Text=([string][char]0x26D4)+' '+$Message
    Update-SfsuDialogLayout $State.Form
}

function New-SfsuAuthenticationDialog {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Authenticate to Active Directory'; $dialog.ClientSize=New-Object Drawing.Size(540,345)
    $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $dialog.Font=$script:SfsuUi.Form.Font
    $hint=New-Object Windows.Forms.Label; $hint.Name='AuthenticationHeading'; $hint.Text='Enter your SFSU ID and password'
    $hint.Font=New-Object Drawing.Font($dialog.Font.FontFamily,([single]($dialog.Font.SizeInPoints*1.25)),[Drawing.FontStyle]::Bold)
    $hint.SetBounds(18,16,504,30); $dialog.Controls.Add($hint)
    $userLabel=New-Object Windows.Forms.Label; $userLabel.Text='SFSU &ID or power-user ID'; $userLabel.SetBounds(18,56,504,25); $dialog.Controls.Add($userLabel)
    $user=New-Object Windows.Forms.TextBox; $user.Name='SfsuLogin'; $user.SetBounds(18,84,504,28); $dialog.Controls.Add($user)
    if ($null -ne $script:SfsuUi.Credential) { $user.Text=$script:SfsuUi.Credential.UserName }
    $validation=New-Object Windows.Forms.Label; $validation.SetBounds(18,119,504,45); $dialog.Controls.Add($validation)
    $passwordLabel=New-Object Windows.Forms.Label; $passwordLabel.Text='&Password'; $passwordLabel.SetBounds(18,170,90,25); $dialog.Controls.Add($passwordLabel)
    $password=New-Object Windows.Forms.TextBox; $password.Name='Password'; $password.UseSystemPasswordChar=$true; $password.SetBounds(115,168,407,28); $dialog.Controls.Add($password)
    $purpose=New-Object Windows.Forms.Label; $purpose.Text='AD resolves SFSU ID to Display Name.'; $dialog.Controls.Add($purpose)
    $cancel=New-SfsuButton $dialog 'Continue without AD' 156 210 293; $cancel.DialogResult='Cancel'
    $ok=New-SfsuButton $dialog 'Authenticate' 378 144 293
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    $state=[pscustomobject]@{Form=$dialog;User=$user;Password=$password;Heading=$hint;Purpose=$purpose;Hint=$validation;Authenticate=$ok;Continue=$cancel;Worker=$null;Pending=$null;Credential=$null;Succeeded=$false;Closing=$false;ReportPath='';Root=$script:SfsuUi.Root;Server=$LdapServer;Timer=(New-Object Windows.Forms.Timer)}
    $dialog.Tag=$state; $state.Timer.Interval=100
    $user.Add_TextChanged({
        param($sender,$event)
        $s=$sender.FindForm().Tag
        try { [void](ConvertTo-SfsuLogin $sender.Text); $s.Hint.Text='' }
        catch { $s.Hint.Text=$_.Exception.Message }
    })
    $ok.Add_Click({
        param($sender,$event)
        $s=$sender.FindForm().Tag
        if ($null -ne $s.Worker) { return }
        try { $login=ConvertTo-SfsuLogin $s.User.Text }
        catch { $s.Hint.Text=$_.Exception.Message; return }
        try {
            if (-not $s.Password.Text) { $s.Hint.Text='Enter your password.'; return }
            $secure=ConvertTo-SecureString $s.Password.Text -AsPlainText -Force
            $s.Password.Clear()
            $s.Credential=New-Object Management.Automation.PSCredential($login,$secure)
            $s.User.Enabled=$false; $s.Password.Enabled=$false; $s.Authenticate.Enabled=$false
            $s.Hint.Text='Authenticating to Active Directory...'
            $s.Worker=[PowerShell]::Create()
            [void]$s.Worker.AddScript({param($root,$server,$credential)
                $ErrorActionPreference='Stop'
                Import-Module (Join-Path $root 'App/Scripts/Sfsu.Logging.psm1') -Force
                Import-Module (Join-Path $root 'App/Scripts/Sfsu.Inventory.psm1') -Force
                Invoke-SfsuDirectoryAuthentication -PackageRoot $root -Server $server -Credential $credential
            }.ToString()).AddArgument($s.Root).AddArgument($s.Server).AddArgument($s.Credential)
            $s.Pending=$s.Worker.BeginInvoke(); $s.Timer.Start()
        } catch {
            Set-SfsuAuthenticationFailure $s 'Authentication could not start. Check Logs and retry.'
            if ($null -ne $s.Worker) { $s.Worker.Dispose(); $s.Worker=$null }
            if ($null -ne $s.Credential) { $s.Credential.Password.Dispose(); $s.Credential=$null }
            $s.User.Enabled=$true; $s.Password.Enabled=$true; $s.Authenticate.Enabled=$true
        }
    })
    $state.Timer.Add_Tick({
        if ($null -eq $state.Pending -or -not $state.Pending.IsCompleted) { return }
        $state.Timer.Stop()
        try {
            $output=@($state.Worker.EndInvoke($state.Pending))
            if ($state.Worker.HadErrors -or $output.Count -eq 0) { throw 'Authentication task failed. Review Logs before retrying.' }
            $result=$output[-1]; $state.ReportPath=$result.ReportPath
            if ($result.Success -and -not $state.Closing) { $state.Succeeded=$true }
            elseif (-not $state.Closing) { Set-SfsuAuthenticationFailure $state ($result.DirectoryStatus + '. Retry or continue without AD.') }
        } catch { if (-not $state.Closing) { Set-SfsuAuthenticationFailure $state 'Authentication did not complete. Review Logs, retry, or continue without AD.' } }
        finally {
            $state.Worker.Dispose(); $state.Worker=$null; $state.Pending=$null
            $state.User.Enabled=$true; $state.Password.Enabled=$true; $state.Authenticate.Enabled=$true
            if (-not $state.Succeeded -and $null -ne $state.Credential) { $state.Credential.Password.Dispose(); $state.Credential=$null }
        }
        if ($state.Succeeded) { $state.Form.DialogResult='OK'; $state.Form.Close() }
        elseif ($state.Closing) { $state.Form.DialogResult='Cancel'; $state.Form.Close() }
    }.GetNewClosure())
    $dialog.Add_FormClosing({
        param($sender,$event)
        $s=$sender.Tag
        if ($null -ne $s.Worker) {
            $event.Cancel=$true
            if (-not $s.Closing) { $s.Closing=$true; $s.Continue.Enabled=$false; $s.Hint.Text='Stopping authentication...'; [void]$s.Worker.BeginStop($null,$null) }
        }
    })
    $dialog.Add_Disposed({
        param($sender,$event)
        $s=$sender.Tag; $s.Timer.Dispose(); $s.Password.Clear()
        $s.Heading.Font.Dispose()
        if ($null -ne $s.Credential) { $s.Credential.Password.Dispose(); $s.Credential=$null }
    })
    $user.AccessibleName='SFSU ID or power-user ID'; $user.AccessibleDescription='Enter the account ID, optionally followed by @sfsu.edu.'
    $password.AccessibleName='Password'; $password.AccessibleDescription='Active Directory password. The entry is masked.'
    $ok.Name='PrimaryAction'
    Initialize-SfsuAccessibleStatus $validation 'Alert'
    $dialog.Add_FontChanged({
        param($sender,$event)
        $heading=$sender.Controls['AuthenticationHeading']; $previous=$heading.Font
        $heading.Font=New-Object Drawing.Font($sender.Font.FontFamily,([single]($sender.Font.SizeInPoints*1.25)),[Drawing.FontStyle]::Bold)
        $previous.Dispose()
    })
    Initialize-SfsuDialogLayout $dialog @(
        @{Control=$hint;Kind='Label';Lines=1},@{Control=$userLabel;Kind='Label';Lines=1},@{Control=$user;Kind='Input'},
        @{Control=$validation;Kind='Label';Lines=2},@{Control=$passwordLabel;Kind='Label';Lines=1},@{Control=$password;Kind='Input'},@{Control=$purpose;Kind='Label';Lines=1}
    ) @($cancel,$ok)
    $dialog.Add_Shown({param($sender,$event) [void]$sender.Tag.User.Focus()})
    Register-SfsuThemedDialog $dialog
    $dialog
}

function Show-SfsuDirectoryCredentials {
    $dialog=New-SfsuAuthenticationDialog
    try {
        $accepted=$dialog.ShowDialog($script:SfsuUi.Form) -eq 'OK' -and $dialog.Tag.Succeeded
        if ($null -ne $script:SfsuUi.Credential) { $script:SfsuUi.Credential.Password.Dispose(); $script:SfsuUi.Credential=$null }
        $script:SfsuUi.UseDirectory=$accepted
        if ($dialog.Tag.ReportPath) { $script:SfsuUi.LatestReport=$dialog.Tag.ReportPath; $script:SfsuUi.Open.Enabled=$true }
        if ($accepted) {
            $script:SfsuUi.Credential=$dialog.Tag.Credential; $dialog.Tag.Credential=$null
        }
    } finally { $dialog.Dispose() }
    if ($script:SfsuUi.Tabs.SelectedIndex -eq 0 -or -not $script:SfsuUi.UseDirectory) { Start-SfsuUiTask 'Discover profiles' }
    else { Start-SfsuUiTask 'Refresh current names' }
}

function Show-SfsuManualIdentity {
    $row=$script:SfsuUi.Profiles.CurrentRow
    if ($null -eq $row) { Show-SfsuMessage 'Select a profile row first.'; return }
    $profile=$row.Tag
    if ($profile.IdentityStatus -match 'conflict') { Show-SfsuMessage 'Directory identity conflicts must be resolved before preparing this profile.'; return }
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Assign Display Name'; $dialog.ClientSize=New-Object Drawing.Size(530,285)
    $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.Font=$script:SfsuUi.Form.Font
    $hint=New-Object Windows.Forms.Label; $hint.Text='Profile: ' + $profile.ProfilePath; $hint.SetBounds(18,16,490,43); $dialog.Controls.Add($hint)
    $idLabel=New-Object Windows.Forms.Label; $idLabel.Text='SFSU ID'; $idLabel.SetBounds(18,72,100,25); $dialog.Controls.Add($idLabel)
    $id=New-Object Windows.Forms.Label; $id.Text=$profile.SfsuId; $id.SetBounds(128,72,375,25); $dialog.Controls.Add($id)
    if ($profile.AccountType -eq 'Local') { $idLabel.Text='Local Account'; $id.Text=$profile.AccountName }
    $nameLabel=New-Object Windows.Forms.Label; $nameLabel.Text='&Display name'; $nameLabel.SetBounds(18,115,105,25); $dialog.Controls.Add($nameLabel)
    $name=New-Object Windows.Forms.TextBox; $name.Text=$profile.DisplayName; $name.SetBounds(128,111,375,28); $dialog.Controls.Add($name)
    $confirm=New-Object Windows.Forms.CheckBox; $confirm.Text='I confirm this display name belongs to the selected profile.'; $confirm.SetBounds(18,163,490,43); $dialog.Controls.Add($confirm)
    $ok=New-SfsuButton $dialog 'Assign Display Name' 165 175 229
    $cancel=New-SfsuButton $dialog 'Cancel' 355 148 229; $cancel.DialogResult='Cancel'
    $dialog.CancelButton=$cancel; $dialog.AcceptButton=$ok
    $name.AccessibleName='Display name'; $confirm.AccessibleName='Confirm the display name belongs to this profile'; $ok.Name='PrimaryAction'
    Initialize-SfsuDialogLayout $dialog @(
        @{Control=$hint;Kind='Label';Lines=2},@{Control=$idLabel;Kind='Label';Lines=1},@{Control=$id;Kind='Label';Lines=1},
        @{Control=$nameLabel;Kind='Label';Lines=1},@{Control=$name;Kind='Input'},@{Control=$confirm;Kind='Input'}
    ) @($cancel,$ok)
    $dialog.Add_Shown({[void]$name.Focus()}.GetNewClosure())
    Register-SfsuThemedDialog $dialog
    $ok.Add_Click({
        try {
            Set-SfsuManualIdentity -Profile $profile -DisplayName $name.Text -Confirmed:$confirm.Checked | Out-Null
            $dialog.DialogResult='OK'; $dialog.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Check identity') }
    }.GetNewClosure())
    try {
        if ($dialog.ShowDialog($script:SfsuUi.Form) -eq 'OK') {
            if ($profile.AccountType -ne 'Local') { $row.Cells['SfsuId'].Value=$profile.SfsuId }
            $row.Cells['DisplayName'].Value=$profile.DisplayName; $row.Cells['IdentityStatus'].Value=$profile.IdentityStatus
            $row.Cells['Verified'].Value=''; $row.Cells['Verified'].ToolTipText='Display name assigned manually; not verified against AD.'
            Set-SfsuControlPalette $script:SfsuUi.Profiles $script:SfsuUi.Palette
        }
    } finally { $dialog.Dispose() }
}

$form=New-Object Windows.Forms.Form
$form.Text='SFSU User State Migration Tool'; $form.ClientSize=New-Object Drawing.Size(1120,745)
$form.MinimumSize=New-Object Drawing.Size(760,560); $form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',([single](10*$script:SfsuUi.TextScale/100.0)))
$form.BackColor=[Drawing.Color]::White; $form.AutoScaleMode='Dpi'; $form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
$form.AutoScroll=$true
$form.AccessibleName='SFSU User State Migration Tool'; $form.KeyPreview=$true
$script:SfsuUi.Form=$form
$header=New-Object Windows.Forms.Panel; $header.Name='ThemeHeader'; $header.Dock='Top'; $header.Height=112; $header.BackColor=[Drawing.ColorTranslator]::FromHtml('#442C8B'); $header.TabStop=$false
$logoBox=New-Object Windows.Forms.PictureBox; $logoBox.Name='ThemeLogo'; $logoBox.SetBounds(22,14,84,84); $logoBox.SizeMode='Zoom'; $logoBox.AccessibleName='San Francisco State University logo'; $logoBox.TabStop=$false; $header.Controls.Add($logoBox)
$textLogo=New-Object Windows.Forms.Label; $textLogo.Name='ThemeTextLogo'; $textLogo.Text='SFSU'; $textLogo.SetBounds(18,14,90,84); $textLogo.TextAlign='MiddleCenter'; $textLogo.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold); $header.Controls.Add($textLogo)
$logoPath=Join-Path $packageRoot 'App/Assets/SFSU Logo.png'
if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
    try { $image=[Drawing.Image]::FromFile($logoPath); try { $script:SfsuUi.Logo=New-Object Drawing.Bitmap($image); $logoBox.Image=$script:SfsuUi.Logo } finally { $image.Dispose() } }
    catch { Write-Warning 'The SFSU logo could not be loaded.' }
}
$title=New-Object Windows.Forms.Label; $title.Name='ThemeTitle'; $title.Text='SFSU User State Migration Tool'; $title.UseMnemonic=$false; $title.SetBounds(126,20,970,43); $title.Anchor='Top,Left,Right'
$title.Font=New-Object Drawing.Font('Segoe UI',23,[Drawing.FontStyle]::Bold); $title.ForeColor=[Drawing.ColorTranslator]::FromHtml('#FFD24F'); $header.Controls.Add($title)
$subtitle=New-Object Windows.Forms.LinkLabel; $subtitle.Text='By Academic Technology at SF State'; $subtitle.UseMnemonic=$false; $subtitle.LinkBehavior='AlwaysUnderline'; $subtitle.TabStop=$true
$subtitle.AccessibleName=$subtitle.Text; $subtitle.AccessibleDescription='Open the Academic Technology website in your default browser.'
$subtitle.Links.Clear(); [void]$subtitle.Links.Add(0,$subtitle.Text.Length,'https://at.sfsu.edu/')
$subtitle.SetBounds(129,69,967,28); $subtitle.Anchor='Top,Left,Right'; $header.Controls.Add($subtitle)
$subtitle.Add_LinkClicked({
    param($sender,$event)
    try { Start-Process -FilePath ([string]$event.Link.LinkData) -ErrorAction Stop | Out-Null; $event.Link.Visited=$true }
    catch { Show-SfsuMessage 'The Academic Technology website could not be opened. Visit https://at.sfsu.edu/ in your browser.' }
})
$notice=New-Object Windows.Forms.Label; $notice.Name='ThemeNotice'; $notice.Dock='Top'; $notice.AutoSize=$false; $notice.Padding=New-Object Windows.Forms.Padding(18,10,18,10)
$notice.Text='Preparation test: reads profiles and directory identities, creates folders and metadata. No employee files are copied and no restore runs.'
$notice.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF6DF')
$footer=New-Object Windows.Forms.TableLayoutPanel; $footer.Name='ThemeFooter'; $footer.Dock='Bottom'; $footer.AutoSize=$true; $footer.Padding=New-Object Windows.Forms.Padding(12,8,12,8)
$footer.ColumnCount=2; $footer.RowCount=2
[void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
[void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$footerActions=New-Object Windows.Forms.FlowLayoutPanel; $footerActions.Name='ThemeSurface'; $footerActions.Dock='Fill'; $footerActions.AutoSize=$true; $footerActions.WrapContents=$true; $footer.Controls.Add($footerActions,0,0)
$footer.SetColumnSpan($footerActions,2)
$open=New-SfsuButton $footerActions 'Open latest report' 18 180; $open.Enabled=$false
$logs=New-SfsuButton $footerActions 'Open Logs folder' 212 170
$cancelTask=New-SfsuButton $footerActions 'Cancel task' 396 135; $cancelTask.Enabled=$false
$chooseTheme=New-SfsuButton $footer 'Theme & Font' 0 160; $chooseTheme.UseMnemonic=$false; $chooseTheme.Name='ChooseTheme'; $chooseTheme.Anchor='Bottom,Right'; $footer.SetCellPosition($chooseTheme,(New-Object Windows.Forms.TableLayoutPanelCellPosition(1,1)))
$chooseTheme.AccessibleDescription='Alt+T. Choose and save the shared toolkit appearance.'
$status=New-Object Windows.Forms.Label; $status.Dock='Fill'; $status.AutoSize=$true; $status.MinimumSize=New-Object Drawing.Size(0,44); $status.Text='Ready.'; $footer.Controls.Add($status,0,1)
Initialize-SfsuAccessibleStatus $status
if ($script:SfsuUi.PreferenceWarning) { $status.Text=$script:SfsuUi.PreferenceWarning }
$script:SfsuUi.Status=$status; $script:SfsuUi.Open=$open; $script:SfsuUi.Cancel=$cancelTask
$script:SfsuUi.ChooseTheme=$chooseTheme
$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'; $tabs.Padding=New-Object Drawing.Point(18,8)
$backupPage=New-Object Windows.Forms.TabPage; $backupPage.Text='Backup'; [void]$tabs.TabPages.Add($backupPage)
$restorePage=New-Object Windows.Forms.TabPage; $restorePage.Text='Restore'; [void]$tabs.TabPages.Add($restorePage)
$script:SfsuUi.Tabs=$tabs
$backupBar=New-Object Windows.Forms.FlowLayoutPanel; $backupBar.Dock='Top'; $backupBar.AutoSize=$true; $backupBar.WrapContents=$true; $backupBar.Padding=New-Object Windows.Forms.Padding(8)
$refresh=New-SfsuButton $backupBar 'Refresh profiles' 12 150
$credentials=New-SfsuButton $backupBar 'Directory credentials...' 174 200
$manual=New-SfsuButton $backupBar 'Assign Display Name' 386 230
$prepare=New-SfsuButton $backupBar 'Prepare selected folders' 628 250
$prepare.Name='PrimaryAction'
$all=New-SfsuButton $backupBar 'Select all' 12 110 53
$none=New-SfsuButton $backupBar 'Select none' 134 120 53
$profiles=New-SfsuGrid $backupPage @(
    @{Id='Selected';Title='Select';Weight=7}, @{Id='SfsuId';Title='SFSU ID';Weight=13}, @{Id='Verified';Title='Verified';Weight=9}, @{Id='DisplayName';Title='Name';Weight=22},
    @{Id='ProfilePath';Title='Profile directory';Weight=31}, @{Id='IdentityStatus';Title='Identity';Weight=27}, @{Id='Sid';Title='SID';Weight=35}
)
$profiles.AutoSizeColumnsMode='None'; $profiles.ScrollBars='Both'; $profiles.AllowUserToResizeColumns=$true
$profileWidths=@{Selected=65;SfsuId=125;Verified=145;DisplayName=200;ProfilePath=280;IdentityStatus=300;Sid=360}
foreach ($column in $profiles.Columns) { $column.Width=$profileWidths[$column.Name] }
foreach ($columnName in @('Selected','SfsuId','Verified','DisplayName')) { $profiles.Columns[$columnName].Frozen=$true }
$script:SfsuUi.VerifiedFont=New-Object Drawing.Font('Segoe UI',10)
$profiles.Columns['Verified'].DefaultCellStyle.Font=$script:SfsuUi.VerifiedFont
$profiles.Columns['Verified'].DefaultCellStyle.Alignment='MiddleCenter'
$profiles.AccessibleName='Registered domain and local profiles'
$backupPage.Controls.Add($backupBar); $script:SfsuUi.Profiles=$profiles
$restoreBar=New-Object Windows.Forms.FlowLayoutPanel; $restoreBar.Dock='Top'; $restoreBar.AutoSize=$true; $restoreBar.WrapContents=$true; $restoreBar.Padding=New-Object Windows.Forms.Padding(8)
$refreshBackups=New-SfsuButton $restoreBar 'Refresh backups' 12 155
$currentNames=New-SfsuButton $restoreBar 'Refresh current names' 179 205
$restoreCredentials=New-SfsuButton $restoreBar 'Directory credentials...' 396 205
$review=New-SfsuButton $restoreBar 'Review selected backups' 613 260
$review.Name='PrimaryAction'
$backups=New-SfsuGrid $restorePage @(
    @{Id='Selected';Title='Select';Weight=6}, @{Id='SfsuId';Title='SFSU ID';Weight=11}, @{Id='AccountName';Title='Account';Weight=14}, @{Id='DisplayName';Title='Name';Weight=18},
    @{Id='Timestamp';Title='Timestamp (Pacific)';Weight=20}, @{Id='SourceComputer';Title='Computer';Weight=13},
    @{Id='Status';Title='Status';Weight=19}, @{Id='FormerName';Title='Formerly known as';Weight=17}
)
$backups.Columns['Timestamp'].ValueType=[DateTime]
$backups.Columns['Timestamp'].MinimumWidth=215
$backups.AccessibleName='Saved backup folders'
$backups.Add_CellFormatting({
    param($sender,$event)
    if ($sender.Columns[$event.ColumnIndex].Name -eq 'Timestamp' -and $event.Value -is [DateTime]) {
        $utc=[DateTime]::SpecifyKind($event.Value,[DateTimeKind]::Utc)
        $event.Value=[TimeZoneInfo]::ConvertTime([DateTimeOffset]$utc,[TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')).ToString('yyyy-MM-dd HH:mm:ss zzz')
        $event.FormattingApplied=$true
    }
})
$restorePage.Controls.Add($restoreBar); $script:SfsuUi.Backups=$backups
$form.Controls.Add($tabs); $form.Controls.Add($footer); $form.Controls.Add($notice); $form.Controls.Add($header)
$header.TabIndex=0; $tabs.TabIndex=1; $footer.TabIndex=2; $backupBar.TabIndex=0; $profiles.TabIndex=1; $restoreBar.TabIndex=0; $backups.TabIndex=1
foreach ($bar in @($backupBar,$restoreBar,$footerActions)) { $tabIndex=0; foreach ($child in $bar.Controls) { $child.TabIndex=$tabIndex; $tabIndex++ } }
$chooseTheme.TabIndex=1; $footerActions.TabIndex=0
$tabs.AccessibleName='Backup and restore views'
$tabs.Add_DrawItem({
    param($sender,$event)
    $palette=$script:SfsuUi.Palette
    $selected=$sender.SelectedIndex -eq $event.Index
    $bg=$palette.Surface; $fg=$palette.Foreground
    if ($selected) { $bg=$palette.Accent; $fg=$palette.AccentText }
    $brush=New-Object Drawing.SolidBrush($bg)
    try { $event.Graphics.FillRectangle($brush,$event.Bounds) } finally { $brush.Dispose() }
    [Windows.Forms.TextRenderer]::DrawText($event.Graphics,$sender.TabPages[$event.Index].Text,$sender.Font,$event.Bounds,$fg,([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
    if ($selected -and $sender.Focused) { $focus=$event.Bounds; $focus.Inflate(-3,-3); [Windows.Forms.ControlPaint]::DrawFocusRectangle($event.Graphics,$focus,$fg,$bg) }
})
function Get-SfsuMainLayoutSignature {
    # Height-only changes use normal docking. Include effective viewport widths
    # because native scrollbars can change them independently of the outer width.
    @($script:SfsuUi.Form.ClientSize.Width,$tabs.ClientSize.Width,$profiles.ClientSize.Width,
        $script:SfsuUi.Form.Font.Name,$script:SfsuUi.Form.Font.SizeInPoints,$script:SfsuUi.Form.Font.Height,
        $script:SfsuUi.Form.AutoScaleDimensions,$script:SfsuUi.Form.DeviceDpi,
        $title.Font.Name,$title.Font.SizeInPoints,$title.Font.Height,$title.Text,$subtitle.Text,$notice.Text,
        (($profiles.Columns | ForEach-Object Width) -join ',')) -join '|'
}

function Update-SfsuMainLayout {
    param([switch]$Force)
    $layout=$script:SfsuUi.MainLayout
    if ($layout.Interactive -or $layout.Busy -or $script:SfsuUi.Form.IsDisposed -or $script:SfsuUi.Form.WindowState -eq 'Minimized') { return }
    # Usually one pass. Allow bounded settling if the final batch changes native
    # scrollbar widths; nested Resize events cannot reenter custom measurement.
    for ($pass=0;$pass -lt 3;$pass++) {
        $signature=Get-SfsuMainLayoutSignature
        if (-not $Force -and $signature -ceq $layout.Signature) { return }
        $Force=$false
        $layout.Busy=$true
        $containers=@($script:SfsuUi.Form,$header,$tabs,$profiles,$backups)
        foreach ($container in $containers) { $container.SuspendLayout() }
        try {
            $headerWidth=[Math]::Max(200,$script:SfsuUi.Form.ClientSize.Width-150)
            $titleSize=[Windows.Forms.TextRenderer]::MeasureText($title.Text,$title.Font,(New-Object Drawing.Size($headerWidth,0)),[Windows.Forms.TextFormatFlags]::WordBreak)
            $title.Width=$headerWidth; $title.Height=$titleSize.Height+4
            $subtitle.Width=$headerWidth
            $subtitleSize=[Windows.Forms.TextRenderer]::MeasureText($subtitle.Text,$subtitle.Font,(New-Object Drawing.Size($headerWidth,0)),[Windows.Forms.TextFormatFlags]::WordBreak)
            $subtitle.Top=$title.Bottom+4; $subtitle.Height=$subtitleSize.Height+4
            $header.Height=[Math]::Max(112,$subtitle.Bottom+14)
            $logoBox.Top=[int](($header.Height-$logoBox.Height)/2); $textLogo.Height=$header.Height-28
            $width=[Math]::Max(100,$script:SfsuUi.Form.ClientSize.Width-$notice.Padding.Horizontal)
            $measured=[Windows.Forms.TextRenderer]::MeasureText($notice.Text,$notice.Font,(New-Object Drawing.Size($width,0)),[Windows.Forms.TextFormatFlags]::WordBreak)
            $notice.Height=$measured.Height+$notice.Padding.Vertical+4
            $tabs.SizeMode='Fixed'
            $tabs.ItemSize=New-Object Drawing.Size(([Math]::Max(100,[int](($tabs.ClientSize.Width-8)/2))),([Math]::Max(38,$tabs.Font.Height+16)))
            $profiles.Columns['Verified'].DefaultCellStyle.Font=$profiles.Font
            $scale=$script:SfsuUi.Form.Font.SizeInPoints/10.0
            $script:SfsuUi.Form.AutoScrollMinSize=New-Object Drawing.Size(0,([int](560+320*[Math]::Max(0,($scale-1))+[Math]::Max(0,($header.Height-112)))))
            $scaleChanged=$scale -ne $script:SfsuUi.GridFontScale
            $widths=@{}
            foreach ($column in $profiles.Columns) {
                $widths[$column.Name]=$column.Width
                if ($scaleChanged) { $widths[$column.Name]=[int]($profileWidths[$column.Name]*$scale) }
            }
            $wantedFrozen=@{}; $frozenWidth=0
            foreach ($name in @('Selected','SfsuId','Verified','DisplayName')) {
                if ($frozenWidth+$widths[$name] -gt $profiles.ClientSize.Width-120) { break }
                $wantedFrozen[$name]=$true; $frozenWidth+=$widths[$name]
            }
            # Remove only surplus frozen columns, right to left, before growing widths.
            for ($index=$profiles.Columns.Count-1;$index -ge 0;$index--) {
                $column=$profiles.Columns[$index]
                if ($column.Frozen -and -not $wantedFrozen.ContainsKey($column.Name)) { $column.Frozen=$false }
            }
            if ($scaleChanged) {
                foreach ($column in $profiles.Columns) { if ($column.Width -ne $widths[$column.Name]) { $column.Width=$widths[$column.Name] } }
                if ($scale -gt 1.25) {
                    $backups.AutoSizeColumnsMode='None'; $backups.ScrollBars='Both'
                    $restoreWidths=@{Selected=65;SfsuId=125;AccountName=150;DisplayName=220;Timestamp=235;SourceComputer=150;Status=250;FormerName=240}
                    foreach ($column in $backups.Columns) { $column.Width=[int]($restoreWidths[$column.Name]*$scale) }
                } else { $backups.AutoSizeColumnsMode='Fill' }
                $script:SfsuUi.GridFontScale=$scale
            }
            foreach ($column in $profiles.Columns) {
                if ($wantedFrozen.ContainsKey($column.Name) -and -not $column.Frozen) { $column.Frozen=$true }
            }
        } finally {
            try {
                for ($index=$containers.Count-1;$index -ge 0;$index--) { $containers[$index].ResumeLayout($true) }
            } finally { $layout.Busy=$false }
        }
        $layout.Signature=$signature
    }
}
$form.Add_ResizeBegin({ $script:SfsuUi.MainLayout.Interactive=$true })
$form.Add_ResizeEnd({ $script:SfsuUi.MainLayout.Interactive=$false; Update-SfsuMainLayout })
$form.Add_Resize({ Update-SfsuMainLayout })
$form.Add_FontChanged({ Update-SfsuMainLayout })
$form.Add_Shown({ Update-SfsuMainLayout -Force })
Update-SfsuMainLayout
$chooseTheme.Add_Click({ Show-SfsuThemeChooser })
$form.Add_KeyDown({
    param($sender,$event)
    if (-not $event.Alt) { return }
    $target=$null
    switch ($event.KeyCode) {
        'T' { $target=$script:SfsuUi.ChooseTheme }
        'R' { if ($script:SfsuUi.Tabs.SelectedIndex -eq 0) { $target=$refresh } else { $target=$refreshBackups } }
        'D' { if ($script:SfsuUi.Tabs.SelectedIndex -eq 0) { $target=$credentials } else { $target=$restoreCredentials } }
        'N' { if ($script:SfsuUi.Tabs.SelectedIndex -eq 0) { $target=$manual } }
        'P' { if ($script:SfsuUi.Tabs.SelectedIndex -eq 0) { $target=$prepare } else { $target=$review } }
    }
    if ($null -ne $target -and $target.Enabled) { $target.PerformClick(); $event.Handled=$true; $event.SuppressKeyPress=$true }
})
Update-SfsuAppearance
$form.Add_SystemColorsChanged({ Update-SfsuAppearance })
# WinForms dispatches color changes on the UI thread. A small UI timer also
# catches accessibility setting changes that do not emit a color-change event.
$appearanceTimer=New-Object Windows.Forms.Timer; $appearanceTimer.Interval=1000
$script:SfsuUi.AppearanceTimer=$appearanceTimer
$appearanceTimer.Add_Tick({
    $signature=([string][Windows.Forms.SystemInformation]::HighContrast)+':'+[Drawing.SystemColors]::Window.ToArgb()+':'+[Drawing.SystemColors]::WindowText.ToArgb()+':'+[Drawing.SystemColors]::Control.ToArgb()+':'+[Drawing.SystemColors]::ControlText.ToArgb()+':'+[Drawing.SystemColors]::Highlight.ToArgb()+':'+[Drawing.SystemColors]::HighlightText.ToArgb()
    if ($signature -cne $script:SfsuUi.AppearanceSignature) { $script:SfsuUi.AppearanceSignature=$signature; Update-SfsuAppearance }
})
$appearanceTimer.Start()

$refresh.Add_Click({ Start-SfsuUiTask 'Discover profiles' })
$credentials.Add_Click({ Show-SfsuDirectoryCredentials })
$restoreCredentials.Add_Click({ Show-SfsuDirectoryCredentials })
$manual.Add_Click({ Show-SfsuManualIdentity })
$all.Add_Click({ foreach ($row in $script:SfsuUi.Profiles.Rows) { $row.Cells['Selected'].Value=$true } })
$none.Add_Click({ foreach ($row in $script:SfsuUi.Profiles.Rows) { $row.Cells['Selected'].Value=$false } })
$prepare.Add_Click({
    $items=@(Get-SfsuCheckedRows $script:SfsuUi.Profiles)
    if ($items.Count -eq 0) { Show-SfsuMessage 'Check at least one profile to prepare.'; return }
    if (@($items | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) -or $_.IdentitySource -notin @('LDAP','Manual') -or ($_.IdentitySource -eq 'Manual' -and -not $_.ManualConfirmed) }).Count -gt 0) {
        Show-SfsuMessage 'Resolve or explicitly confirm a manual identity for every checked profile first.'; return
    }
    Start-SfsuUiTask 'Prepare folders' $items
})
$refreshBackups.Add_Click({ Start-SfsuUiTask 'List backups' })
$currentNames.Add_Click({ Start-SfsuUiTask 'Refresh current names' })
$review.Add_Click({
    $items=@(Get-SfsuCheckedRows $script:SfsuUi.Backups)
    if ($items.Count -eq 0) { Show-SfsuMessage 'Check at least one backup to review.'; return }
    Start-SfsuUiTask 'Review restore selection' $items
})
$tabs.Add_SelectedIndexChanged({ if ($script:SfsuUi.Tabs.SelectedIndex -eq 1) { Start-SfsuUiTask 'List backups' } })
$open.Add_Click({ try { Start-Process -FilePath $script:SfsuUi.LatestReport | Out-Null } catch { Show-SfsuMessage $_.Exception.Message } })
$logs.Add_Click({
    try { $path=Join-Path $script:SfsuUi.Root 'Logs'; [void][IO.Directory]::CreateDirectory($path); Start-Process explorer.exe -ArgumentList ('"'+$path+'"') | Out-Null }
    catch { Show-SfsuMessage $_.Exception.Message }
})
$cancelTask.Add_Click({
    if ($null -ne $script:SfsuUi.Worker) {
        $script:SfsuUi.Cancelled=$true; $script:SfsuUi.Cancel.Enabled=$false; $script:SfsuUi.Status.Text='Stopping. Any unfinished run remains Incomplete; existing files are preserved.'
        [void]$script:SfsuUi.Worker.BeginStop($null,$null)
    }
})
$timer=New-Object Windows.Forms.Timer; $timer.Interval=150; $script:SfsuUi.Timer=$timer
$timer.Add_Tick({
    if ($null -eq $script:SfsuUi.Pending -or -not $script:SfsuUi.Pending.IsCompleted) { return }
    $script:SfsuUi.Timer.Stop()
    try {
        $output=@($script:SfsuUi.Worker.EndInvoke($script:SfsuUi.Pending))
        if ($script:SfsuUi.Worker.HadErrors) { throw [string]$script:SfsuUi.Worker.Streams.Error[0] }
        if ($output.Count -eq 0) { throw 'The task ended without a result. Review Logs for an incomplete run.' }
        $result=$output[-1]
        $script:SfsuUi.LatestReport=$result.ReportPath; $script:SfsuUi.Open.Enabled=$true
        switch ($script:SfsuUi.Action) {
            'Discover profiles' { Set-SfsuProfileRows @($result.Profiles); $script:SfsuUi.Status.Text="$(@($result.Profiles).Count) domain/local profile directories. Directory: $($result.DirectoryStatus). Check identities before preparation." }
            'Prepare folders' {
                $script:SfsuUi.Status.Text="$(@($result.Paths).Count) folders prepared; $(@($result.Errors).Count) errors. No employee data captured. See the report for details."
            }
            'List backups' { Set-SfsuBackupRows @($result.Backups); $script:SfsuUi.Status.Text="$(@($result.Backups).Count) backup folders listed, newest first. Prepared folders contain no migration data." }
            'Refresh current names' { Set-SfsuBackupRows @($result.Backups); $script:SfsuUi.Status.Text="Current-name lookup: $($result.DirectoryStatus). Historical metadata was preserved." }
            'Review restore selection' { $script:SfsuUi.Status.Text='Selection review finished. No restore ran. Read the report for individual results.' }
        }
    } catch {
        $script:SfsuUi.Status.Text='Task stopped: ' + $_.Exception.Message
        if ($script:SfsuUi.Cancelled) { $script:SfsuUi.Status.Text='Task cancelled. Review the latest report; unfinished work remains Incomplete. No migration ran.' }
        $logRoot=Join-Path $script:SfsuUi.Root 'Logs'
        if (Test-Path -LiteralPath $logRoot) {
            $latest=Get-ChildItem -LiteralPath $logRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($null -ne $latest -and (Test-Path -LiteralPath (Join-Path $latest.FullName 'report.html'))) {
                $script:SfsuUi.LatestReport=Join-Path $latest.FullName 'report.html'; $script:SfsuUi.Open.Enabled=$true
            }
        }
    } finally {
        $script:SfsuUi.Worker.Dispose(); $script:SfsuUi.Worker=$null; $script:SfsuUi.Pending=$null
        $script:SfsuUi.Tabs.Enabled=$true; $script:SfsuUi.Cancel.Enabled=$false
        if ($script:SfsuUi.CloseWhenDone) { $script:SfsuUi.Form.Close() }
    }
})
$form.Add_FormClosing({
    param($sender,$event)
    if ($null -ne $script:SfsuUi.Worker) {
        $event.Cancel=$true; $script:SfsuUi.CloseWhenDone=$true
        if (-not $script:SfsuUi.Cancelled) { $script:SfsuUi.Cancel.PerformClick() }
    }
})
if (-not $BuildUiOnly) { $form.WindowState='Maximized'; $form.Add_Shown({ Show-SfsuDirectoryCredentials }) }
$form.Add_Disposed({
    $script:SfsuUi.Timer.Dispose()
    $script:SfsuUi.AppearanceTimer.Stop(); $script:SfsuUi.AppearanceTimer.Dispose()
    if ($null -ne $script:SfsuUi.Credential) { $script:SfsuUi.Credential.Password.Dispose(); $script:SfsuUi.Credential=$null }
    if ($null -ne $script:SfsuUi.Logo) { $script:SfsuUi.Logo.Dispose() }
    $script:SfsuUi.VerifiedFont.Dispose()
    $script:SfsuUi.Form.Font.Dispose()
})
if ($BuildUiOnly) { return $form }
try { [void]$form.ShowDialog() } finally { $form.Dispose() }
