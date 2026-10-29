# Offscreen dialog tests on Windows PowerShell 5.1. All LDAP responses are synthetic.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/auth-ui-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Reporting'))
Copy-Item (Join-Path $repository 'App/Reporting/report.template.html') (Join-Path $testRoot 'App/Reporting/report.template.html')
Copy-Item (Join-Path $repository 'App/Scripts/Sfsu.Logging.psm1') (Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1')
$fixture=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Sfsu.Inventory.psm1'))+@'

# Test-only connection fixture. The shipped module never contains this override.
function New-SfsuDirectorySession {
    param($Server,$Credential)
    if ($Credential.GetNetworkCredential().Password -eq 'wrong') { throw (New-Object DirectoryServices.Protocols.LdapException(49)) }
    if ($Credential.GetNetworkCredential().Password -eq 'wait') { Start-Sleep -Seconds 20 }
    $connection=New-Object psobject
    $connection | Add-Member ScriptMethod Dispose {}
    [pscustomobject]@{Connection=$connection;SearchBase='DC=example,DC=invalid';Server=$Server}
}
function Get-SfsuWindowsIdentityName { 'SYNTHETIC-LAPTOP\LocalAdmin' }
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'App/Scripts/Sfsu.Inventory.psm1'),$fixture)
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++
}
$main=. (Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
$script:SfsuUi.Root=$testRoot
$main.ShowInTaskbar=$false; $main.StartPosition='Manual'; $main.Location=New-Object Drawing.Point(-30000,-30000)
$main.Show()
try {
    foreach ($case in @('validation','retry','cancel','accept-flow')) {
        $dialog=New-SfsuAuthenticationDialog
        $dialog.StartPosition='Manual'; $dialog.Location=New-Object Drawing.Point(-30000,-30000); $dialog.ShowInTaskbar=$false
        $script:AuthCase=[pscustomobject]@{Kind=$case;Dialog=$dialog;Stage=0;Error='';Deadline=[DateTime]::UtcNow.AddSeconds(15);FailureSeen=$false}
        $driver=New-Object Windows.Forms.Timer; $driver.Interval=50
        $driver.Add_Tick({
            $c=$script:AuthCase; $s=$c.Dialog.Tag
            try {
                if ([DateTime]::UtcNow -gt $c.Deadline) { throw 'Authentication dialog timed out.' }
                if ($c.Stage -eq 0) {
                    $c.Stage=1
                    Assert-True ($s.Form.Text -eq 'Authenticate to Active Directory') 'Dialog title is exact.'
                    Assert-True (@($s.Form.Controls | Where-Object Text -eq 'Enter your SFSU ID and password').Count -eq 1) 'Dialog message is exact.'
                    Assert-True ($s.Authenticate.Text -eq 'Authenticate' -and $s.Continue.Text -eq 'Continue without AD') 'Both action labels are exact.'
                    Assert-True ($s.Authenticate.Left -gt $s.Continue.Right -and $s.Authenticate.Top -eq $s.Continue.Top -and $s.Form.ClientSize.Width-$s.Authenticate.Right -eq 18) 'Authenticate is bottom right, with Continue without AD immediately to its left.'
                    Assert-True ($s.Form.AcceptButton -eq $s.Authenticate -and $s.Password.UseSystemPasswordChar) 'Enter authenticates and password entry is masked.'
                    if ($c.Kind -eq 'validation') {
                        $s.User.Text='person@sfsu.edu'
                        Assert-True ($s.Hint.Text -eq 'Enter your SFSU ID, not your email address.') 'An email address immediately shows the SFSU ID hint.'
                        $s.Password.Text='synthetic'
                        $s.Authenticate.PerformClick()
                        Assert-True ($null -eq $s.Worker -and $s.Form.DialogResult -eq 'None') 'Invalid login does not start a connection or close the dialog.'
                        $s.User.Text='000000123'; $s.Password.Clear(); $s.Authenticate.PerformClick()
                        Assert-True ($s.Hint.Text -eq 'Enter your password.' -and $null -eq $s.Worker) 'Blank passwords are rejected before authentication.'
                        $bitmap=New-Object Drawing.Bitmap($s.Form.Width,$s.Form.Height)
                        try { $s.Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot 'authentication.png')) } finally { $bitmap.Dispose() }
                        $s.Continue.PerformClick()
                    } else {
                        $s.User.Text='000000123'
                        if ($c.Kind -eq 'retry') { $s.Password.Text='wrong' }
                        elseif ($c.Kind -eq 'cancel') { $s.Password.Text='wait' }
                        else { $s.Password.Text='synthetic-good-password' }
                        $s.Authenticate.PerformClick()
                        Assert-True ($null -ne $s.Worker -and -not $s.Authenticate.Enabled -and -not $s.Password.Text) 'Authentication runs in the background with double submission disabled and the password box cleared.'
                    }
                } elseif ($c.Kind -eq 'retry' -and $c.Stage -eq 1 -and $null -eq $s.Worker) {
                    Assert-True ($s.Hint.Text -match 'Authentication failed' -and -not $s.Succeeded -and $null -eq $s.Credential) 'Rejected credentials leave the dialog open for retry and discard the failed password.'
                    $c.FailureSeen=$true; $c.Stage=2
                    $s.Password.Text='synthetic-good-password'; $s.Authenticate.PerformClick()
                } elseif ($c.Kind -eq 'cancel' -and $c.Stage -eq 1) {
                    $c.Stage=2; $s.Continue.PerformClick()
                }
            } catch { $c.Error=$_.Exception.Message; $c.Dialog.Close() }
        })
        $driver.Start()
        try {
            if ($case -eq 'accept-flow') {
                $script:WrappedDialog=$dialog
                $savedDialogFunction=${function:New-SfsuAuthenticationDialog}; $savedStartFunction=${function:Start-SfsuUiTask}
                function New-SfsuAuthenticationDialog { $script:WrappedDialog }
                function Start-SfsuUiTask { param($Action,$Items) $script:AuthenticatedAction=$Action }
                try { Show-SfsuDirectoryCredentials }
                finally { Set-Item function:New-SfsuAuthenticationDialog $savedDialogFunction; Set-Item function:Start-SfsuUiTask $savedStartFunction }
                Assert-True ($script:SfsuUi.UseDirectory -and $script:SfsuUi.Credential.UserName -eq '000000123@sfsu.edu' -and $script:AuthenticatedAction -eq 'Discover profiles') 'Verified credentials transfer into app state before discovery starts.'
                Assert-True ($script:SfsuUi.Credential.GetNetworkCredential().Password -eq 'synthetic-good-password') 'Dialog disposal does not dispose the successfully transferred app-session credential.'
            } else { $result=$dialog.ShowDialog($main) }
            if ($script:AuthCase.Error) { throw $script:AuthCase.Error }
            if ($case -eq 'retry') {
                Assert-True ($result -eq 'OK' -and $dialog.Tag.Succeeded -and $script:AuthCase.FailureSeen) 'A successful retry closes the dialog only after LDAP verification.'
                Assert-True ($dialog.Tag.Credential.UserName -ceq '000000123@sfsu.edu') 'The submitted bare ID becomes a full login, preserving leading zeros.'
                Assert-True (Test-Path -LiteralPath $dialog.Tag.ReportPath) 'The verified authentication has its own real report.'
                Assert-True (-not [IO.File]::ReadAllText($dialog.Tag.ReportPath).Contains('synthetic-good-password')) 'Authentication reports do not contain the submitted password.'
            } elseif ($case -ne 'accept-flow') {
                Assert-True ($result -eq 'Cancel' -and -not $dialog.Tag.Succeeded -and $null -eq $dialog.Tag.Credential) 'Continue without AD never returns an authenticated credential, including during an active attempt.'
            }
        } finally { $driver.Stop(); $driver.Dispose(); $dialog.Dispose() }
    }
} finally { $main.Dispose() }
Write-Output ("PASS: $script:Assertions assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
