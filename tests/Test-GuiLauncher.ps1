# Isolated launcher/startup fixtures. No live app discovery, credentials, AD or migration.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $PSScriptRoot ('.work/gui launch & (test)-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'App/Scripts'))
Copy-Item -LiteralPath (Join-Path $repository 'sfsu-usmt.cmd') -Destination $testRoot
$entryPath=Join-Path $testRoot 'App/Scripts/Start-SfsuUsmt.ps1'
$script:Assertions=0
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw ('FAILED: '+$Message) }; $script:Assertions++ }
function Invoke-Launcher([string]$Arguments='', [string]$PackageRoot=$testRoot) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$env:ComSpec
    $start.Arguments='/d /c ""'+(Join-Path $PackageRoot 'sfsu-usmt.cmd')+'" '+$Arguments+'"'
    $start.WorkingDirectory=$PSScriptRoot
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Launcher timed out.' }
        [pscustomobject]@{ExitCode=$process.ExitCode;Output=$process.StandardOutput.ReadToEnd();Error=$process.StandardError.ReadToEnd()}
    } finally { $process.Dispose() }
}
function Wait-Probe([string]$Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { [Threading.Thread]::Sleep(50) }
    if (-not (Test-Path -LiteralPath $Path)) { throw ('Missing launcher probe: '+$Path) }
    # The fixture writes via a temporary path then renames when complete.
    ConvertFrom-Json ([IO.File]::ReadAllText($Path))
}
$fixture=@'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GuiLaunchConsoleProbe {
 [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
"@
$form=New-Object Windows.Forms.Form
$form.ShowInTaskbar=$false; $form.StartPosition='Manual'; $form.Location=New-Object Drawing.Point(-30000,-30000)
$password=New-Object Windows.Forms.TextBox; $password.UseSystemPasswordChar=$true; $form.Controls.Add($password)
try {
 $form.Show(); [Windows.Forms.Application]::DoEvents()
 $result=@{ConsoleVisible=[GuiLaunchConsoleProbe]::IsWindowVisible([GuiLaunchConsoleProbe]::GetConsoleWindow());FormVisible=$form.Visible;PasswordMasked=$password.UseSystemPasswordChar;Apartment=[string][Threading.Thread]::CurrentThread.ApartmentState;ProcessPolicy=[string](Get-ExecutionPolicy -Scope Process);ArgumentCount=$args.Count}
 $path=Join-Path $PSScriptRoot '../../launch-probe.json'
 [IO.File]::WriteAllText(($path+'.tmp'),(ConvertTo-Json $result))
 [IO.File]::Move(($path+'.tmp'),$path)
} finally { $form.Dispose() }
'@
[IO.File]::WriteAllText($entryPath,$fixture)
$launched=Invoke-Launcher
Assert-True ($launched.ExitCode -eq 0) ('Normal CMD launch succeeds through a quoted portable path: '+$launched.Error)
$probe=Wait-Probe (Join-Path $testRoot 'launch-probe.json')
Assert-True (-not $probe.ConsoleVisible -and $probe.FormVisible) 'Normal launch hides its console while a graphical form remains visible.'
Assert-True ($probe.PasswordMasked -and $probe.Apartment -eq 'STA' -and $probe.ProcessPolicy -eq 'Bypass' -and $probe.ArgumentCount -eq 0) 'The launch retains masked input, STA and process-only Bypass without additional script arguments.'

# Exercise the real entry-point catch with an isolated import failure. Replace
# only the native message-box call so no modal window waits for a person.
$entry=[IO.File]::ReadAllText((Join-Path $repository 'App/Scripts/Start-SfsuUsmt.ps1'))
$messageCall="[void][Windows.Forms.MessageBox]::Show(`$message,'SFSU USMT startup error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)"
if (-not $entry.Contains($messageCall)) { throw 'Startup error fixture seam missing.' }
$messageProbe=@'
    $path=Join-Path $packageRoot 'error-probe.json'
    [IO.File]::WriteAllText(($path+'.tmp'),(ConvertTo-Json @{Message=$message;DetailsPath=$DetailsPath}))
    [IO.File]::Move(($path+'.tmp'),$path)
'@
[IO.File]::WriteAllText($entryPath,$entry.Replace($messageCall,$messageProbe))
[IO.File]::WriteAllText((Join-Path $testRoot 'App/Scripts/Sfsu.Launch.psm1'),'function Test-SfsuAdministrator { $true }')
[IO.File]::WriteAllText((Join-Path $testRoot 'App/Scripts/Sfsu.Logging.psm1'),"throw 'Synthetic startup import failure.'")
$launched=Invoke-Launcher
Assert-True ($launched.ExitCode -eq 0) 'The normal launcher returns after starting its hidden app process.'
$errorProbe=Wait-Probe (Join-Path $testRoot 'error-probe.json')
Assert-True ($errorProbe.Message -match 'SFSU USMT could not start' -and $errorProbe.Message.Contains($errorProbe.DetailsPath) -and (Test-Path -LiteralPath $errorProbe.DetailsPath)) 'GUI startup failure requests a visible error with a real saved details path.'
Assert-True ([IO.File]::ReadAllText($errorProbe.DetailsPath).Contains('Synthetic startup import failure.')) 'The startup log preserves the underlying failure.'
Move-Item -LiteralPath (Join-Path $testRoot 'error-probe.json') -Destination (Join-Path $testRoot 'previous-error-probe.json')
$cli=Invoke-Launcher '-Headless'
Assert-True ($cli.ExitCode -eq 1 -and $cli.Error.Contains('Synthetic startup import failure.')) 'Command-line actions remain synchronous and return their failure code/details.'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'error-probe.json'))) 'Headless failures do not request a GUI message box.'

# A file blocking Logs must still produce an actionable graphical error.
$blockedRoot=Join-Path $testRoot 'blocked'; [void][IO.Directory]::CreateDirectory((Join-Path $blockedRoot 'App/Scripts'))
[IO.File]::WriteAllText((Join-Path $blockedRoot 'App/Scripts/Start-SfsuUsmt.ps1'),$entry.Replace($messageCall,$messageProbe))
[IO.File]::WriteAllText((Join-Path $blockedRoot 'App/Scripts/Sfsu.Launch.psm1'),'function Test-SfsuAdministrator { $true }')
[IO.File]::WriteAllText((Join-Path $blockedRoot 'App/Scripts/Sfsu.Logging.psm1'),"throw 'Synthetic startup import failure.'")
[IO.File]::WriteAllText((Join-Path $blockedRoot 'Logs'),'Synthetic obstruction.')
Copy-Item -LiteralPath (Join-Path $repository 'sfsu-usmt.cmd') -Destination $blockedRoot
$blocked=Invoke-Launcher '-Scenario Completed' $blockedRoot
Assert-True ($blocked.ExitCode -eq 1) 'A GUI startup failure without writable Logs still returns failure when launched synchronously.'
$blockedProbe=Wait-Probe (Join-Path $blockedRoot 'error-probe.json')
Assert-True (-not $blockedProbe.DetailsPath -and $blockedProbe.Message.Contains('could not be saved')) 'An unsaved log is not presented as a saved path in the GUI error.'
Write-Output ("PASS: $script:Assertions GUI-launcher assertions on PowerShell "+$PSVersionTable.PSVersion)
Write-Output ('Validation artifacts: '+$testRoot)
