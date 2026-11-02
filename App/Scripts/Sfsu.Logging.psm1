# Compatible with Windows PowerShell 5.1. No migration executable is invoked here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:JournalCache=@{}

function Initialize-SfsuPathSafety {
    if ('Sfsu.SafeFiles' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Sfsu {
 public static class SafeFiles {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
   public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint mode,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateDirectory(string path,IntPtr security);
  public static void ReserveDirectory(string path) { if(!CreateDirectory(path,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  static void Check(SafeFileHandle file,bool directory) {
   if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
   Info info; if(!GetFileInformationByHandle(file,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
   if((info.Attributes & 0x400)!=0) throw new IOException("Linked paths are not supported.");
   if(directory && (info.Attributes & 0x10)==0) throw new IOException("A regular directory is required.");
   if(!directory && ((info.Attributes & 0x10)!=0 || info.Links>1)) throw new IOException("A regular file with one link is required.");
  }
  public sealed class Lease : IDisposable {
   List<SafeFileHandle> handles=new List<SafeFileHandle>();
   public Lease(string path) {
    try {
     var paths=new List<string>(); string current=Path.GetFullPath(path);
     while(!String.IsNullOrEmpty(current)) { paths.Add(current); string parent=Path.GetDirectoryName(current); if(parent==current) break; current=parent; }
     paths.Reverse();
     foreach(string item in paths) {
      // Lock ancestors against deletion/rename while the operation is active.
      if(!Directory.Exists(item)) { if(File.Exists(item)) continue; break; }
      // Attribute-only handles do not enforce delete sharing on Windows.
      // Generic read includes directory-list access, making share denial real.
      var handle=CreateFile(item,0x80000000,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
      handles.Add(handle); try { Check(handle,true); } catch(Exception ex) { throw new IOException("Cannot protect directory: "+item+". "+ex.Message,ex); }
     }
    } catch { Dispose(); throw; }
   }
   public void Dispose() { for(int i=handles.Count-1;i>=0;i--) handles[i].Dispose(); handles.Clear(); }
  }
  public static FileStream Open(string path, bool write, bool createNew) {
   var handle=CreateFile(Path.GetFullPath(path),write ? 0xC0000000u : 0x80000000u,1,IntPtr.Zero,createNew ? 1u : 3u,0x00200000,IntPtr.Zero);
   try { Check(handle,false); return new FileStream(handle,write ? FileAccess.ReadWrite : FileAccess.Read); }
   catch { handle.Dispose(); throw; }
  }
 }
}
'@
}

function Enter-SfsuPathGuard([string]$Path) {
    Initialize-SfsuPathSafety
    [Sfsu.SafeFiles+Lease]::new([IO.Path]::GetFullPath($Path))
}

function Assert-SfsuSafePath([string]$Path,[switch]$AllowMissing) {
    $full=[IO.Path]::GetFullPath($Path)
    $guard=Enter-SfsuPathGuard $full
    try {
        if (Test-Path -LiteralPath $full) {
            $item=Get-Item -LiteralPath $full -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked paths are not supported.' }
            if (-not $item.PSIsContainer) { $stream=[Sfsu.SafeFiles]::Open($full,$false,$false); $stream.Dispose() }
        } elseif (-not $AllowMissing) { throw 'The required path does not exist.' }
        $full
    } finally { $guard.Dispose() }
}

function Copy-SfsuReportFile([string]$Source,[string]$Destination) {
    # Open without following reparse points; validate hard-link count before
    # changing bytes. The open handle prevents a target swap during the copy.
    $guard=Enter-SfsuPathGuard $Destination
    $inputFile=$null; $outputFile=$null
    try {
        $inputFile=[Sfsu.SafeFiles]::Open($Source,$false,$false)
        $outputFile=[Sfsu.SafeFiles]::Open($Destination,$true,$false)
        $outputFile.SetLength(0); $inputFile.CopyTo($outputFile); $outputFile.Flush($true)
    } finally { if ($outputFile) { $outputFile.Dispose() }; if ($inputFile) { $inputFile.Dispose() }; $guard.Dispose() }
}

function Copy-SfsuSafeDirectory([string]$Source,[string]$Destination) {
    $sourceGuard=Enter-SfsuPathGuard $Source
    $parentGuard=$null
    $destinationGuard=$null
    try {
        $parentGuard=Enter-SfsuPathGuard $Destination
        [void](Assert-SfsuSafePath $Source)
        [void](Assert-SfsuSafePath $Destination -AllowMissing)
        if (Test-Path -LiteralPath $Destination) { throw 'Snapshot staging destination already exists.' }
        [Sfsu.SafeFiles]::ReserveDirectory($Destination)
        $destinationGuard=Enter-SfsuPathGuard $Destination
        foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
            [void](Assert-SfsuSafePath $item.FullName)
            $target=Join-Path $Destination $item.Name
            if ($item.PSIsContainer) { Copy-SfsuSafeDirectory $item.FullName $target }
            else {
                $inputFile=[Sfsu.SafeFiles]::Open($item.FullName,$false,$false)
                $outputFile=$null
                try { $outputFile=[Sfsu.SafeFiles]::Open($target,$true,$true); $inputFile.CopyTo($outputFile); $outputFile.Flush($true) }
                finally { if ($outputFile) { $outputFile.Dispose() }; $inputFile.Dispose() }
            }
        }
    } finally { if ($destinationGuard) { $destinationGuard.Dispose() }; if ($parentGuard) { $parentGuard.Dispose() }; $sourceGuard.Dispose() }
}

function ConvertTo-SfsuHtml([object]$Value) {
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Read-SfsuLogoData([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $guard=Enter-SfsuPathGuard $Path
    $stream=$null; $memory=$null
    try {
        $stream=[Sfsu.SafeFiles]::Open($Path,$false,$false)
        if ($stream.Length -gt 1MB) { return '' }
        $memory=New-Object IO.MemoryStream
        $stream.CopyTo($memory); $bytes=$memory.ToArray()
        if ($bytes.Length -lt 8 -or [BitConverter]::ToString($bytes,0,8) -ne '89-50-4E-47-0D-0A-1A-0A') { return '' }
        [Convert]::ToBase64String($bytes)
    } finally { if ($memory) { $memory.Dispose() }; if ($stream) { $stream.Dispose() }; $guard.Dispose() }
}

function Write-SfsuAtomicText([string]$Path, [string]$Text) {
    $guard=Enter-SfsuPathGuard $Path
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [void](Assert-SfsuSafePath $Path -AllowMissing)
        $temporaryStream=[Sfsu.SafeFiles]::Open($temporary,$true,$true)
        try { $temporaryBytes=$script:Utf8.GetBytes($Text); $temporaryStream.Write($temporaryBytes,0,$temporaryBytes.Length); $temporaryStream.Flush($true) }
        finally { $temporaryStream.Dispose() }
        if ([System.IO.File]::Exists($Path)) {
            try {
                [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
            } catch [System.IO.IOException], [System.NotSupportedException], [System.UnauthorizedAccessException] {
                # A share can permit writing report.html while denying atomic replacement.
                # Overwrite only this generated report. The durable journal can rebuild it
                # if this non-atomic fallback is interrupted. Never delete the destination.
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    try {
                        Copy-SfsuReportFile $temporary $Path
                        break
                    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                        if ($attempt -eq 2) { throw }
                        Start-Sleep -Milliseconds (100 * ($attempt + 1))
                    }
                }
            }
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } catch {
        throw [System.IO.IOException]::new(
            ('Could not update the HTML report at "' + $Path + '". Check write access and file locks in this app session. The events.jsonl journal is preserved; the HTML report may be stale. ' + $_.Exception.Message),
            $_.Exception)
    } finally {
        # Clean up only the temporary file owned by this call, without hiding a write error.
        try { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
        catch { Write-Warning ('Could not remove temporary report file "' + $temporary + '": ' + $_.Exception.Message) }
        $guard.Dispose()
    }
}

function Get-SfsuRunHandle([string]$RunDirectory) {
    [void](Assert-SfsuSafePath $RunDirectory)
    [void](Assert-SfsuSafePath (Join-Path $RunDirectory 'Raw'))
    $directory = (Get-Item -LiteralPath $RunDirectory -ErrorAction Stop).FullName
    [pscustomobject]@{
        RunDirectory = $directory
        RunId = Split-Path $directory -Leaf
        EventsPath = Join-Path $directory 'events.jsonl'
        ReportPath = Join-Path $directory 'report.html'
        RawDirectory = Join-Path $directory 'Raw'
        LastRenderUtc = [DateTime]::MinValue
    }
}

function Read-SfsuEvents($Run) {
    [void](Assert-SfsuSafePath $Run.EventsPath)
    $file=Get-Item -LiteralPath $Run.EventsPath -Force
    if ($file.Length -gt 32MB) { throw 'Journal exceeds the 32 MB safety limit. Preserve it for troubleshooting.' }
    $key=$file.FullName
    $stamp=[string]$file.Length+':'+$file.LastWriteTimeUtc.Ticks
    if ($script:JournalCache.ContainsKey($key) -and $script:JournalCache[$key].Stamp -eq $stamp) { return $script:JournalCache[$key].Journal }
    $events = New-Object System.Collections.Generic.List[object]
    $invalid = 0
    $guard=Enter-SfsuPathGuard $Run.EventsPath
    $stream=$null; $reader=$null
    try {
    $stream=[Sfsu.SafeFiles]::Open($Run.EventsPath,$false,$false)
    if ($stream.Length -gt 32MB) { throw 'Journal exceeds the 32 MB safety limit.' }
    $reader=New-Object IO.StreamReader($stream,$script:Utf8)
    while ($null -ne ($line=$reader.ReadLine())) {
        if ($line.Length -gt 1MB -or $events.Count -ge 20000) { throw 'Journal record/count safety limit exceeded.' }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $item = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            foreach ($field in @('Sequence','TimeUtc','Type','StepId','Severity','Message','NextAction','Details','Data')) {
                if ($null -eq $item.PSObject.Properties[$field]) { throw "Missing event field: $field" }
            }
            if ($item.Sequence -ne ($events.Count + 1)) { throw 'Event sequence is incomplete.' }
            [void][DateTimeOffset]::Parse($item.TimeUtc)
            if ($item.Type -notin @('RunStarted','StepStarted','Message','Checkpoint','StepFinished','RawLog','RunFinished') -or
                $item.Severity -notin @('INFO','WARNING','ERROR')) { throw 'Unknown event type or severity.' }
            if ($item.Type -eq 'RunFinished' -and $item.Data.Outcome -notin @('Completed','CompletedWithWarnings','Failed','Cancelled')) {
                throw 'Unknown run outcome.'
            }
            if ($item.Type -eq 'StepFinished' -and $item.Data.Status -notin @('Passed','Warning','Failed','Skipped')) {
                throw 'Unknown step result.'
            }
            if ($item.Type -eq 'Checkpoint' -and $item.Data.Status -notin @('Passed','Warning','Failed','NotRun')) {
                throw 'Unknown checkpoint result.'
            }
            $events.Add($item)
        } catch { $invalid++ }
    } } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }; $guard.Dispose() }
    if ($events.Count -eq 0 -or $events[0].Type -ne 'RunStarted') {
        throw 'The event journal has no readable run header. Preserve it for troubleshooting.'
    }
    $journal=[pscustomobject]@{ Events = $events.ToArray(); InvalidLines = $invalid }
    # Limit cache lifetime/size; it accelerates repeated checks, never grants trust.
    if ($script:JournalCache.Count -ge 4) { $script:JournalCache.Clear() }
    $script:JournalCache[$key]=@{Stamp=$stamp;Journal=$journal}
    $journal
}

function Get-SfsuStepState($Events, [string]$StepId) {
    $started = @($Events | Where-Object { $_.StepId -eq $StepId -and $_.Type -eq 'StepStarted' })
    $finished = @($Events | Where-Object { $_.StepId -eq $StepId -and $_.Type -eq 'StepFinished' })
    [pscustomobject]@{ Started = $started; Finished = $finished }
}

function Assert-SfsuWritableRun($Run, [string]$StepId) {
    $journal = Read-SfsuEvents $Run
    if ($journal.InvalidLines -gt 0) { throw 'The journal is damaged. Regenerate the report; do not append to this run.' }
    if (@($journal.Events | Where-Object Type -eq 'RunFinished').Count -gt 0) { throw 'This run has already ended. Start a new run.' }
    if ($StepId -and @($journal.Events[0].Data.Steps | Where-Object Id -eq $StepId).Count -eq 0) {
        throw "Unknown step: $StepId"
    }
    $journal
}

function Add-SfsuEvent {
    param($Run, [string]$Type, [string]$StepId = '', [string]$Severity = 'INFO',
        [string]$Message, [string]$NextAction = '', [string]$Details = '', $Data = @{})
    $sequence = 1
    $previousEvents=@()
    if ([System.IO.File]::Exists($Run.EventsPath)) {
        $previousEvents=(Read-SfsuEvents $Run).Events
        $sequence = $previousEvents.Count + 1
    }
    $event = [ordered]@{
        Sequence = $sequence; TimeUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Type = $Type; StepId = $StepId; Severity = $Severity
        Message = $Message; NextAction = $NextAction; Details = $Details; Data = $Data
    }
    $bytes = $script:Utf8.GetBytes((ConvertTo-Json -InputObject $event -Depth 12 -Compress) + "`n")
    if ($bytes.Length -gt 1MB -or $sequence -gt 20000) { throw 'Journal record/count safety limit exceeded.' }
    $guard=Enter-SfsuPathGuard $Run.EventsPath
    $stream=$null
    try {
        $stream=[Sfsu.SafeFiles]::Open($Run.EventsPath,$true,(-not [IO.File]::Exists($Run.EventsPath)))
        if ($stream.Length+$bytes.Length -gt 32MB) { throw 'Journal exceeds the 32 MB safety limit.' }
        [void]$stream.Seek(0,[IO.SeekOrigin]::End); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    } finally { if ($stream) { $stream.Dispose() }; $guard.Dispose() }
    $info=Get-Item -LiteralPath $Run.EventsPath -Force
    if ($script:JournalCache.Count -ge 4 -and -not $script:JournalCache.ContainsKey($info.FullName)) { $script:JournalCache.Clear() }
    $script:JournalCache[$info.FullName]=@{Stamp=([string]$info.Length+':'+$info.LastWriteTimeUtc.Ticks);Journal=[pscustomobject]@{Events=@($previousEvents)+[pscustomobject]$event;InvalidLines=0}}
    # The durable journal is written first. A rendering failure never discards its evidence.
    # Keep ordinary messages durable immediately; bound expensive HTML rebuilds
    # to once a second. Checkpoints, errors and lifecycle boundaries render now.
    if ($Type -ne 'Message' -or $Severity -eq 'ERROR' -or ([DateTime]::UtcNow-$Run.LastRenderUtc).TotalSeconds -ge 1) {
        Update-SfsuLogReport -RunDirectory $Run.RunDirectory | Out-Null
        $Run.LastRenderUtc=[DateTime]::UtcNow
    }
}

function New-SfsuLogRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][ValidateSet('Backup','Restore','ReportPreview','ProfileDiscovery','BackupPreparation','BackupInventory','RestoreReview','DirectoryAuthentication')][string]$Operation,
        [Parameter(Mandatory)][object[]]$Steps,
        [string]$Label = '', [switch]$Sample
    )
    $root = Assert-SfsuSafePath $PackageRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'PackageRoot must be a directory.' }
    if ($Steps.Count -eq 0) { throw 'At least one step is required.' }
    $seen = @{}
    $definitions = foreach ($step in $Steps) {
        if ($step.Id -notmatch '^[a-zA-Z0-9_-]+$' -or [string]::IsNullOrWhiteSpace($step.Title)) {
            throw 'Each step requires a simple Id and a non-empty Title.'
        }
        if ($seen.ContainsKey($step.Id)) { throw 'Step IDs must be unique.' }
        $seen[$step.Id] = $true
        [pscustomobject]@{ Id = [string]$step.Id; Title = [string]$step.Title }
    }
    $logs = Join-Path $root 'Logs'
    [void](Assert-SfsuSafePath $logs -AllowMissing)
    $guard=Enter-SfsuPathGuard $logs
    try {
    [void][System.IO.Directory]::CreateDirectory($logs)
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $directory = Join-Path $logs $id
    [void][System.IO.Directory]::CreateDirectory($directory)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $directory 'Raw'))
    } finally { $guard.Dispose() }
    $runGuard=Enter-SfsuPathGuard $directory
    try {
    $run = Get-SfsuRunHandle $directory
    $logo = Join-Path $root 'App/Assets/SFSU Logo.png'
    $logoData = ''
    try { $logoData=Read-SfsuLogoData $logo } catch { $logoData='' }
    # Keep a bounded PNG beside the journal for portable rebuilds, instead of
    # re-reading a large Base64 field on every event. HTML still embeds the PNG.
    if ($logoData) {
        $logoFile=[Sfsu.SafeFiles]::Open((Join-Path $directory 'logo.png'),$true,$true)
        try { $logoBytes=[Convert]::FromBase64String($logoData); $logoFile.Write($logoBytes,0,$logoBytes.Length); $logoFile.Flush($true) } finally { $logoFile.Dispose() }
    }
    Add-SfsuEvent -Run $run -Type RunStarted -Message 'Run started.' -Data @{
        RunId = $id; Operation = $Operation; Label = $Label; Sample = [bool]$Sample
        Steps = @($definitions); PackageRoot = $root; LogoData = ''
    }
    $run
    } finally { $runGuard.Dispose() }
}

