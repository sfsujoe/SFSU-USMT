# Windows PowerShell 5.1. Preferences are stored only in the portable toolkit.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-SfsuThemeCatalog {
    @(
        [pscustomobject]@{Id='Classic';Name='SFSU Classic'}, [pscustomobject]@{Id='Ocean';Name='SFSU Ocean'},
        [pscustomobject]@{Id='Forest';Name='SFSU Forest'}, [pscustomobject]@{Id='Warm';Name='SFSU Warm'},
        [pscustomobject]@{Id='Dark';Name='Dark Mode'}, [pscustomobject]@{Id='System';Name='Windows system colors'}
    )
}

function Read-SfsuAppearancePreference([string]$PackageRoot) {
    $result=[pscustomobject]@{ThemeId='Classic';TextScale=100;Warning=''}
    $directory=Join-Path $PackageRoot 'App/Settings'
    $path=Join-Path $directory 'appearance.json'
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $result }
        foreach ($itemPath in @($directory,$path)) {
            $item=Get-Item -LiteralPath $itemPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked preference paths are not supported.' }
        }
        $file=Get-Item -LiteralPath $path
        if ($file.PSIsContainer -or $file.Length -gt 4096) { throw 'Invalid preference file.' }
        $data=ConvertFrom-Json ([IO.File]::ReadAllText($path))
        if ($data.SchemaVersion -ne 1 -or $data.ThemeId -cnotin @(Get-SfsuThemeCatalog | ForEach-Object Id)) { throw 'Unknown preference version or theme.' }
        if ($data.PSObject.Properties['TextScale'] -and $data.TextScale -notin @(100,125,150,200)) { throw 'Unknown text size.' }
        $result.ThemeId=[string]$data.ThemeId
        if ($data.PSObject.Properties['TextScale']) { $result.TextScale=[int]$data.TextScale }
    } catch { $result.Warning='The saved theme could not be read. SFSU Classic is being used; choose a theme to save a new preference.' }
    $result
}

function Save-SfsuAppearancePreference([string]$PackageRoot,[string]$ThemeId,[int]$TextScale=100) {
    if ($ThemeId -cnotin @(Get-SfsuThemeCatalog | ForEach-Object Id)) { throw 'Choose a supported theme.' }
    if ($TextScale -notin @(100,125,150,200)) { throw 'Choose a supported text size.' }
    $directory=Join-Path $PackageRoot 'App/Settings'
    [void][IO.Directory]::CreateDirectory($directory)
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked preference directories are not supported.' }
    $path=Join-Path $directory 'appearance.json'
    $lockPath=Join-Path $directory 'appearance.lock'
    $temporary=Join-Path $directory ('.appearance-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $lock=$null
    try {
        # Serialize simultaneous saves from technicians sharing the toolkit.
        if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked preference locks are not supported.' }
        for ($attempt=0; $attempt -lt 3; $attempt++) {
            try {
                $lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
                break
            } catch [IO.IOException] { if ($attempt -eq 2) { throw }; Start-Sleep -Milliseconds 50 }
        }
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked preference files are not supported.' }
        }
        $json=ConvertTo-Json ([ordered]@{SchemaVersion=1;ThemeId=$ThemeId;TextScale=$TextScale}) -Compress
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $path) {
            # Some SMB destinations reject Replace. Keep all temporary files here,
            # with a bounded overwrite fallback; invalid interrupted files load Classic.
            try { [IO.File]::Replace($temporary,$path,[NullString]::Value) }
            catch {
                if ($_.Exception.GetBaseException() -isnot [IO.IOException] -and
                    $_.Exception.GetBaseException() -isnot [UnauthorizedAccessException] -and
                    $_.Exception.GetBaseException() -isnot [NotSupportedException]) { throw }
                for ($attempt=0; $attempt -lt 3; $attempt++) {
                    try { [IO.File]::Copy($temporary,$path,$true); break }
                    catch { if ($attempt -eq 2) { throw }; Start-Sleep -Milliseconds 50 }
                }
            }
        } else { [IO.File]::Move($temporary,$path) }
    } finally {
        try { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        finally { if ($null -ne $lock) { $lock.Dispose() } }
    }
}

