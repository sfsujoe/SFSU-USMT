# Offscreen UI fixtures with synthetic names/passwords. No migration action runs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$root=Join-Path $PSScriptRoot ('.work/migration-ui-'+[guid]::NewGuid().ToString('N').Substring(0,8)); [void][IO.Directory]::CreateDirectory($root)
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert-True $failed $Message }
function Save-Dialog($Dialog,[string]$Name) {
    $bitmap=New-Object Drawing.Bitmap($Dialog.Width,$Dialog.Height)
    try { $Dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $root $Name)) } finally { $bitmap.Dispose() }
}
$main=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
try {
    $main.ShowInTaskbar=$false; $main.StartPosition='Manual'; $main.Location=New-Object Drawing.Point(-30000,-30000); $main.Show(); [Windows.Forms.Application]::DoEvents()
    Assert-True ($prepare.Text -eq 'Back up selected profiles' -and $review.Text -eq 'Restore selected backups') 'The main actions clearly invoke capture and restore rather than preparation-only operations.'
    $plan=[pscustomobject]@{AccountName='SyntheticLocal';DisplayName='Synthetic Employee';LocalOptions=$null}
    $dialog=New-SfsuLocalRestoreDialog $plan
    Assert-True ($dialog.Tag.Password.UseSystemPasswordChar -and $dialog.Tag.Confirm.UseSystemPasswordChar -and $dialog.Tag.Password.MaxLength -eq 256) 'Each account has bounded masked password and confirmation fields.'
    Assert-True ($dialog.Tag.Enabled.SelectedIndex -eq -1 -and $dialog.Tag.Administrator.SelectedIndex -eq 0) 'Enablement requires an explicit choice; administrator membership defaults to No.'
    $dialog.Add_Shown({
        param($sender,$event)
        $state=$sender.Tag
        $sender.AcceptButton.PerformClick(); Assert-True ($state.Error.Text -match 'nonempty') 'Empty passwords cannot advance.'
        $state.Password.Text='Synthetic-Password!19'; $state.Confirm.Text='different'
        $sender.AcceptButton.PerformClick(); Assert-True ($state.Error.Text -match 'identical') 'Mismatched password confirmation cannot advance.'
        $state.Confirm.Text=$state.Password.Text
        $sender.AcceptButton.PerformClick(); Assert-True ($state.Error.Text -match 'Choose whether') 'A password alone cannot silently choose account enablement.'
        $state.Enabled.SelectedIndex=0
        Save-Dialog $sender 'local-account-normal.png'
        $sender.AcceptButton.PerformClick()
    })
    try {
        Assert-True ($dialog.ShowDialog($main) -eq 'OK') 'A complete per-account choice set can be accepted.'
        Assert-True (-not $dialog.Tag.Options.Enabled -and -not $dialog.Tag.Options.Administrator -and $dialog.Tag.Options.Password.IsReadOnly()) 'Disabled/standard choices and a read-only SecureString are transferred independently.'
        Assert-True (-not $dialog.Tag.Password.Text -and -not $dialog.Tag.Confirm.Text) 'Accepted passwords are cleared from both text fields.'
        $plan.LocalOptions=$dialog.Tag.Options; $dialog.Tag.Options=$null
    } finally { $dialog.Dispose() }
    $secret=$plan.LocalOptions.Password; Clear-SfsuRestorePasswords @($plan)
    Assert-True ($null -eq $plan.LocalOptions.Password) 'Completed/cancelled plan cleanup clears the retained secret reference.'
    Assert-Throws { $secret.Copy() } 'The transferred SecureString is disposed during cleanup.'

    $dialog=New-SfsuLocalRestoreDialog $plan
    $dialog.Add_Shown({param($sender,$event) $sender.Tag.Password.Text='Another-Synthetic!42'; $sender.Tag.Confirm.Text=$sender.Tag.Password.Text; $sender.Tag.Enabled.SelectedIndex=1; $sender.Tag.Administrator.SelectedIndex=1; $sender.AcceptButton.PerformClick()})
    try { [void]$dialog.ShowDialog($main); Assert-True ($dialog.Tag.Options.Enabled -and $dialog.Tag.Options.Administrator) 'Enabled/administrator choices are supported separately for each account.' } finally { $dialog.Dispose() }
    $dialog=New-SfsuLocalRestoreDialog $plan
    $dialog.Add_Shown({param($sender,$event) $sender.Tag.Password.Text='Cancel-Synthetic!55'; $sender.Tag.Confirm.Text=$sender.Tag.Password.Text; $sender.CancelButton.PerformClick()})
    try { Assert-True ($dialog.ShowDialog($main) -eq 'Cancel' -and $null -eq $dialog.Tag.Options -and -not $dialog.Tag.Password.Text -and -not $dialog.Tag.Confirm.Text) 'Cancelling an account dialog clears its inputs and produces no account settings.' } finally { $dialog.Dispose() }

    $profile=[pscustomobject]@{ProfilePath='C:\Users\Synthetic';DisplayName='Synthetic Employee'}
    $reviewPlan=[pscustomobject]@{Profile=$profile;CloudRoots=@([pscustomobject]@{Path='D:\Cloud & Files';Source='synthetic provider'});BrowserRoots=@();RedirectedFolders=@('Personal: D:\Cloud & Files\Documents');Issues=@('Review custom cloud locations.');Reviewed=$false;AdditionalCloudRoots=@();AdditionalBrowserRoots=@()}
    $dialog=New-SfsuCaptureLocationDialog $reviewPlan
    $dialog.Add_Shown({
        param($sender,$event)
        $sender.AcceptButton.PerformClick(); Assert-True ($sender.Tag.Error.Text -match 'Confirm') 'Capture requires an explicit location review.'
        $sender.Tag.Cloud.Text='D:\Additional cloud'; $sender.Tag.Browser.Text='Firefox|D:\Custom Firefox'; $sender.Tag.Confirmed.Checked=$true
        Save-Dialog $sender 'capture-locations-normal.png'
        $sender.AcceptButton.PerformClick()
    })
    try {
        Assert-True ($dialog.ShowDialog($main) -eq 'OK' -and $reviewPlan.Reviewed -and $reviewPlan.AdditionalCloudRoots.Count -eq 1 -and $reviewPlan.AdditionalBrowserRoots.Count -eq 1) 'Reviewed custom cloud and browser roots are attached to the selected profile.'
    } finally { $dialog.Dispose() }

    # Render both forms in the shared dark theme with 200% text. Layout uses the
    # existing scrollable/accessibility framework and does not save preferences.
    $script:SfsuUi.ThemeId='Dark'; $script:SfsuUi.TextScale=200; Update-SfsuAppearance
    foreach ($kind in @('local','locations')) {
        $dialog=if ($kind -eq 'local') { New-SfsuLocalRestoreDialog $plan } else { New-SfsuCaptureLocationDialog $reviewPlan }
        $dialog.Add_Shown({param($sender,$event) Update-SfsuDialogLayout $sender -Force; Save-Dialog $sender ($sender.Text.Replace(' ','-')+'-large.png'); $sender.DialogResult='Cancel'; $sender.Close()})
        try { [void]$dialog.ShowDialog($main); Assert-True ($dialog.AutoScroll -and $dialog.SfsuLayout.Rows.Count -gt 0 -and $dialog.AccessibleName -eq $dialog.Text) 'Large-text migration dialogs keep measured scrollable layout and an accessible name.' } finally { $dialog.Dispose() }
    }
} finally { $main.Dispose() }
Write-Output ("PASS: $script:Assertions migration-UI assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$root)