function Start-SfsuLogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId)
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($state.Started.Count -gt 0 -or $state.Finished.Count -gt 0) { throw 'This step has already started or ended.' }
    Add-SfsuEvent -Run $Run -Type StepStarted -StepId $StepId -Message 'Step started.'
}

function Write-SfsuLogEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [string]$StepId = '',
        [ValidateSet('INFO','WARNING','ERROR')][string]$Severity = 'INFO',
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '', [string]$Details = '')
    [void](Assert-SfsuWritableRun $Run $StepId)
    Add-SfsuEvent -Run $Run -Type Message -StepId $StepId -Severity $Severity -Message $Message -NextAction $NextAction -Details $Details
}

function Write-SfsuCheckpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('Passed','Warning','Failed','NotRun')][string]$Status,
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '', [string]$Details = '')
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($Status -ne 'NotRun' -and ($state.Started.Count -eq 0 -or $state.Finished.Count -gt 0)) {
        throw 'Record checkpoint evidence while its step is active.'
    }
    $severity = 'INFO'
    if ($Status -eq 'Warning') { $severity = 'WARNING' }
    if ($Status -eq 'Failed') { $severity = 'ERROR' }
    Add-SfsuEvent -Run $Run -Type Checkpoint -StepId $StepId -Severity $severity -Message $Message -NextAction $NextAction -Details $Details -Data @{ Status = $Status }
}