function Get-SfsuThemePalette([string]$ThemeId='Classic',[bool]$HighContrast=[Windows.Forms.SystemInformation]::HighContrast) {
    $native=$HighContrast -or $ThemeId -eq 'System'
    if ($native) {
        return [pscustomobject]@{Native=$true;HighContrast=$HighContrast;Background=[Drawing.SystemColors]::Window;Foreground=[Drawing.SystemColors]::WindowText
            Surface=[Drawing.SystemColors]::Control;Header=[Drawing.SystemColors]::Control;HeaderText=[Drawing.SystemColors]::ControlText;Title=[Drawing.SystemColors]::ControlText
            Accent=[Drawing.SystemColors]::Highlight;AccentText=[Drawing.SystemColors]::HighlightText;Border=[Drawing.SystemColors]::WindowText
            Warning=[Drawing.SystemColors]::Window;WarningText=[Drawing.SystemColors]::WindowText}
    }
    $values=@{
        Classic=@('#FFFFFF','#202020','#F3F1F8','#442C8B','#FFFFFF','#FFD24F','#442C8B','#FFFFFF','#717171','#FFE2B4','#202020')
        Ocean=@('#FFFFFF','#202020','#EAF4F9','#044361','#FFFFFF','#FFFFFF','#044361','#FFFFFF','#61727C','#FFE2B4','#202020')
        Forest=@('#FFFFFF','#202020','#EAF5F0','#005755','#FFFFFF','#FFFFFF','#005755','#FFFFFF','#61736C','#FFE2B4','#202020')
        Warm=@('#F6F0D6','#202020','#FFE2B4','#6E5D53','#F6F0D6','#F6F0D6','#6E5D53','#FFFFFF','#6E5D53','#FAC4CB','#202020')
        Dark=@('#18181B','#F4F4F5','#27272A','#27272A','#F4F4F5','#F4F4F5','#70B3D7','#18181B','#A1A1AA','#3B3021','#F4F4F5')
    }
    if (-not $values.ContainsKey($ThemeId)) { $ThemeId='Classic' }
    $palette=[ordered]@{Native=$false;HighContrast=$false}
    $names=@('Background','Foreground','Surface','Header','HeaderText','Title','Accent','AccentText','Border','Warning','WarningText')
    for ($i=0;$i -lt $names.Count;$i++) { $palette[$names[$i]]=[Drawing.ColorTranslator]::FromHtml($values[$ThemeId][$i]) }
    [pscustomobject]$palette
}

