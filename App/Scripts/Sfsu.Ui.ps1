# Loaded by Start-SfsuUsmt.ps1. UI tasks run in a separate PowerShell runspace.
Import-Module (Join-Path $PSScriptRoot 'Sfsu.Inventory.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:SfsuUi = @{ Root=$packageRoot; Worker=$null; Pending=$null; Credential=$null; UseDirectory=$false; LatestReport=''; CloseWhenDone=$false; Cancelled=$false; Logo=$null }

function New-SfsuButton($Parent, [string]$Text, [int]$Left, [int]$Width, [int]$Top=12) {
    $control = New-Object Windows.Forms.Button
    $control.Text=$Text; $control.SetBounds($Left,$Top,$Width,34)
    $Parent.Controls.Add($control)
    $control
}

function New-SfsuGrid($Parent, [object[]]$Definitions) {
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'; $grid.BackgroundColor=[Drawing.Color]::White; $grid.BorderStyle='None'
    $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false
    $grid.AllowUserToResizeRows=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.SelectionMode='FullRowSelect'
    $grid.MultiSelect=$false; $grid.RowTemplate.Height=32; $grid.ColumnHeadersHeight=38
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
    $Parent.Controls.Add($grid)
    $grid
}

function Test-SfsuProfileVerified($Profile) {
    $Profile.AccountType -eq 'Domain' -and $Profile.IdentitySource -eq 'LDAP' -and
        $Profile.IdentityStatus -eq 'Directory verified' -and $Profile.VerifiedAtUtc -and
        $Profile.DirectorySid -eq $Profile.ProfileSid -and $Profile.SfsuId -match '^\d{1,32}$' -and
        $Profile.SfsuId -ceq $Profile.SamAccountName -and $Profile.SfsuId -ceq (Split-Path $Profile.ProfilePath -Leaf) -and
        -not [string]::IsNullOrWhiteSpace($Profile.DisplayName)
}

function Set-SfsuProfileRows([object[]]$Profiles) {
    $grid=$script:SfsuUi.Profiles; $grid.Rows.Clear()
    foreach ($profile in $Profiles) {
        $idLabel=$profile.SfsuId
        if ($profile.AccountType -eq 'Local') { $idLabel='Local Account' }
        $verified=''
        if (Test-SfsuProfileVerified $profile) { $verified=[string][char]0x2705 }
        $index=$grid.Rows.Add([object[]]@($false,$idLabel,$verified,$profile.DisplayName,$profile.ProfilePath,$profile.IdentityStatus,$profile.ProfileSid))
        $grid.Rows[$index].Tag=$profile
        $grid.Rows[$index].Cells['Sid'].ToolTipText=$profile.ProfileSid
        $verificationHint='Not verified against Active Directory.'
        if ($verified) { $verificationHint='AD verified: profile SID, SFSU ID, and display name.' }
        elseif ($profile.AccountType -eq 'Local') { $verificationHint='Local account; AD verification does not apply.' }
        elseif ($profile.IdentitySource -eq 'Manual') { $verificationHint='Display name assigned manually; not verified against AD.' }
        $grid.Rows[$index].Cells['Verified'].ToolTipText=$verificationHint
        if ($profile.IdentitySource -ne 'LDAP') { $grid.Rows[$index].DefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF6DF') }
    }
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

function New-SfsuAuthenticationDialog {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Authenticate to Active Directory'; $dialog.ClientSize=New-Object Drawing.Size(540,345)
    $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $dialog.Font=$script:SfsuUi.Form.Font
    $hint=New-Object Windows.Forms.Label; $hint.Text='Enter your SFSU ID and password'
    $hint.SetBounds(18,16,504,30); $dialog.Controls.Add($hint)
    $userLabel=New-Object Windows.Forms.Label; $userLabel.Text='SFSU ID or full SFSU Login'; $userLabel.SetBounds(18,56,504,25); $dialog.Controls.Add($userLabel)
    $user=New-Object Windows.Forms.TextBox; $user.Name='SfsuLogin'; $user.SetBounds(18,84,504,28); $dialog.Controls.Add($user)
    if ($null -ne $script:SfsuUi.Credential) { $user.Text=$script:SfsuUi.Credential.UserName }
    $validation=New-Object Windows.Forms.Label; $validation.SetBounds(18,119,504,45); $dialog.Controls.Add($validation)
    $passwordLabel=New-Object Windows.Forms.Label; $passwordLabel.Text='Password'; $passwordLabel.SetBounds(18,170,90,25); $dialog.Controls.Add($passwordLabel)
    $password=New-Object Windows.Forms.TextBox; $password.Name='Password'; $password.UseSystemPasswordChar=$true; $password.SetBounds(115,168,407,28); $dialog.Controls.Add($password)
    $privacy=New-Object Windows.Forms.Label; $privacy.Text='Account names appear in logs. Your password is kept only for this open app session and is not saved.'; $privacy.SetBounds(18,211,504,47); $dialog.Controls.Add($privacy)
    $cancel=New-SfsuButton $dialog 'Continue without AD' 156 210 293; $cancel.DialogResult='Cancel'
    $ok=New-SfsuButton $dialog 'Authenticate' 378 144 293
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    $state=[pscustomobject]@{Form=$dialog;User=$user;Password=$password;Hint=$validation;Authenticate=$ok;Continue=$cancel;Worker=$null;Pending=$null;Credential=$null;Succeeded=$false;Closing=$false;ReportPath='';Root=$script:SfsuUi.Root;Server=$LdapServer;Timer=(New-Object Windows.Forms.Timer)}
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
            $s.Hint.Text='Authentication could not start. Check Logs and retry.'
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
            else { $state.Hint.Text=$result.DirectoryStatus + '. Retry or continue without AD.' }
        } catch { $state.Hint.Text='Authentication did not complete. Review Logs, retry, or continue without AD.' }
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
        if ($null -ne $s.Credential) { $s.Credential.Password.Dispose(); $s.Credential=$null }
    })
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
    $nameLabel=New-Object Windows.Forms.Label; $nameLabel.Text='Display name'; $nameLabel.SetBounds(18,115,105,25); $dialog.Controls.Add($nameLabel)
    $name=New-Object Windows.Forms.TextBox; $name.Text=$profile.DisplayName; $name.SetBounds(128,111,375,28); $dialog.Controls.Add($name)
    $confirm=New-Object Windows.Forms.CheckBox; $confirm.Text='I confirm this display name belongs to the selected profile.'; $confirm.SetBounds(18,163,490,43); $dialog.Controls.Add($confirm)
    $ok=New-SfsuButton $dialog 'Assign Display Name' 165 175 229
    $cancel=New-SfsuButton $dialog 'Cancel' 355 148 229; $cancel.DialogResult='Cancel'
    $dialog.CancelButton=$cancel; $dialog.AcceptButton=$ok
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
            $row.DefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF6DF')
        }
    } finally { $dialog.Dispose() }
}