function Complete-SfsuLogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][ValidateSet('Passed','Warning','Failed','Skipped')][string]$Status,
        [Parameter(Mandatory)][string]$Message, [string]$NextAction = '')
    $journal = Assert-SfsuWritableRun $Run $StepId
    $state = Get-SfsuStepState $journal.Events $StepId
    if ($state.Finished.Count -gt 0) { throw 'This step has already ended.' }
    if ($Status -ne 'Skipped' -and $state.Started.Count -eq 0) { throw 'Start the step before completing it.' }
    if ($Status -eq 'Passed') {
        $stepEvents = @($journal.Events | Where-Object StepId -eq $StepId)
        if (@($stepEvents | Where-Object Severity -eq 'ERROR').Count -gt 0) { $Status = 'Failed' }
        elseif (@($stepEvents | Where-Object Severity -eq 'WARNING').Count -gt 0) { $Status = 'Warning' }
    }
    $severity = 'INFO'
    if ($Status -eq 'Warning') { $severity = 'WARNING' }
    if ($Status -eq 'Failed') { $severity = 'ERROR' }
    Add-SfsuEvent -Run $Run -Type StepFinished -StepId $StepId -Severity $severity -Message $Message -NextAction $NextAction -Data @{ Status = $Status }
}

function Complete-SfsuLogRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('Completed','Failed','Cancelled')][string]$Outcome,
        [Parameter(Mandatory)][string]$Message)
    $journal = Assert-SfsuWritableRun $Run ''
    $resolvedOutcome = $Outcome
    if ($Outcome -eq 'Completed') {
        foreach ($step in $journal.Events[0].Data.Steps) {
            $state = Get-SfsuStepState $journal.Events $step.Id
            if ($state.Finished.Count -eq 0 -or $state.Finished[-1].Data.Status -eq 'Skipped') {
                throw 'An unfinished or skipped required step cannot be reported as completed.'
            }
        }
        if (@($journal.Events | Where-Object Severity -eq 'ERROR').Count -gt 0) { $resolvedOutcome = 'Failed' }
        elseif (@($journal.Events | Where-Object Severity -eq 'WARNING').Count -gt 0) { $resolvedOutcome = 'CompletedWithWarnings' }
    }
    $severity = 'INFO'
    if ($resolvedOutcome -eq 'Failed') { $severity = 'ERROR' }
    if ($resolvedOutcome -eq 'CompletedWithWarnings') { $severity = 'WARNING' }
    Add-SfsuEvent -Run $Run -Type RunFinished -Severity $severity -Message $Message -Data @{ Outcome = $resolvedOutcome }
    $Run.ReportPath
}

