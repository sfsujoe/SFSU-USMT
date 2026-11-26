# Worker-side progress only. Publish one immutable snapshot for the UI reader.
Set-StrictMode -Version Latest

function Initialize-SfsuWorkflowProgress($Control,[string]$Operation,[string[]]$Names,[double[]]$Sizes=@()) {
    if (-not $Control) { return }
    $Control.Workflow=@{Operation=$Operation;Names=$Names;Weights=@();Transfer=@($Names | ForEach-Object { 0.0 });Verify=@($Names | ForEach-Object { 0.0 });Index=0;Stage='Preparing';StageText='Preparing migration';Overall=0.0;WeightNote='Calculating profile sizes';Outcome='Running'}
    Set-SfsuWorkflowWeights $Control $Sizes
    Publish-SfsuWorkflowProgress $Control 'Preparing migration' -1
}

function Set-SfsuWorkflowWeights($Control,[double[]]$Sizes) {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    $state=$Control.Workflow; $known=@($Sizes | Where-Object { $_ -gt 0 -and -not [double]::IsInfinity($_) -and -not [double]::IsNaN($_) })
    $fallback=1.0; if ($known.Count) { $fallback=[double](($known | Measure-Object -Average).Average) }
    $weights=@(); $missing=0
    for ($i=0;$i -lt $state.Names.Count;$i++) {
        if ($i -lt $Sizes.Count -and $Sizes[$i] -gt 0 -and -not [double]::IsInfinity($Sizes[$i]) -and -not [double]::IsNaN($Sizes[$i])) { $weights+= $Sizes[$i] }
        else { $weights+= $fallback; $missing++ }
    }
    $state.Weights=$weights
    $state.WeightNote=if ($missing) { 'Estimated overall; average/equal weight used where size is unavailable' } else { 'Estimated overall; weighted by profile size, not elapsed time' }
}

function Publish-SfsuWorkflowProgress($Control,[string]$Message,[int]$Percent=-1) {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    $state=$Control.Workflow; $total=0.0; $transfer=0.0; $verify=0.0
    for ($i=0;$i -lt $state.Weights.Count;$i++) {
        $total+=$state.Weights[$i]; $transfer+=$state.Weights[$i]*$state.Transfer[$i]; $verify+=$state.Weights[$i]*$state.Verify[$i]
    }
    $overall=0.0
    if ($state.Stage -ne 'Preparing' -and $total -gt 0) {
        if ($state.Operation -eq 'Backup') { $overall=5+85*$transfer/$total+9*$verify/$total }
        else { $overall=5+84*$transfer/$total+10*$verify/$total }
    }
    # Native progress can reset or disappear. Never rewind the overall display;
    # only a successful terminal result may consume the final one percent.
    $state.Overall=[Math]::Max([double]$state.Overall,[Math]::Min(99.0,[double]$overall))
    if ($state.Outcome -in @('Completed','CompletedWithWarnings')) { $state.Overall=100.0 }
    $name=''; if ($state.Index -gt 0 -and $state.Index -le $state.Names.Count) { $name=$state.Names[$state.Index-1] }
    $Control.ProgressSnapshot=[pscustomobject]@{Message=$Message;Percent=$Percent;OverallPercent=$state.Overall;ProfileIndex=$state.Index;ProfileCount=$state.Names.Count;ProfileName=$name;Stage=$state.StageText;Outcome=$state.Outcome;WeightNote=$state.WeightNote}
}

function Set-SfsuWorkflowStage($Control,[string]$Stage,[int]$Index=0,[string]$Text='') {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    $Control.Workflow.Stage=$Stage; $Control.Workflow.Index=$Index; $Control.Workflow.StageText=$Text
    $Control.Message=$Text; $Control.Percent=-1
    Publish-SfsuWorkflowProgress $Control $Text -1
}

function Update-SfsuWorkflowNativeProgress($Control,[string]$Message,[int]$Percent=-1) {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    $state=$Control.Workflow
    if ($Percent -ge 0 -and $state.Index -gt 0 -and $state.Index -le $state.Names.Count -and $state.Stage -in @('Transfer','Verify')) {
        $values=$state[$state.Stage]; $i=$state.Index-1
        $values[$i]=[Math]::Max($values[$i],[Math]::Min(100,$Percent)/100.0)
    }
    Publish-SfsuWorkflowProgress $Control $Message $Percent
}

function Complete-SfsuWorkflowStage($Control) {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    Update-SfsuWorkflowNativeProgress $Control $Control.Workflow.StageText 100
}

function Complete-SfsuWorkflowProgress($Control,[string]$Outcome) {
    if (-not $Control -or -not $Control.ContainsKey('Workflow')) { return }
    $Control.Workflow.Outcome=$Outcome
    Publish-SfsuWorkflowProgress $Control $Control.Message $Control.Percent
}

Export-ModuleMember -Function Initialize-SfsuWorkflowProgress,Set-SfsuWorkflowWeights,Set-SfsuWorkflowStage,Update-SfsuWorkflowNativeProgress,Complete-SfsuWorkflowStage,Complete-SfsuWorkflowProgress