function Set-SfsuControlPalette($Control,$Palette) {
    $Control.BackColor=$Palette.Background; $Control.ForeColor=$Palette.Foreground
    if ($Control.Name -in @('ThemeFooter','ThemeSurface')) { $Control.BackColor=$Palette.Surface }
    if ($Control.Name -eq 'ThemeHeader') { $Control.BackColor=$Palette.Header; $Control.ForeColor=$Palette.HeaderText }
    if ($Control.Name -eq 'ThemeNotice') { $Control.BackColor=$Palette.Warning; $Control.ForeColor=$Palette.WarningText }
    if ($Control -is [Windows.Forms.Label] -and $null -ne $Control.Parent -and $Control.Name -ne 'ThemeNotice') {
        $Control.BackColor=$Control.Parent.BackColor; $Control.ForeColor=$Control.Parent.ForeColor
    }
    if ($Control.Name -eq 'ThemeTitle') { $Control.ForeColor=$Palette.Title }
    if ($Control -is [Windows.Forms.LinkLabel]) {
        # Underlining and native focus identify the link without color alone.
        $Control.LinkColor=$Control.ForeColor; $Control.ActiveLinkColor=$Control.ForeColor
        $Control.VisitedLinkColor=$Control.ForeColor; $Control.DisabledLinkColor=$Control.ForeColor
    }
    if ($Control.Name -eq 'ThemeLogo') { $Control.BackColor=$Palette.Header; $Control.Visible=-not $Palette.Native }
    if ($Control.Name -eq 'ThemeTextLogo') { $Control.Visible=$Palette.Native }
    if ($Control -is [Windows.Forms.Button]) {
        $Control.UseVisualStyleBackColor=$Palette.Native
        if ($Palette.Native) { $Control.FlatStyle='Standard' }
        else {
            $Control.FlatStyle='Flat'; $Control.FlatAppearance.BorderColor=$Palette.Border
            $Control.FlatAppearance.MouseOverBackColor=$Palette.Surface; $Control.FlatAppearance.MouseDownBackColor=$Palette.Surface
            if ($Control.Name -eq 'PrimaryAction') {
                $Control.BackColor=$Palette.Accent; $Control.ForeColor=$Palette.AccentText
                $Control.FlatAppearance.BorderColor=$Palette.Accent
                $Control.FlatAppearance.MouseOverBackColor=$Palette.Accent; $Control.FlatAppearance.MouseDownBackColor=$Palette.Accent
            }
        }
    }
    if ($Control -is [Windows.Forms.CheckBox]) { $Control.UseVisualStyleBackColor=$Palette.Native }
    if ($Control -is [Windows.Forms.TabControl]) {
        if ($Palette.Native) { $Control.DrawMode='Normal' } else { $Control.DrawMode='OwnerDrawFixed' }
    }
    if ($Control -is [Windows.Forms.ComboBox]) {
        if ($Palette.Native) { $Control.DrawMode='Normal' } else { $Control.DrawMode='OwnerDrawFixed' }
    }
    if ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor=$Palette.Background; $Control.GridColor=$Palette.Border
        $Control.EnableHeadersVisualStyles=$Palette.Native
        foreach ($style in @($Control.DefaultCellStyle,$Control.RowsDefaultCellStyle,$Control.AlternatingRowsDefaultCellStyle,$Control.ColumnHeadersDefaultCellStyle,$Control.RowHeadersDefaultCellStyle)) {
            $style.BackColor=$Palette.Background; $style.ForeColor=$Palette.Foreground
            $style.SelectionBackColor=$Palette.Accent; $style.SelectionForeColor=$Palette.AccentText
        }
        $Control.ColumnHeadersDefaultCellStyle.BackColor=$Palette.Surface
        foreach ($column in $Control.Columns) {
            $column.DefaultCellStyle.ForeColor=$Palette.Foreground
            $column.DefaultCellStyle.SelectionBackColor=$Palette.Accent; $column.DefaultCellStyle.SelectionForeColor=$Palette.AccentText
        }
        foreach ($row in $Control.Rows) {
            $row.DefaultCellStyle.BackColor=$Palette.Background; $row.DefaultCellStyle.ForeColor=$Palette.Foreground
            if ($null -ne $row.Tag -and $row.Tag.PSObject.Properties['IdentitySource'] -and $row.Tag.IdentitySource -ne 'LDAP') {
                $row.DefaultCellStyle.BackColor=$Palette.Warning; $row.DefaultCellStyle.ForeColor=$Palette.WarningText
            }
        }
    } else { foreach ($child in $Control.Controls) { Set-SfsuControlPalette $child $Palette } }
    $Control.Invalidate()
}

function Initialize-SfsuAccessibleStatus($Label,[string]$Role='StatusBar') {
    $Label.AccessibleRole=$Role; $Label.AccessibleName=$Label.Text
    if ($Label.PSObject.Properties['LiveSetting']) { $Label.LiveSetting='Polite' }
    $Label.Add_TextChanged({
        param($sender,$event)
        $sender.AccessibleName=$sender.Text
        if ($sender.IsHandleCreated -and $sender.Text -and $sender.AccessibilityObject.PSObject.Methods['RaiseAutomationNotification']) {
            [void]$sender.AccessibilityObject.RaiseAutomationNotification(
                [Windows.Forms.Automation.AutomationNotificationKind]::Other,
                [Windows.Forms.Automation.AutomationNotificationProcessing]::ImportantMostRecent,$sender.Text)
        }
    })
}