$form=New-Object Windows.Forms.Form
$form.Text='SFSU USMT - Backup and Restore Preparation'; $form.ClientSize=New-Object Drawing.Size(1120,745)
$form.MinimumSize=New-Object Drawing.Size(1040,680); $form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.BackColor=[Drawing.Color]::White; $form.AutoScaleMode='Dpi'
$script:SfsuUi.Form=$form
$header=New-Object Windows.Forms.Panel; $header.Dock='Top'; $header.Height=112; $header.BackColor=[Drawing.ColorTranslator]::FromHtml('#442C8B')
$logoBox=New-Object Windows.Forms.PictureBox; $logoBox.SetBounds(22,14,84,84); $logoBox.SizeMode='Zoom'; $logoBox.AccessibleName='San Francisco State University logo'; $header.Controls.Add($logoBox)
$logoPath=Join-Path $packageRoot 'App/Assets/SFSU Logo.png'
if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
    try { $image=[Drawing.Image]::FromFile($logoPath); try { $script:SfsuUi.Logo=New-Object Drawing.Bitmap($image); $logoBox.Image=$script:SfsuUi.Logo } finally { $image.Dispose() } }
    catch { Write-Warning 'The SFSU logo could not be loaded.' }
}
$title=New-Object Windows.Forms.Label; $title.Text='Employee Backup & Restore'; $title.UseMnemonic=$false; $title.SetBounds(126,20,920,43)
$title.Font=New-Object Drawing.Font('Segoe UI',23,[Drawing.FontStyle]::Bold); $title.ForeColor=[Drawing.ColorTranslator]::FromHtml('#FFD24F'); $header.Controls.Add($title)
$subtitle=New-Object Windows.Forms.Label; $subtitle.Text='SFSU  |  Profile discovery and backup preparation'; $subtitle.SetBounds(129,69,900,28); $subtitle.ForeColor=[Drawing.Color]::White; $header.Controls.Add($subtitle)
$notice=New-Object Windows.Forms.Label; $notice.Dock='Top'; $notice.Height=52; $notice.Padding=New-Object Windows.Forms.Padding(18,10,18,0)
$notice.Text='Preparation test: reads profiles and directory identities, creates folders and metadata. No employee files are copied and no restore runs.'
$notice.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF6DF')
$footer=New-Object Windows.Forms.Panel; $footer.Dock='Bottom'; $footer.Height=114; $footer.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F1F8')
$open=New-SfsuButton $footer 'Open latest report' 18 180; $open.Enabled=$false
$logs=New-SfsuButton $footer 'Open Logs folder' 212 170
$cancelTask=New-SfsuButton $footer 'Cancel task' 396 135; $cancelTask.Enabled=$false
$status=New-Object Windows.Forms.Label; $status.SetBounds(18,57,1045,49); $status.Anchor='Top,Left,Right'; $status.Text='Ready.'; $footer.Controls.Add($status)
$script:SfsuUi.Status=$status; $script:SfsuUi.Open=$open; $script:SfsuUi.Cancel=$cancelTask
$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'; $tabs.Padding=New-Object Drawing.Point(18,8)
$backupPage=New-Object Windows.Forms.TabPage; $backupPage.Text='Backup'; [void]$tabs.TabPages.Add($backupPage)
$restorePage=New-Object Windows.Forms.TabPage; $restorePage.Text='Restore'; [void]$tabs.TabPages.Add($restorePage)
$script:SfsuUi.Tabs=$tabs
$backupBar=New-Object Windows.Forms.Panel; $backupBar.Dock='Top'; $backupBar.Height=96
$refresh=New-SfsuButton $backupBar 'Refresh profiles' 12 150
$credentials=New-SfsuButton $backupBar 'Directory credentials...' 174 200
$manual=New-SfsuButton $backupBar 'Assign Display Name' 386 230
$prepare=New-SfsuButton $backupBar 'Prepare selected folders' 628 250
$prepare.BackColor=$header.BackColor; $prepare.ForeColor=[Drawing.Color]::White; $prepare.FlatStyle='Flat'
$all=New-SfsuButton $backupBar 'Select all' 12 110 53
$none=New-SfsuButton $backupBar 'Select none' 134 120 53
$hint=New-Object Windows.Forms.Label; $hint.Text='Check profiles. ' + [char]0x2705 + ' = AD verified. Scroll right for SID.'; $hint.SetBounds(271,59,730,30); $backupBar.Controls.Add($hint)
$profiles=New-SfsuGrid $backupPage @(
    @{Id='Selected';Title='Select';Weight=7}, @{Id='SfsuId';Title='SFSU ID';Weight=13}, @{Id='Verified';Title='Verified';Weight=9}, @{Id='DisplayName';Title='Name';Weight=22},
    @{Id='ProfilePath';Title='Profile directory';Weight=31}, @{Id='IdentityStatus';Title='Identity';Weight=27}, @{Id='Sid';Title='SID';Weight=35}
)
$profiles.AutoSizeColumnsMode='None'; $profiles.ScrollBars='Both'; $profiles.AllowUserToResizeColumns=$true
$profileWidths=@{Selected=65;SfsuId=125;Verified=85;DisplayName=200;ProfilePath=280;IdentityStatus=300;Sid=360}
foreach ($column in $profiles.Columns) { $column.Width=$profileWidths[$column.Name] }
foreach ($columnName in @('Selected','SfsuId','Verified','DisplayName')) { $profiles.Columns[$columnName].Frozen=$true }
$script:SfsuUi.VerifiedFont=New-Object Drawing.Font('Segoe UI Emoji',12)
$profiles.Columns['Verified'].DefaultCellStyle.Font=$script:SfsuUi.VerifiedFont
$profiles.Columns['Verified'].DefaultCellStyle.Alignment='MiddleCenter'
$profiles.Columns['Verified'].DefaultCellStyle.ForeColor=[Drawing.Color]::ForestGreen
$backupPage.Controls.Add($backupBar); $script:SfsuUi.Profiles=$profiles
$restoreBar=New-Object Windows.Forms.Panel; $restoreBar.Dock='Top'; $restoreBar.Height=96
$refreshBackups=New-SfsuButton $restoreBar 'Refresh backups' 12 155
$currentNames=New-SfsuButton $restoreBar 'Refresh current names' 179 205
$restoreCredentials=New-SfsuButton $restoreBar 'Directory credentials...' 396 205
$review=New-SfsuButton $restoreBar 'Review selected backups' 613 260
$restoreHint=New-Object Windows.Forms.Label; $restoreHint.Text='Newest first. Click column headers to sort. Prepared folders have no data to restore.'; $restoreHint.SetBounds(18,60,1040,28); $restoreBar.Controls.Add($restoreHint)
$backups=New-SfsuGrid $restorePage @(
    @{Id='Selected';Title='Select';Weight=6}, @{Id='SfsuId';Title='SFSU ID';Weight=11}, @{Id='AccountName';Title='Account';Weight=14}, @{Id='DisplayName';Title='Name';Weight=18},
    @{Id='Timestamp';Title='Timestamp (Pacific)';Weight=20}, @{Id='SourceComputer';Title='Computer';Weight=13},
    @{Id='Status';Title='Status';Weight=19}, @{Id='FormerName';Title='Formerly known as';Weight=17}
)
$backups.Columns['Timestamp'].ValueType=[DateTime]
$backups.Columns['Timestamp'].MinimumWidth=215
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
if (-not $BuildUiOnly) { $form.Add_Shown({ Show-SfsuDirectoryCredentials }) }
$form.Add_Disposed({
    $script:SfsuUi.Timer.Dispose()
    if ($null -ne $script:SfsuUi.Credential) { $script:SfsuUi.Credential.Password.Dispose(); $script:SfsuUi.Credential=$null }
    if ($null -ne $script:SfsuUi.Logo) { $script:SfsuUi.Logo.Dispose() }
    $script:SfsuUi.VerifiedFont.Dispose()
})
if ($BuildUiOnly) { return $form }
try { [void]$form.ShowDialog() } finally { $form.Dispose() }
