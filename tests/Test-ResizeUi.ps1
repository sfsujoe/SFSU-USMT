# Offscreen native event dispatch plus real WinForms size/font/layout changes.
# No live inventory, LDAP, settings saves or migrations.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/resize-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
foreach ($file in Get-ChildItem (Join-Path $repository 'App/Scripts') -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $testRoot 'App/Scripts') }
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Send-WindowEvent($Window,[string]$Name) {
    $method=[Windows.Forms.Form].GetMethod($Name,[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Window.PSObject.BaseObject,[object[]]@(([EventArgs]::Empty).PSObject.BaseObject))
}
function Save-WindowImage($Window,[string]$Name) {
    $bitmap=New-Object Drawing.Bitmap($Window.Width,$Window.Height)
    try { $Window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height))); $bitmap.Save((Join-Path $testRoot $Name)) } finally { $bitmap.Dispose() }
}
$main=. (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1') -BuildUiOnly
$main.ShowInTaskbar=$false; $main.StartPosition='Manual'; $main.Location=New-Object Drawing.Point(-30000,-30000)
$main.Show(); [Windows.Forms.Application]::DoEvents(); $script:SfsuUi.AppearanceTimer.Stop()
try {
    $originalNotice=$notice.Text
    $initialHeight=$notice.Height; $initialSignature=$script:SfsuUi.MainLayout.Signature
    Send-WindowEvent $main OnResizeBegin
    Assert-True $script:SfsuUi.MainLayout.Interactive 'Native ResizeBegin enables main-window deferral.'
    $notice.Text=('Synthetic wrapping measurement. '*18)
    foreach ($width in @(1080,1000,920,840)) {
        $main.ClientSize=New-Object Drawing.Size($width,700)
        [Windows.Forms.Application]::DoEvents()
        Assert-True ($notice.Height -eq $initialHeight -and $script:SfsuUi.MainLayout.Signature -ceq $initialSignature) 'Intermediate drag sizes do not run custom text measurement.'
    }
    # Native docking is deliberately still live while custom heights stay put.
    Assert-True ($tabs.Width -lt 900) 'Native docking continues during a resize drag.'
    Send-WindowEvent $main OnResizeEnd
    Assert-True (-not $script:SfsuUi.MainLayout.Interactive -and -not $script:SfsuUi.MainLayout.Busy) 'ResizeEnd clears both drag and layout guards.'
    $expected=[Windows.Forms.TextRenderer]::MeasureText($notice.Text,$notice.Font,(New-Object Drawing.Size(($main.ClientSize.Width-$notice.Padding.Horizontal),0)),[Windows.Forms.TextFormatFlags]::WordBreak)
    Assert-True ($notice.Height -eq $expected.Height+$notice.Padding.Vertical+4) 'ResizeEnd measures the final width correctly.'
    Assert-True ($script:SfsuUi.MainLayout.Signature -cne $initialSignature) 'The completed layout records its new inputs.'
    $notice.Text=$originalNotice; Update-SfsuMainLayout
    $main.ClientSize=New-Object Drawing.Size(1120,745); [Windows.Forms.Application]::DoEvents()
    $script:FrozenChanges=0
    $profiles.Add_ColumnStateChanged({param($sender,$event) if ($event.StateChanged -eq [Windows.Forms.DataGridViewElementStates]::Frozen) { $script:FrozenChanges++ }})
    $moveSignature=$script:SfsuUi.MainLayout.Signature
    Send-WindowEvent $main OnResizeBegin
    $main.Location=New-Object Drawing.Point(-29980,-29980)
    Send-WindowEvent $main OnResizeEnd
    Update-SfsuMainLayout
    Assert-True ($script:FrozenChanges -eq 0 -and $script:SfsuUi.MainLayout.Signature -ceq $moveSignature) 'Moving the window and repeated unchanged requests cause no frozen-column churn.'
    $main.ClientSize=New-Object Drawing.Size(1120,780); [Windows.Forms.Application]::DoEvents()
    Assert-True ($script:FrozenChanges -eq 0) 'Height-only resizing keeps unchanged frozen-column states.'
    $profiles.Columns['DisplayName'].Width=400
    $script:FrozenChanges=0
    $main.ClientSize=New-Object Drawing.Size(760,700); [Windows.Forms.Application]::DoEvents()
    Assert-True (-not $profiles.Columns['DisplayName'].Frozen -and $script:FrozenChanges -eq 1) 'Narrowing removes only the surplus frozen column.'
    $script:FrozenChanges=0
    $main.ClientSize=New-Object Drawing.Size(1120,745); [Windows.Forms.Application]::DoEvents()
    Assert-True ($profiles.Columns['DisplayName'].Frozen -and $script:FrozenChanges -eq 1) 'Widening adds only the newly fitting frozen column.'
    $profiles.Columns['DisplayName'].Width=200; Update-SfsuMainLayout
    $notice.Text=('Immediate programmatic resize. '*16)
    $main.ClientSize=New-Object Drawing.Size(820,720); [Windows.Forms.Application]::DoEvents()
    $expected=[Windows.Forms.TextRenderer]::MeasureText($notice.Text,$notice.Font,(New-Object Drawing.Size(($main.ClientSize.Width-$notice.Padding.Horizontal),0)),[Windows.Forms.TextFormatFlags]::WordBreak)
    Assert-True ($notice.Height -eq $expected.Height+$notice.Padding.Vertical+4) 'Programmatic width changes update without ResizeBegin/ResizeEnd.'
    $notice.Text=$originalNotice; Update-SfsuMainLayout
    $main.WindowState='Maximized'; [Windows.Forms.Application]::DoEvents()
    Assert-True ($tabs.ItemSize.Width -eq [Math]::Max(100,[int](($tabs.ClientSize.Width-8)/2))) 'Maximizing updates custom tab sizing immediately.'
    $main.WindowState='Normal'; [Windows.Forms.Application]::DoEvents()
    Assert-True ($tabs.ItemSize.Width -eq [Math]::Max(100,[int](($tabs.ClientSize.Width-8)/2))) 'Restore updates custom tab sizing without a drag.'
    $main.Font=New-Object Drawing.Font('Segoe UI',20)
    Assert-True ($script:SfsuUi.GridFontScale -eq 2 -and $profiles.Columns['SfsuId'].Width -eq 250) 'Font changes outside a drag still resize grid columns immediately.'
    $main.Font=New-Object Drawing.Font('Segoe UI',10)
    $main.ClientSize=New-Object Drawing.Size(1120,745); [Windows.Forms.Application]::DoEvents()
    Save-WindowImage $main 'main-after-resize.png'

    $auth=New-SfsuAuthenticationDialog
    $auth.ShowInTaskbar=$false; $auth.StartPosition='Manual'; $auth.Location=New-Object Drawing.Point(-30000,-30000)
    try {
        $auth.Show(); [Windows.Forms.Application]::DoEvents()
        Assert-True ($auth.ClientSize.Width-$auth.Tag.Authenticate.Right -eq 18) 'The first shown dialog settles its DPI-scaled button placement.'
        $signature=$auth.SfsuLayout.Signature
        Send-WindowEvent $auth OnResizeBegin
        $auth.Location=New-Object Drawing.Point(-29980,-29980)
        Send-WindowEvent $auth OnResizeEnd
        Assert-True (-not $auth.SfsuLayout.UserResized -and $auth.SfsuLayout.Signature -ceq $signature) 'Moving a dialog does not disable automatic content sizing.'
        $inputWidth=$auth.Tag.User.Width; $signature=$auth.SfsuLayout.Signature
        Send-WindowEvent $auth OnResizeBegin
        foreach ($width in @(600,550,500)) {
            $auth.Size=New-Object Drawing.Size($width,550)
            [Windows.Forms.Application]::DoEvents()
            Assert-True ($auth.Tag.User.Width -eq $inputWidth -and $auth.SfsuLayout.Signature -ceq $signature) 'Dialog drag steps defer measured field placement.'
            Assert-True ($auth.Height -eq 550) ('Dialog auto-height does not fight the height being dragged. Actual size: '+$auth.Size+'; drag: '+$auth.SfsuLayout.Interactive)
        }
        Send-WindowEvent $auth OnResizeEnd
        Assert-True ($auth.SfsuLayout.UserResized -and -not $auth.SfsuLayout.Interactive -and $auth.Height -eq 550) 'A completed dialog resize preserves the user-selected height.'
        Assert-True ($auth.Tag.User.Right -eq $auth.ClientSize.Width-18) ('Dialog fields reflow to the final width on ResizeEnd. Client: '+$auth.ClientSize+'; input: '+$auth.Tag.User.Bounds+'; scroll: '+$auth.AutoScrollPosition)
        $auth.ClientSize=New-Object Drawing.Size(620,550)
        Assert-True ($auth.Tag.User.Right -eq $auth.ClientSize.Width-18) 'Programmatic dialog width changes still reflow immediately.'
        $auth.Font=New-Object Drawing.Font('Segoe UI',20)
        Assert-True ($auth.Tag.User.Left -eq 36 -and $auth.Tag.User.Right -eq $auth.ClientSize.Width-36) 'Font changes remeasure a user-resized dialog without a drag.'
        Save-WindowImage $auth 'authentication-after-resize.png'
    } finally { $auth.Dispose() }

    $auth=New-SfsuAuthenticationDialog
    try {
        $auth.ShowInTaskbar=$false; $auth.StartPosition='Manual'; $auth.Location=New-Object Drawing.Point(-30000,-30000); $auth.Show(); [Windows.Forms.Application]::DoEvents()
        $start=$auth.Size; $signature=$auth.SfsuLayout.Signature
        Send-WindowEvent $auth OnResizeBegin
        $auth.Width+=80; $auth.Size=$start
        Send-WindowEvent $auth OnResizeEnd
        Assert-True (-not $auth.SfsuLayout.UserResized -and $auth.SfsuLayout.Signature -ceq $signature) 'A cancelled resize returning to its start size needs no final remeasurement.'
        Send-WindowEvent $auth OnResizeBegin
        $auth.Font=New-Object Drawing.Font('Segoe UI',15)
        Assert-True ($auth.SfsuLayout.Signature -ceq $signature) 'Font changes during a drag are deferred with other custom measurements.'
        Send-WindowEvent $auth OnResizeEnd
        Assert-True ($auth.SfsuLayout.Signature -cne $signature -and $auth.Tag.User.Left -eq 27) 'Deferred font changes are applied when the drag ends.'
    } finally { $auth.Dispose() }
    Assert-True (-not $script:SfsuUi.MainLayout.Busy -and $script:SfsuUi.Dialogs.Count -eq 0) 'Layout guards and dialog tracking finish cleanly.'
    Assert-True (-not (Test-Path (Join-Path $testRoot 'App/Settings')) -and -not (Test-Path (Join-Path $testRoot 'Logs'))) 'Resize tests create no preferences or action logs.'
} finally { $main.Dispose() }
# Exercise the real non-BuildUiOnly startup branch in a separate process. Replace
# only its final display call in the isolated copy, so no visible window or AD
# startup handler runs. This checks startup configuration, not a live AD launch.
$uiPath=Join-Path $testRoot 'App/Scripts/Sfsu.Ui.ps1'
$uiSource=[IO.File]::ReadAllText($uiPath)
$showCall='try { [void]$form.ShowDialog() } finally { $form.Dispose() }'
if (-not $uiSource.Contains($showCall)) { throw 'Startup display fixture seam not found.' }
$startupProbe=@'
try {
    $startupAuth=New-SfsuAuthenticationDialog
    try {
        [IO.File]::WriteAllText((Join-Path $packageRoot 'startup-probe.json'),(ConvertTo-Json @{
            MainWindow=[string]$form.WindowState; AuthenticationWindow=[string]$startupAuth.WindowState; AuthenticationPosition=[string]$startupAuth.StartPosition
        }))
    } finally { $startupAuth.Dispose() }
} finally { $form.Dispose() }
'@
[IO.File]::WriteAllText($uiPath,$uiSource.Replace($showCall,$startupProbe))
& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1')
Assert-True ($LASTEXITCODE -eq 0) 'The normal startup configuration probe exits cleanly without displaying the GUI.'
$startup=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $testRoot 'startup-probe.json')))
Assert-True ($startup.MainWindow -eq 'Maximized' -and $startup.AuthenticationWindow -eq 'Normal' -and $startup.AuthenticationPosition -eq 'CenterParent') 'Normal startup maximizes the main window while keeping authentication normal and centered.'
Write-Output ("PASS: $script:Assertions assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