# Dialogs keep real native controls and their tab order. Measure wrapped labels,
# input heights and button text at the current font instead of fixed pixel rows.
function Get-SfsuDialogLayoutSignature($Form) {
    $layout=$Form.SfsuLayout
    $values=@($Form.ClientSize.Width,$Form.Font.Name,$Form.Font.SizeInPoints,$Form.Font.Height,$Form.AutoScaleDimensions,$Form.DeviceDpi,$layout.UserResized)
    foreach ($row in $layout.Rows) {
        $values+=@($row.Control.Font.Name,$row.Control.Font.SizeInPoints,$row.Control.Font.Height)
        if ($row.Control -is [Windows.Forms.Label] -or $row.Control -is [Windows.Forms.CheckBox]) { $values+=$row.Control.Text }
    }
    foreach ($button in $layout.Buttons) { $values+=@($button.Text,$button.Font.Name,$button.Font.SizeInPoints,$button.Font.Height) }
    $values -join '|'
}

function Update-SfsuDialogLayout($Form,[switch]$Force) {
    if ($Form.IsDisposed -or -not $Form.PSObject.Properties['SfsuLayout']) { return }
    $layout=$Form.SfsuLayout
    if ($layout.Busy -or $layout.Interactive -or $Form.WindowState -eq 'Minimized') { return }
    $signature=Get-SfsuDialogLayoutSignature $Form
    if (-not $Force -and $signature -ceq $layout.Signature) { return }
    $layout.Busy=$true
    # Measure in logical (unscrolled) coordinates. Stale wide controls can cause
    # temporary horizontal scrolling while measurements are deferred in a drag.
    $scrollY=-$Form.AutoScrollPosition.Y
    $Form.AutoScrollPosition=New-Object Drawing.Point(0,0)
    $Form.SuspendLayout()
    try {
        $clientWidth=$Form.ClientSize.Width
        $scale=[Math]::Max(1.0,$Form.Font.SizeInPoints/10.0)
        $margin=[int](18*$scale); $gap=[int](8*$scale); $y=$margin
        $width=[Math]::Max(200,$Form.ClientSize.Width-2*$margin)
        foreach ($row in $layout.Rows) {
            $c=$row.Control
            if ($row.ContainsKey('HideWhenEmpty')) {
                $show=-not [string]::IsNullOrWhiteSpace($c.Text)
                $c.Visible=$show
                if (-not $show) { continue }
            }
            if ($row.Kind -eq 'Label') {
                $size=[Windows.Forms.TextRenderer]::MeasureText($c.Text,$c.Font,(New-Object Drawing.Size($width,0)),[Windows.Forms.TextFormatFlags]::WordBreak)
                $height=[Math]::Max([int]($row.Lines*$c.Font.Height),$size.Height+4)
            } elseif ($row.Kind -eq 'Preview') { $height=$Form.Font.Height*3+12 }
            elseif ($c -is [Windows.Forms.CheckBox]) {
                $size=[Windows.Forms.TextRenderer]::MeasureText($c.Text,$c.Font,(New-Object Drawing.Size(($width-32),0)),[Windows.Forms.TextFormatFlags]::WordBreak)
                $height=[Math]::Max([int](30*$scale),$size.Height+8)
            }
            else { $height=[Math]::Max($c.PreferredSize.Height,[int](30*$scale)) }
            $c.SetBounds($margin,$y,$width,$height); $y+=$height+$gap
        }
        $y+=$gap
        $right=$Form.ClientSize.Width-$margin; $buttonHeight=[int](36*$scale)
        $buttonWidths=@()
        foreach ($button in $layout.Buttons) {
            $size=[Windows.Forms.TextRenderer]::MeasureText($button.Text,$button.Font)
            $buttonWidths+=[int][Math]::Min($width,[Math]::Max([int](120*$scale),$size.Width+32))
        }
        if (($buttonWidths | Measure-Object -Sum).Sum+$gap*($layout.Buttons.Count-1) -le $width) {
            for ($i=$layout.Buttons.Count-1;$i -ge 0;$i--) {
                $layout.Buttons[$i].SetBounds($right-$buttonWidths[$i],$y,$buttonWidths[$i],$buttonHeight); $right-=$buttonWidths[$i]+$gap
            }
        } else {
            # When buttons wrap, keep their visual and keyboard order aligned,
            # with the primary action last and at the bottom right.
            for ($i=0;$i -lt $layout.Buttons.Count;$i++) {
                $layout.Buttons[$i].SetBounds($right-$buttonWidths[$i],$y,$buttonWidths[$i],$buttonHeight)
                if ($i -lt $layout.Buttons.Count-1) { $y+=$buttonHeight+$gap }
            }
        }
        $height=$y+$buttonHeight+$margin
        $Form.AutoScrollMinSize=New-Object Drawing.Size(0,$height)
        if (-not $layout.UserResized) {
            $screen=[Windows.Forms.Screen]::FromControl($Form).WorkingArea
            $targetHeight=[Math]::Min($height,[Math]::Max(300,$screen.Height-90))
            $Form.Height=$targetHeight+($Form.Height-$Form.ClientSize.Height)
        }
    } finally {
        try {
            $Form.ResumeLayout($true)
            if ($scrollY -gt 0) { $Form.AutoScrollPosition=New-Object Drawing.Point(0,$scrollY) }
        } finally { $layout.Busy=$false }
    }
    $layout.Signature=$signature
    if ($Form.ClientSize.Width -ne $clientWidth) { Update-SfsuDialogLayout $Form }
}

