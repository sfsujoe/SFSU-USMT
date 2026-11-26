# Modeless, room-visible monitor. Only the UI thread touches these controls.
if (-not ('Sfsu.Ui.ProgressPie' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Sfsu.Progress.Native.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
}

function Set-SfsuProgressWindowAppearance($Window) {
    if ($null -eq $Window -or $Window.IsDisposed) { return }
    Set-SfsuControlPalette $Window $script:SfsuUi.Palette
    $Window.Tag.Pie.BackColor=$Window.BackColor; $Window.Tag.Pie.ForeColor=$Window.ForeColor
    $Window.Tag.Pie.Invalidate()
}

function Update-SfsuProgressWindowLayout($Window) {
    $state=$Window.Tag
    $width=[Math]::Max(400,$Window.ClientSize.Width-70)
    $height=[Windows.Forms.TextRenderer]::MeasureText($state.Heading.Text,$state.Heading.Font,(New-Object Drawing.Size($width,0)),[Windows.Forms.TextFormatFlags]::WordBreak).Height+24
    $height=[Math]::Max(100,$height)
    $state.Layout.RowStyles[0].Height=$height
    $minimumHeight=$height+536
    $Window.AutoScrollMinSize=New-Object Drawing.Size(0,$minimumHeight)
    $state.Layout.MinimumSize=New-Object Drawing.Size(0,$minimumHeight)
    $state.Layout.Height=[Math]::Max($minimumHeight,$Window.ClientSize.Height)
}

function New-SfsuMigrationProgressWindow([string]$Action) {
    $window=New-Object Windows.Forms.Form
    $window.Text=if ($Action -eq 'Capture profiles') { 'Backup progress - SFSU USMT' } else { 'Restore progress - SFSU USMT' }
    $window.Name='MigrationProgress'; $window.AccessibleName=$window.Text
    $window.StartPosition='CenterScreen'; $window.ClientSize=New-Object Drawing.Size(1200,800)
    $window.MinimumSize=New-Object Drawing.Size(760,580); $window.AutoScroll=$true; $window.WindowState='Maximized'
    $window.Font=New-Object Drawing.Font('Segoe UI',16)
    $layout=New-Object Windows.Forms.TableLayoutPanel; $layout.Dock='Top'; $layout.Padding=New-Object Windows.Forms.Padding(28)
    $layout.ColumnCount=2; $layout.RowCount=3; $layout.AutoScroll=$true
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',42)))
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',58)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',100)))
    $window.Controls.Add($layout)
    $heading=New-Object Windows.Forms.Label; $heading.Dock='Fill'; $heading.TextAlign='MiddleLeft'; $heading.Font=New-Object Drawing.Font('Segoe UI',40,[Drawing.FontStyle]::Bold)
    Initialize-SfsuAccessibleStatus $heading 'Alert'; $heading.Text='PREPARING'; $layout.Controls.Add($heading,0,0); $layout.SetColumnSpan($heading,2)
    $left=New-Object Windows.Forms.TableLayoutPanel; $left.Dock='Fill'; $left.ColumnCount=1; $left.RowCount=3
    [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',110)))
    [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',70)))
    $layout.Controls.Add($left,0,1)
    $pie=New-Object Sfsu.Ui.ProgressPie; $pie.Dock='Fill'; $pie.MinimumSize=New-Object Drawing.Size(200,200); $left.Controls.Add($pie,0,0)
    $overall=New-Object Windows.Forms.Label; $overall.Dock='Fill'; $overall.TextAlign='MiddleCenter'; $overall.Font=New-Object Drawing.Font('Segoe UI',62,[Drawing.FontStyle]::Bold); $overall.Text='0%'; $left.Controls.Add($overall,0,1)
    $weight=New-Object Windows.Forms.Label; $weight.Dock='Fill'; $weight.TextAlign='TopCenter'; $weight.Text='Estimated overall progress'; $left.Controls.Add($weight,0,2)
    $right=New-Object Windows.Forms.FlowLayoutPanel; $right.Dock='Fill'; $right.FlowDirection='TopDown'; $right.WrapContents=$false; $right.AutoScroll=$true; $right.Padding=New-Object Windows.Forms.Padding(24,8,0,0); $layout.Controls.Add($right,1,1)
    $profile=New-Object Windows.Forms.Label; $profile.AutoSize=$true; $profile.Font=New-Object Drawing.Font('Segoe UI',34,[Drawing.FontStyle]::Bold); $profile.Text='Preparing migration'; $right.Controls.Add($profile)
    $stage=New-Object Windows.Forms.Label; $stage.AutoSize=$true; $stage.Font=New-Object Drawing.Font('Segoe UI',30); $stage.Text='Checking selected profiles'; $right.Controls.Add($stage)
    $bar=New-Object Windows.Forms.ProgressBar; $bar.Height=46; $bar.Width=500; $bar.Style='Marquee'; $bar.AccessibleName='Native progress for the current profile and stage'; $right.Controls.Add($bar)
    $native=New-Object Windows.Forms.Label; $native.AutoSize=$true; $native.Font=New-Object Drawing.Font('Segoe UI',26); $native.Text='Waiting for native progress'; $right.Controls.Add($native)
    $message=New-Object Windows.Forms.Label; $message.AutoSize=$true; $message.Font=New-Object Drawing.Font('Segoe UI',20); $right.Controls.Add($message)
    $elapsed=New-Object Windows.Forms.Label; $elapsed.AutoSize=$true; $right.Controls.Add($elapsed)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill'; $buttons.WrapContents=$true; $layout.Controls.Add($buttons,0,2); $layout.SetColumnSpan($buttons,2)
    $top=New-Object Windows.Forms.CheckBox; $top.Text='Always on top'; $top.AutoSize=$true; $top.Add_CheckedChanged({param($sender,$event) $sender.FindForm().TopMost=$sender.Checked}); $buttons.Controls.Add($top)
    $report=New-Object Windows.Forms.Button; $report.Text='Open report'; $report.AutoSize=$true; $report.Enabled=$false; $buttons.Controls.Add($report)
    $stop=New-Object Windows.Forms.Button; $stop.Text='Cancel migration'; $stop.AutoSize=$true; $buttons.Controls.Add($stop)
    $close=New-Object Windows.Forms.Button; $close.Text='Close'; $close.AutoSize=$true; $close.Enabled=$false; $buttons.Controls.Add($close)
    $window.Tag=[pscustomobject]@{Pie=$pie;Heading=$heading;Overall=$overall;Weight=$weight;Profile=$profile;Stage=$stage;Bar=$bar;Native=$native;Message=$message;Elapsed=$elapsed;Report=$report;ReportPath='';Stop=$stop;Close=$close;Right=$right;Layout=$layout;Started=[DateTime]::UtcNow;Running=$true;CloseAfter=$false;Snapshot=$null;Action=$Action;Terminal=''}
    $window.Add_Resize({param($sender,$event) if ($sender.Tag) { Update-SfsuProgressWindowLayout $sender }})
    $window.Add_SystemColorsChanged({ Update-SfsuAppearance })
    $right.Add_Resize({param($sender,$event)
        $width=[Math]::Max(260,$sender.ClientSize.Width-$sender.Padding.Horizontal-30)
        foreach ($child in $sender.Controls) { if ($child -is [Windows.Forms.Label]) { $child.MaximumSize=New-Object Drawing.Size($width,0) } else { $child.Width=$width } }
    })
    $stop.Add_Click({ Request-SfsuUiCancellation })
    $close.Add_Click({param($sender,$event) $sender.FindForm().Close()})
    $report.Add_Click({param($sender,$event) try { $path=$sender.FindForm().Tag.ReportPath; if ($path) { Start-Process -FilePath $path | Out-Null } } catch { Show-SfsuMessage $_.Exception.Message }})
    $window.Add_FormClosing({param($sender,$event)
        if ($sender.Tag.Running) {
            $event.Cancel=$true
            Request-SfsuUiCancellation
            if ($script:SfsuUi.Cancelled) { $sender.Tag.CloseAfter=$true }
        }
    })
    $window.Add_Disposed({param($sender,$event)
        # Explicitly owned fonts are not shared with the main application.
        foreach ($control in @($sender.Tag.Heading,$sender.Tag.Overall,$sender.Tag.Profile,$sender.Tag.Stage,$sender.Tag.Native,$sender.Tag.Message,$sender)) { $control.Font.Dispose() }
    })
    Set-SfsuProgressWindowAppearance $window
    Update-SfsuProgressWindowLayout $window
    $window
}

function Show-SfsuMigrationProgressWindow([string]$Action) {
    $old=$script:SfsuUi.ProgressWindow
    if ($null -ne $old -and -not $old.IsDisposed) { $old.Tag.Running=$false; $old.Dispose() }
    $window=New-SfsuMigrationProgressWindow $Action; $script:SfsuUi.ProgressWindow=$window
    $window.Show($script:SfsuUi.Form)
}

function Update-SfsuMigrationProgressWindow($Snapshot,[string]$Outcome='',[string]$ReportPath='') {
    $window=$script:SfsuUi.ProgressWindow
    if ($null -eq $window -or $window.IsDisposed) { return }
    $state=$window.Tag
    if ($null -ne $Snapshot) { $state.Snapshot=$Snapshot }
    $snapshot=$state.Snapshot
    if ($null -ne $snapshot) {
        $state.Pie.Percent=$snapshot.OverallPercent
        $state.Overall.Text=([Math]::Floor($snapshot.OverallPercent)).ToString('0')+'%'
        $state.Weight.Text=$snapshot.WeightNote
        $state.Profile.Text=if ($snapshot.ProfileIndex -gt 0) { 'Profile '+$snapshot.ProfileIndex+' of '+$snapshot.ProfileCount+"`r`n"+$snapshot.ProfileName } else { 'All '+$snapshot.ProfileCount+' selected profiles' }
        $state.Stage.Text=$snapshot.Stage; $state.Message.Text=$snapshot.Message
        if ($snapshot.Percent -ge 0) { $state.Bar.Style='Continuous'; $state.Bar.Value=[Math]::Min(100,$snapshot.Percent); $state.Native.Text='Current stage: '+$snapshot.Percent+'%' }
        else { $state.Bar.Style='Marquee'; $state.Native.Text='Current stage: working (percentage unavailable)' }
    }
    if ($Outcome) {
        $state.Running=$false; $state.Terminal=$Outcome; $state.Pie.Outcome=$Outcome; $state.Bar.Style='Continuous'
        $state.Stop.Enabled=$false; $state.Close.Enabled=$true; $state.ReportPath=$ReportPath; $state.Report.Enabled=[bool]$ReportPath
        $state.Heading.Text=switch ($Outcome) { 'Completed' { 'COMPLETED' }; 'CompletedWithWarnings' { 'COMPLETED WITH WARNINGS' }; 'Cancelled' { 'CANCELLED' }; default { 'FAILED' } }
        if ($Outcome -in @('Completed','CompletedWithWarnings')) { $state.Pie.Percent=100; $state.Overall.Text='100%'; $state.Bar.Value=100; $state.Native.Text='Required migration stages finished'; $state.Stage.Text='Migration and required checks finished' }
        else { $state.Native.Text='Stopped; partial work is preserved'; $state.Weight.Text='Stopped at '+$state.Overall.Text+" overall`r`n"+$state.Weight.Text }
        if ($state.CloseAfter) { $window.Close(); return }
    } elseif ($state.Running) {
        $state.Heading.Text=if ($script:SfsuUi.Cancelled) { 'STOPPING' } elseif ($state.Action -eq 'Capture profiles') { 'BACKUP IN PROGRESS' } else { 'RESTORE IN PROGRESS' }
        $state.Stop.Enabled=-not $script:SfsuUi.Cancelled
    }
    $duration=[DateTime]::UtcNow-$state.Started
    $state.Elapsed.Text='Elapsed: '+([int]$duration.TotalHours).ToString('00')+':'+$duration.Minutes.ToString('00')+':'+$duration.Seconds.ToString('00')
    $state.Pie.AccessibleName=$state.Heading.Text+'; overall '+$state.Overall.Text
    Update-SfsuProgressWindowLayout $window
}