function Get-SfsuRawLogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Use a simple raw-log filename without directories.' }
    Assert-SfsuSafePath (Join-Path $Run.RawDirectory $Name) -AllowMissing
}

function Add-SfsuRawLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Name, [string]$StepId = '')
    [void](Assert-SfsuWritableRun $Run $StepId)
    $path = Get-SfsuRawLogPath -Run $Run -Name $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Write the raw log before registering it.' }
    Add-SfsuEvent -Run $Run -Type RawLog -StepId $StepId -Message "Original diagnostic log: $Name" -Data @{ Name = $Name }
}

function Update-SfsuLogReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)
    $run = Get-SfsuRunHandle $RunDirectory
    $journal = Read-SfsuEvents $run
    $events = @($journal.Events)
    $header = $events[0].Data
    $finished = @($events | Where-Object Type -eq 'RunFinished')
    $outcome = 'Incomplete'
    $resultText = 'No final result was recorded. This run may still be active or may have been interrupted.'
    if ($finished.Count -gt 0 -and $journal.InvalidLines -eq 0) {
        $outcome = $finished[-1].Data.Outcome
        $resultText = $finished[-1].Message
    }
    $outcomeLabels = @{ Incomplete='Incomplete'; Completed='Completed'; CompletedWithWarnings='Completed with warnings'; Failed='Failed'; Cancelled='Cancelled' }
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
    $stepTitles = @{}
    $stepsHtml = New-Object System.Text.StringBuilder
    $position = 0
    foreach ($definition in $header.Steps) {
        $position++
        $stepTitles[$definition.Id] = $definition.Title
        $state = Get-SfsuStepState $events $definition.Id
        $status = 'Not run'; $duration = '--'; $message = 'No work recorded.'
        if ($state.Started.Count -gt 0) {
            $status = 'Incomplete'; $message = 'Started; no step result recorded.'
            $endTime = [DateTimeOffset]::Parse($events[-1].TimeUtc)
            if ($state.Finished.Count -gt 0) { $endTime = [DateTimeOffset]::Parse($state.Finished[-1].TimeUtc) }
            $duration = '{0:0.0} s' -f ($endTime - [DateTimeOffset]::Parse($state.Started[0].TimeUtc)).TotalSeconds
        }
        if ($state.Finished.Count -gt 0) { $status = $state.Finished[-1].Data.Status; $message = $state.Finished[-1].Message }
        $class = ConvertTo-SfsuHtml $status.ToLowerInvariant().Replace(' ','-')
        $badge = ConvertTo-SfsuHtml $status
        if ($status -eq 'Failed') { $badge = '! ERROR' }
        if ($status -eq 'Warning') { $badge = '! WARNING' }
        [void]$stepsHtml.Append('<li class="step ' + $class + '"><div class="step-top"><span class="step-number">' + $position + '</span><h3>' + (ConvertTo-SfsuHtml $definition.Title) + '</h3><strong class="badge">' + $badge + '</strong><span class="duration">' + $duration + '</span></div><p>' + (ConvertTo-SfsuHtml $message) + '</p>')
        foreach ($checkpoint in @($events | Where-Object { $_.Type -eq 'Checkpoint' -and $_.StepId -eq $definition.Id })) {
            $checkpointStatus = [string]$checkpoint.Data.Status
            $checkpointLabel = $checkpointStatus
            if ($checkpointStatus -eq 'NotRun') { $checkpointLabel = 'Not run' }
            if ($checkpointStatus -eq 'Failed') { $checkpointLabel = '! ERROR' }
            if ($checkpointStatus -eq 'Warning') { $checkpointLabel = '! WARNING' }
            [void]$stepsHtml.Append('<div class="checkpoint"><strong>Checkpoint: ' + (ConvertTo-SfsuHtml $checkpointLabel) + '</strong> &mdash; ' + (ConvertTo-SfsuHtml $checkpoint.Message))
            if ($checkpoint.NextAction) { [void]$stepsHtml.Append('<br><span>Next action: ' + (ConvertTo-SfsuHtml $checkpoint.NextAction) + '</span>') }
            [void]$stepsHtml.Append('</div>')
        }
        [void]$stepsHtml.Append('</li>')
    }
    $rows = New-Object System.Text.StringBuilder
    foreach ($event in $events) {
        $utcTime = [DateTimeOffset]::Parse($event.TimeUtc)
        $time = [TimeZoneInfo]::ConvertTime($utcTime, $zone).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
        $title = 'Run'
        if ($event.StepId) { $title = $stepTitles[$event.StepId] }
        $severityText = $event.Severity
        if ($event.Severity -in @('ERROR','WARNING')) { $severityText = '! ' + $severityText }
        $severityText = ConvertTo-SfsuHtml $severityText
        $details = ''
        if ($event.Details) { $details = '<details><summary>Technical details</summary><pre>' + (ConvertTo-SfsuHtml $event.Details) + '</pre></details>' }
        $message = ConvertTo-SfsuHtml $event.Message
        if ($event.Type -eq 'Checkpoint') {
            $checkpointLabel = [string]$event.Data.Status
            if ($checkpointLabel -eq 'NotRun') { $checkpointLabel = 'Not run' }
            $message = '<strong>Checkpoint: ' + (ConvertTo-SfsuHtml $checkpointLabel) + '</strong><br>' + $message
        }
        [void]$rows.Append('<tr data-severity="' + (ConvertTo-SfsuHtml $event.Severity) + '"><td>' + $event.Sequence + '</td><td class="time" data-sort="' + $utcTime.ToUnixTimeMilliseconds() + '">' + $time + '</td><td>' + (ConvertTo-SfsuHtml $title) + '</td><td class="severity">' + $severityText + '</td><td>' + $message + $details + '</td><td>' + (ConvertTo-SfsuHtml $event.NextAction) + '</td></tr>')
    }
    $rawLinks = New-Object System.Text.StringBuilder
    # Discover raw files as well as registered events: interrupted engines may leave unregistered logs.
    foreach ($file in @(Get-ChildItem -LiteralPath $run.RawDirectory -File | Sort-Object Name)) {
        [void](Assert-SfsuSafePath $file.FullName)
        [void]$rawLinks.Append('<li><a href="Raw/' + [Uri]::EscapeDataString($file.Name) + '">' + (ConvertTo-SfsuHtml $file.Name) + '</a></li>')
    }
    if ($rawLinks.Length -eq 0) { [void]$rawLinks.Append('<li>No original USMT logs have been recorded.</li>') }
    $notice = ''
    if ($header.Sample) { $notice = '<div class="sample">SAMPLE REPORT &mdash; simulated events only. No migration, store verification, or restore test was performed.</div>' }
    if ($journal.InvalidLines -gt 0) { $notice += '<div class="alert">! ERROR: The event journal contains unreadable or out-of-sequence records. Result is Incomplete. Preserve the original journal.</div>' }
    $snapshotError = Join-Path $run.RunDirectory 'snapshot-error.txt'
    if (Test-Path -LiteralPath $snapshotError -PathType Leaf) {
        $notice += '<div class="alert">! WARNING: A backup log copy could not be completed. These root logs remain available. ' + (ConvertTo-SfsuHtml ([System.IO.File]::ReadAllText($snapshotError))) + '</div>'
    }
    $logoHtml = ''
    $savedLogo=Join-Path $run.RunDirectory 'logo.png'
    if (-not $header.LogoData -and (Test-Path -LiteralPath $savedLogo)) {
        $header.LogoData=Read-SfsuLogoData $savedLogo
    }
    if ($header.LogoData) { $logoHtml = '<img class="logo" alt="San Francisco State University" src="data:image/png;base64,' + (ConvertTo-SfsuHtml $header.LogoData) + '">' }
    $operationTitle = [string]$header.Operation
    if ($operationTitle -eq 'ReportPreview') { $operationTitle = 'Reporting preview' }
    $operationLabels = @{ ProfileDiscovery='Profile discovery'; BackupPreparation='Backup folder preparation'; BackupInventory='Backup inventory'; RestoreReview='Restore selection review'; DirectoryAuthentication='Active Directory authentication' }
    if ($operationLabels.ContainsKey($operationTitle)) { $operationTitle = $operationLabels[$operationTitle] }
    $tokens = @{
        TITLE = ConvertTo-SfsuHtml ($operationTitle + ' report')
        LABEL = ConvertTo-SfsuHtml $header.Label
        RUNID = ConvertTo-SfsuHtml $header.RunId
        OUTCOME = ConvertTo-SfsuHtml $outcomeLabels[$outcome]
        OUTCOMECLASS = ConvertTo-SfsuHtml $outcome.ToLowerInvariant()
        RESULT = ConvertTo-SfsuHtml $resultText
        NOTICE = $notice; LOGO = $logoHtml; STEPS = $stepsHtml.ToString(); ROWS = $rows.ToString(); RAWLINKS = $rawLinks.ToString()
        ASOF = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($events[-1].TimeUtc), $zone).ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
    $template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../Reporting/report.template.html'))
    $renderer = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) [string]$tokens[$match.Groups[1].Value] }
    $html = [regex]::Replace($template, '@@([A-Z]+)@@', $renderer)
    Write-SfsuAtomicText $run.ReportPath $html
    $run.ReportPath
}