function Initialize-SfsuDialogLayout($Form,[object[]]$Rows,[object[]]$Buttons) {
    $Form.AutoScroll=$true; $Form.AutoScaleMode='Dpi'; $Form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
    $Form.FormBorderStyle='Sizable'; $Form.MinimumSize=New-Object Drawing.Size(460,300)
    $Form.AccessibleName=$Form.Text
    $Form | Add-Member NoteProperty SfsuLayout ([pscustomobject]@{Rows=$Rows;Buttons=$Buttons;Busy=$false;UserResized=$false;Interactive=$false;StartSize=$Form.Size;Signature=''})
    $index=0
    foreach ($row in $Rows) { $row.Control.TabIndex=$index; $index++; if ($row.Control -is [Windows.Forms.Label]) { $row.Control.TabStop=$false } }
    foreach ($button in $Buttons) { $button.AutoSize=$false; $button.MinimumSize=New-Object Drawing.Size(0,0); $button.TabIndex=$index; $button.AccessibleName=$button.Text; $index++ }
    $Form.Add_Resize({param($sender,$event) Update-SfsuDialogLayout $sender})
    $Form.Add_ResizeBegin({param($sender,$event) $sender.SfsuLayout.StartSize=$sender.Size; $sender.SfsuLayout.Interactive=$true})
    $Form.Add_ResizeEnd({
        param($sender,$event)
        $s=$sender.SfsuLayout
        if ($s.Interactive -and $sender.Size -ne $s.StartSize) { $s.UserResized=$true }
        $s.Interactive=$false
        Update-SfsuDialogLayout $sender
    })
    $Form.Add_FontChanged({param($sender,$event) Update-SfsuDialogLayout $sender})
    $Form.Add_Shown({param($sender,$event) Update-SfsuDialogLayout $sender -Force})
    Update-SfsuDialogLayout $Form
}

Export-ModuleMember -Function Get-SfsuThemeCatalog,Read-SfsuAppearancePreference,Save-SfsuAppearancePreference,
    Get-SfsuThemePalette,Set-SfsuControlPalette,Initialize-SfsuAccessibleStatus,Initialize-SfsuDialogLayout,Update-SfsuDialogLayout
