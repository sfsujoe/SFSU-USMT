# Loaded into the main UI scope. Passwords remain in SecureString objects only
# for the active restore request and never enter saved plans or process arguments.
function Initialize-SfsuAccountChoice($Choice) {
    # The shared palette uses owner drawing for custom-theme combo boxes.
    $Choice.DrawMode='OwnerDrawFixed'; $Choice.ItemHeight=$Choice.Font.Height+6
    $Choice.Add_FontChanged({param($sender,$event) $sender.ItemHeight=$sender.Font.Height+6})
    $Choice.Add_DrawItem({
        param($sender,$event)
        if ($event.Index -lt 0) { return }
        $palette=$script:SfsuUi.Palette; $background=$palette.Background; $foreground=$palette.Foreground
        if ($event.State -band [Windows.Forms.DrawItemState]::Selected) { $background=$palette.Accent; $foreground=$palette.AccentText }
        $brush=New-Object Drawing.SolidBrush($background)
        try { $event.Graphics.FillRectangle($brush,$event.Bounds) } finally { $brush.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($event.Graphics,[string]$sender.Items[$event.Index],$sender.Font,$event.Bounds,$foreground,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        if ($event.State -band [Windows.Forms.DrawItemState]::Focus) { [Windows.Forms.ControlPaint]::DrawFocusRectangle($event.Graphics,$event.Bounds,$foreground,$background) }
    })
}

function New-SfsuLocalRestoreDialog($Plan) {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Recreate local account'; $dialog.ClientSize=New-Object Drawing.Size(600,560)
    $dialog.StartPosition='CenterParent'; $dialog.Font=$script:SfsuUi.Form.Font
    $heading=New-Object Windows.Forms.Label; $heading.Text='Account: '+$Plan.AccountName+'  |  '+$Plan.DisplayName; $dialog.Controls.Add($heading)
    $explanation=New-Object Windows.Forms.Label; $explanation.Text='Choose a new password and the final account settings. The account is created disabled and stays disabled if restore fails.'; $dialog.Controls.Add($explanation)
    $passwordLabel=New-Object Windows.Forms.Label; $passwordLabel.Text='&Password'; $dialog.Controls.Add($passwordLabel)
    $password=New-Object Windows.Forms.TextBox; $password.UseSystemPasswordChar=$true; $password.MaxLength=256; $password.AccessibleName='New local account password'; $dialog.Controls.Add($password)
    $confirmLabel=New-Object Windows.Forms.Label; $confirmLabel.Text='&Confirm password'; $dialog.Controls.Add($confirmLabel)
    $confirm=New-Object Windows.Forms.TextBox; $confirm.UseSystemPasswordChar=$true; $confirm.MaxLength=256; $confirm.AccessibleName='Confirm new local account password'; $dialog.Controls.Add($confirm)
    $enabledLabel=New-Object Windows.Forms.Label; $enabledLabel.Text='&Enable this account after restore?'; $dialog.Controls.Add($enabledLabel)
    $enabled=New-Object Windows.Forms.ComboBox; $enabled.DropDownStyle='DropDownList'; [void]$enabled.Items.AddRange(@('No - leave disabled','Yes - enable')); $enabled.SelectedIndex=-1; $enabled.AccessibleName='Enable the recreated account after successful restore'; $dialog.Controls.Add($enabled)
    $adminLabel=New-Object Windows.Forms.Label; $adminLabel.Text='Add to local &Administrators?'; $dialog.Controls.Add($adminLabel)
    $admin=New-Object Windows.Forms.ComboBox; $admin.DropDownStyle='DropDownList'; [void]$admin.Items.AddRange(@('No - standard user','Yes - administrator')); $admin.SelectedIndex=0; $admin.AccessibleName='Add the recreated account to local Administrators'; $dialog.Controls.Add($admin)
    Initialize-SfsuAccountChoice $enabled; Initialize-SfsuAccountChoice $admin
    $errorLabel=New-Object Windows.Forms.Label; Initialize-SfsuAccessibleStatus $errorLabel 'Alert'; $dialog.Controls.Add($errorLabel)
    $ok=New-SfsuButton $dialog 'Use these settings' 0 180; $ok.Name='PrimaryAction'
    $cancel=New-SfsuButton $dialog 'Cancel restore' 0 150; $cancel.DialogResult='Cancel'
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    $dialog.Tag=[pscustomobject]@{Password=$password;Confirm=$confirm;Enabled=$enabled;Administrator=$admin;Error=$errorLabel;Options=$null}
    $ok.Add_Click({
        param($sender,$event)
        $window=$sender.FindForm(); $state=$window.Tag
        if (-not $state.Password.Text -or $state.Password.Text -cne $state.Confirm.Text) { $state.Error.Text='Enter a nonempty password and an identical confirmation.'; Update-SfsuDialogLayout $window; return }
        if ($state.Enabled.SelectedIndex -lt 0 -or $state.Administrator.SelectedIndex -lt 0) { $state.Error.Text='Choose whether the account will be enabled and whether it will be an administrator.'; Update-SfsuDialogLayout $window; return }
        $secure=[Net.NetworkCredential]::new('', $state.Password.Text).SecurePassword; $secure.MakeReadOnly()
        $state.Options=[pscustomobject]@{Password=$secure;Enabled=($state.Enabled.SelectedIndex -eq 1);Administrator=($state.Administrator.SelectedIndex -eq 1)}
        $state.Password.Clear(); $state.Confirm.Clear(); $window.DialogResult='OK'; $window.Close()
    })
    $dialog.Add_FormClosed({param($sender,$event) $sender.Tag.Password.Clear(); $sender.Tag.Confirm.Clear(); if ($sender.DialogResult -ne 'OK' -and $null -ne $sender.Tag.Options) { $sender.Tag.Options.Password.Dispose(); $sender.Tag.Options=$null }})
    $dialog.Add_Disposed({param($sender,$event) if ($null -ne $sender.Tag.Options) { $sender.Tag.Options.Password.Dispose(); $sender.Tag.Options=$null }})
    Initialize-SfsuDialogLayout $dialog @(
        @{Control=$heading;Kind='Label';Lines=2},@{Control=$explanation;Kind='Label';Lines=2},
        @{Control=$passwordLabel;Kind='Label';Lines=1},@{Control=$password;Kind='Input'},@{Control=$confirmLabel;Kind='Label';Lines=1},@{Control=$confirm;Kind='Input'},
        @{Control=$enabledLabel;Kind='Label';Lines=1},@{Control=$enabled;Kind='Input'},@{Control=$adminLabel;Kind='Label';Lines=1},@{Control=$admin;Kind='Input'},@{Control=$errorLabel;Kind='Label';Lines=2;HideWhenEmpty=$true}
    ) @($cancel,$ok)
    $dialog.Add_Shown({param($sender,$event) [void]$sender.Tag.Password.Focus()})
    Register-SfsuThemedDialog $dialog
    $dialog
}

function New-SfsuCaptureLocationDialog($Review) {
    $dialog=New-Object Windows.Forms.Form; $dialog.Text='Review cloud and browser folders'; $dialog.ClientSize=New-Object Drawing.Size(700,700)
    $dialog.StartPosition='CenterParent'; $dialog.Font=$script:SfsuUi.Form.Font
    $heading=New-Object Windows.Forms.Label; $heading.Text=$Review.Profile.DisplayName+'  |  '+$Review.Profile.ProfilePath; $dialog.Controls.Add($heading)
    $description=New-Object Windows.Forms.Label; $description.Text='Cloud folders and caches below will be excluded. Cloud uploads are assumed complete. Review custom locations and redirected folders before backing up.'; $dialog.Controls.Add($description)
    $detected=New-Object Windows.Forms.TextBox; $detected.Multiline=$true; $detected.ReadOnly=$true; $detected.ScrollBars='Both'; $detected.WordWrap=$false; $detected.AccessibleName='Detected cloud exclusions and redirected folders'
    $detected.Text=(@($Review.CloudRoots | ForEach-Object { $_.Path+' ('+$_.Source+')' })+@('','Redirected folders:')+@($Review.RedirectedFolders)+@('','Review notes:')+@($Review.Issues)) -join "`r`n"; $dialog.Controls.Add($detected)
    $cloudLabel=New-Object Windows.Forms.Label; $cloudLabel.Text='Additional cloud folders to exclude, one full path per line:'; $dialog.Controls.Add($cloudLabel)
    $cloud=New-Object Windows.Forms.TextBox; $cloud.Multiline=$true; $cloud.ScrollBars='Vertical'; $cloud.AccessibleName='Additional cloud folder exclusions'; $dialog.Controls.Add($cloud)
    $browserLabel=New-Object Windows.Forms.Label; $browserLabel.Text='Additional browser data folders, one per line: Edge|C:\Path, Chrome|C:\Path or Firefox|C:\Path'; $dialog.Controls.Add($browserLabel)
    $browser=New-Object Windows.Forms.TextBox; $browser.Multiline=$true; $browser.ScrollBars='Vertical'; $browser.AccessibleName='Additional browser data folders'; $dialog.Controls.Add($browser)
    $confirmed=New-Object Windows.Forms.CheckBox; $confirmed.Text='I reviewed the detected locations and added any missing cloud/browser folders.'; $dialog.Controls.Add($confirmed)
    $errorLabel=New-Object Windows.Forms.Label; Initialize-SfsuAccessibleStatus $errorLabel 'Alert'; $dialog.Controls.Add($errorLabel)
    $ok=New-SfsuButton $dialog 'Use these locations' 0 180; $ok.Name='PrimaryAction'
    $cancel=New-SfsuButton $dialog 'Cancel backup' 0 150; $cancel.DialogResult='Cancel'; $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    $dialog.Tag=[pscustomobject]@{Review=$Review;Cloud=$cloud;Browser=$browser;Confirmed=$confirmed;Error=$errorLabel}
    $ok.Add_Click({
        param($sender,$event)
        $window=$sender.FindForm(); $state=$window.Tag
        try { Set-SfsuCaptureLocations -Review $state.Review -CloudText $state.Cloud.Text -BrowserText $state.Browser.Text -Confirmed $state.Confirmed.Checked | Out-Null; $window.DialogResult='OK'; $window.Close() }
        catch { $state.Error.Text=$_.Exception.Message; Update-SfsuDialogLayout $window }
    })
    Initialize-SfsuDialogLayout $dialog @(
        @{Control=$heading;Kind='Label';Lines=2},@{Control=$description;Kind='Label';Lines=2},@{Control=$detected;Kind='TextArea';Lines=6},
        @{Control=$cloudLabel;Kind='Label';Lines=1},@{Control=$cloud;Kind='TextArea';Lines=3},@{Control=$browserLabel;Kind='Label';Lines=2},@{Control=$browser;Kind='TextArea';Lines=3},
        @{Control=$confirmed;Kind='Input'},@{Control=$errorLabel;Kind='Label';Lines=2;HideWhenEmpty=$true}
    ) @($cancel,$ok)
    Register-SfsuThemedDialog $dialog
    $dialog
}

function Clear-SfsuRestorePasswords([object[]]$Plans) {
    foreach ($plan in $Plans) {
        if ($plan.PSObject.Properties['LocalOptions'] -and $null -ne $plan.LocalOptions -and $null -ne $plan.LocalOptions.Password) { $plan.LocalOptions.Password.Dispose(); $plan.LocalOptions.Password=$null }
    }
}

function Show-SfsuCaptureLocations([object[]]$Reviews) {
    foreach ($review in $Reviews) {
        $dialog=New-SfsuCaptureLocationDialog $review
        try { if ($dialog.ShowDialog($script:SfsuUi.Form) -ne 'OK') { $script:SfsuUi.Status.Text='Backup cancelled before capture. No employee data was copied.'; return } }
        finally { $dialog.Dispose() }
    }
    Start-SfsuUiTask 'Capture profiles' $Reviews
}

function Show-SfsuRestoreSettings([object[]]$Plans) {
    $started=$false
    try {
        foreach ($plan in $Plans) {
            if ($plan.AccountType -ne 'Local') { continue }
            $dialog=New-SfsuLocalRestoreDialog $plan
            try {
                if ($dialog.ShowDialog($script:SfsuUi.Form) -ne 'OK') { $script:SfsuUi.Status.Text='Restore cancelled before account/data changes.'; return }
                $plan.LocalOptions=$dialog.Tag.Options; $dialog.Tag.Options=$null
            } finally { $dialog.Dispose() }
        }
        $summary=@('Restore these backups? All targets will be checked again before account/data changes.','')+@($Plans | ForEach-Object {
            $text=$_.DisplayName+' ('+$_.AccountType+')'
            if ($_.AccountType -eq 'Local') { $text+='; Enabled='+$_.LocalOptions.Enabled+'; Administrator='+$_.LocalOptions.Administrator }
            $text
        })
        if ([Windows.Forms.MessageBox]::Show($script:SfsuUi.Form,($summary -join "`r`n"),'Restore selected backups','OKCancel','Question') -ne 'OK') { $script:SfsuUi.Status.Text='Restore cancelled before account/data changes.'; return }
        $script:SfsuUi.ActiveRestorePlans=$Plans
        Start-SfsuUiTask 'Restore backups' $Plans; $started=$true
    } finally { if (-not $started) { Clear-SfsuRestorePasswords $Plans; $script:SfsuUi.ActiveRestorePlans=@() } }
}