function Export-SfsuLogSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$BackupPath)
    $sourceGuard=Enter-SfsuPathGuard $Run.RunDirectory
    $destinationGuard=$null
    try {
    $journal = Read-SfsuEvents $Run
    if ($journal.InvalidLines -gt 0 -or @($journal.Events | Where-Object Type -eq 'RunFinished').Count -eq 0) {
        throw 'Only an ended, readable run can be copied as a finalized backup log snapshot.'
    }
    $root = [string]$journal.Events[0].Data.PackageRoot
    $backupsRoot = [System.IO.Path]::GetFullPath((Join-Path $root 'Backups')).TrimEnd('\') + '\'
    $backup = (Get-Item -LiteralPath $BackupPath -ErrorAction Stop).FullName
    if (-not (Test-Path -LiteralPath $backup -PathType Container) -or
        -not $backup.StartsWith($backupsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose an existing backup directory inside this package Backups folder.'
    }
    $destination = Join-Path (Join-Path $backup 'Logs') $Run.RunId
    [void](Assert-SfsuSafePath $destination -AllowMissing)
    $destinationGuard=Enter-SfsuPathGuard $destination
    if ($Run.RunId -notmatch '^\d{8}T\d{9}Z-[0-9a-f]{12}$' -or (Split-Path $Run.RunDirectory -Leaf) -ne $Run.RunId) { throw 'Invalid source run identifier.' }
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Run.RunDirectory)) -ne [IO.Path]::GetFullPath((Join-Path $root 'Logs'))) { throw 'Snapshot source must be the package root log run.' }
    if (Test-Path -LiteralPath $destination) { throw 'This snapshot already exists; it will not be overwritten.' }
    try {
        [void][System.IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        $staging = $destination + '.' + [guid]::NewGuid().ToString('N') + '.partial'
        Copy-SfsuSafeDirectory $Run.RunDirectory $staging
        # A scanner/indexer or SMB lease can briefly hold the just-copied folder.
        # Retry only the final rename; preserve the original failure/partial copy if it persists.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try { [System.IO.Directory]::Move($staging, $destination); break }
            catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Milliseconds (200 * $attempt)
            }
        }
        Join-Path $destination 'report.html'
    } catch {
        Write-SfsuAtomicText (Join-Path $Run.RunDirectory 'snapshot-error.txt') $_.Exception.Message
        Update-SfsuLogReport -RunDirectory $Run.RunDirectory | Out-Null
        throw
    }
    } finally { if ($destinationGuard) { $destinationGuard.Dispose() }; $sourceGuard.Dispose() }
}

Export-ModuleMember -Function New-SfsuLogRun, Start-SfsuLogStep, Write-SfsuLogEvent, Write-SfsuCheckpoint,
    Complete-SfsuLogStep, Complete-SfsuLogRun, Get-SfsuRawLogPath, Add-SfsuRawLog, Update-SfsuLogReport, Export-SfsuLogSnapshot,
    Assert-SfsuSafePath, Enter-SfsuPathGuard
