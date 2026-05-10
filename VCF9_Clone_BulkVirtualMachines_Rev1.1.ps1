<#
.SYNOPSIS
VCF PowerCLI VM Clone UI (PowerShell 7)

.DESCRIPTION
Layout-focused build with log on the right side, no results grid, actions visible
without scrolling, cancel-running-jobs support, and clearer close behavior.
#>

[CmdletBinding()]
param(
    [switch]$NoRelaunch,
    [switch]$SignedOk,
    [switch]$NoAutoSign
)

$Global:VCFCloneUiVersion = '1.4'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Ensure-SelfSigned {
    param([string]$TargetPath)
    try { $sig = Get-AuthenticodeSignature -FilePath $TargetPath -ErrorAction SilentlyContinue } catch { $sig = $null }
    if ($sig -and $sig.Status -eq 'Valid') { return $false }

    Write-Host '[SelfSign] Creating/trusting a local code-signing certificate and signing the script...'
    $subject = "CN=VCFCloneUI Local Code Signing ($env:USERNAME@$env:COMPUTERNAME)"
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like 'CN=VCFCloneUI Local Code Signing*' } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert `
            -Subject $subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA `
            -KeyLength 3072 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(5)
    }

    foreach ($store in 'Cert:\CurrentUser\Root','Cert:\CurrentUser\TrustedPublisher') {
        try { $null = $cert | Copy-Item -Destination $store -Force -ErrorAction SilentlyContinue } catch {}
    }

    $null = Set-AuthenticodeSignature -FilePath $TargetPath -Certificate $cert -ErrorAction Stop
    Write-Host '[SelfSign] Script signed.'
    return $true
}

try { $pwsh = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path } catch { $pwsh = $null }
if (-not $pwsh) { $pwsh = 'pwsh.exe' }

if (-not $NoAutoSign -and -not $SignedOk) {
    try { $null = Ensure-SelfSigned -TargetPath $PSCommandPath } catch {}
    & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "$PSCommandPath" -SignedOk -NoRelaunch
    exit $LASTEXITCODE
}

if (-not $NoRelaunch) {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "$PSCommandPath" -NoRelaunch -SignedOk
        exit $LASTEXITCODE
    }
}

$script:RunDir = $null
$Global:LogFile = $null
$script:ViServer = $null
$script:CurrentJobs = @()
$script:CancelRequested = $false
$script:IsExecuting = $false
$script:TemplateSourceMap = @{}

function New-RunDir {
    param([string]$Base = (Get-Location).Path)
    if ([string]::IsNullOrWhiteSpace($Base) -or -not (Test-Path $Base)) { $Base = (Get-Location).Path }
    $dir = Join-Path $Base ("VCFCloneUI-Run-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Global:LogFile = Join-Path $dir ("VCFCloneUI-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    '' | Out-File -FilePath $Global:LogFile -Encoding utf8 -Force
    $script:RunDir = $dir
    return $dir
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}][{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    try { if ($Global:LogFile) { Add-Content -Path $Global:LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue } } catch {}
    try {
        if ($script:txtLog) {
            $script:txtLog.AppendText($line + [Environment]::NewLine)
            $script:txtLog.ScrollToEnd()
        }
    } catch {}
    Write-Host $line
}

function Pump-Ui {
    try {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $null = $script:window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ $frame.Continue = $false })
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch {}
}

function Update-ProgressUi {
    param([double]$Percent,[string]$Text,[switch]$Indeterminate)
    try {
        if ($script:pbExec) {
            $script:pbExec.IsIndeterminate = [bool]$Indeterminate
            if (-not $Indeterminate) {
                if ($Percent -lt 0) { $Percent = 0 }
                if ($Percent -gt 100) { $Percent = 100 }
                $script:pbExec.Value = $Percent
            }
        }
        if ($script:lblProgress) { $script:lblProgress.Text = $Text }
    } catch {}
}

function Has-Module { param([string]$Name) return [bool](Get-Module -ListAvailable -Name $Name | Select-Object -First 1) }

function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)
    if (Has-Module $Name) {
        try { Import-Module $Name -ErrorAction Stop | Out-Null; return $true } catch { return $false }
    }
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -AcceptLicense -ErrorAction Stop
        Import-Module $Name -ErrorAction Stop | Out-Null
        Write-Log "$Name installed/updated and imported."
        return $true
    } catch {
        Write-Log "$Name install failed: $($_.Exception.Message)" 'ERROR'
        return $false
    } finally {
        $ProgressPreference = $old
    }
}

function Set-StatusText {
    param([System.Windows.Controls.TextBlock]$Label,[string]$Text,[string]$State)
    if (-not $Label) { return }
    $Label.Text = $Text
    switch ($State) {
        'OK'   { $Label.Foreground = [Windows.Media.Brushes]::LightGreen }
        'WARN' { $Label.Foreground = [Windows.Media.Brushes]::Gold }
        'FAIL' { $Label.Foreground = [Windows.Media.Brushes]::Tomato }
        default { $Label.Foreground = [Windows.Media.Brushes]::White }
    }
}

function Set-PowerCliCertBehavior {
    try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope User | Out-Null } catch {
        try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null } catch {}
    }
}

function Get-PortGroupNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($pg in (Get-VirtualPortGroup -ErrorAction Stop | Sort-Object Name)) {
            if ($pg.Name -and -not $names.Contains($pg.Name)) { $null = $names.Add($pg.Name) }
        }
    } catch {}
    try {
        if (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue) {
            foreach ($pg in (Get-VDPortgroup -ErrorAction Stop | Sort-Object Name)) {
                if ($pg.Name -and -not $names.Contains($pg.Name)) { $null = $names.Add($pg.Name) }
            }
        }
    } catch {}
    return @($names | Sort-Object)
}

function Get-VmFolderNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($f in (Get-Folder -Type VM -ErrorAction Stop | Sort-Object Name)) {
            if ($f.Name -and -not $names.Contains($f.Name)) { $null = $names.Add($f.Name) }
        }
    } catch {}
    return @($names | Sort-Object)
}

function Get-CustomizationSpecNames {
    try { return @('<None>') + @(Get-OSCustomizationSpec -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name) }
    catch { return @('<None>') }
}


function Get-DeployableTemplateSources {
    $items = @()

    try {
        foreach ($t in (Get-Template -ErrorAction Stop | Sort-Object Name)) {
            $items += [pscustomobject]@{
                Display    = "vCenter Template :: $($t.Name)"
                SourceType = 'vCenterTemplate'
                Name       = $t.Name
                Library    = ''
                ItemType   = 'Template'
            }
        }
    } catch {}

    try {
        if (Get-Command Get-ContentLibraryItem -ErrorAction SilentlyContinue) {
            foreach ($lib in @(Get-ContentLibrary -ErrorAction SilentlyContinue | Sort-Object Name)) {
                foreach ($item in @(Get-ContentLibraryItem -ContentLibrary $lib -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $itemType = ''
                    try { $itemType = [string]$item.ItemType } catch {}
                    if ($itemType -and $itemType -notmatch '(?i)(template|ovf)') { continue }

                    $items += [pscustomobject]@{
                        Display    = "Content Library :: $($lib.Name) :: $($item.Name)"
                        SourceType = 'ContentLibraryItem'
                        Name       = $item.Name
                        Library    = $lib.Name
                        ItemType   = $(if ($itemType) { $itemType } else { 'ContentLibraryItem' })
                    }
                }
            }
        }
    } catch {}

    return @($items | Sort-Object Display)
}

function Resolve-SelectedTemplateSource {
    param([Parameter(Mandatory)][string]$Selection)

    if ($script:TemplateSourceMap -and $script:TemplateSourceMap.ContainsKey($Selection)) {
        return $script:TemplateSourceMap[$Selection]
    }

    throw "Selected template source [$Selection] is not in the current inventory. Refresh inventory and try again."
}

function Get-DefaultResourcePool {
    param([Parameter(Mandatory)][object]$Cluster)
    $rp = Get-ResourcePool -Location $Cluster -Name 'Resources' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rp) { $rp = Get-ResourcePool -Location $Cluster -ErrorAction Stop | Select-Object -First 1 }
    if (-not $rp) { throw "Unable to locate a resource pool for cluster [$($Cluster.Name)]." }
    return $rp
}

function Get-ConnectedHostsForCluster {
    param([Parameter(Mandatory)][object]$Cluster)
    $hosts = Get-VMHost -Location $Cluster -ErrorAction Stop |
        Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' } |
        Sort-Object Name
    if (-not $hosts -or $hosts.Count -lt 1) { throw "No connected, powered-on hosts found in cluster [$($Cluster.Name)]." }
    return @($hosts)
}

function Refresh-Inventory {
    if (-not $script:ViServer) { throw 'Not connected to vCenter.' }
    Write-Log 'Refreshing inventory from vCenter...'

    $templateSources = @(Get-DeployableTemplateSources)
    $vcTemplateCount = @($templateSources | Where-Object { $_.SourceType -eq 'vCenterTemplate' }).Count
    $clTemplateCount = @($templateSources | Where-Object { $_.SourceType -eq 'ContentLibraryItem' }).Count
    $clusters   = @(Get-Cluster -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name)
    $datastores = @(Get-Datastore -ErrorAction Stop | Where-Object { $_.ExtensionData.Summary.Accessible -eq $true } | Sort-Object Name | Select-Object -ExpandProperty Name)
    $networks   = @(Get-PortGroupNames)
    $folders    = @(Get-VmFolderNames)
    $custSpecs  = @(Get-CustomizationSpecNames)

    $script:TemplateSourceMap = @{}
    $script:cmbTemplate.Items.Clear()
    foreach ($src in $templateSources) {
        $script:TemplateSourceMap[$src.Display] = $src
        [void]$script:cmbTemplate.Items.Add($src.Display)
    }

    $script:cmbCluster.Items.Clear();   foreach ($x in $clusters)   { [void]$script:cmbCluster.Items.Add($x) }
    $script:cmbDatastore.Items.Clear(); foreach ($x in $datastores) { [void]$script:cmbDatastore.Items.Add($x) }
    $script:cmbNetwork.Items.Clear();   foreach ($x in $networks)   { [void]$script:cmbNetwork.Items.Add($x) }
    $script:cmbFolder.Items.Clear();    foreach ($x in $folders)    { [void]$script:cmbFolder.Items.Add($x) }
    $script:cmbCustSpec.Items.Clear();  foreach ($x in $custSpecs)  { [void]$script:cmbCustSpec.Items.Add($x) }

    if ($script:cmbTemplate.Items.Count -gt 0 -and -not $script:cmbTemplate.SelectedItem)   { $script:cmbTemplate.SelectedIndex = 0 }
    if ($script:cmbCluster.Items.Count -gt 0 -and -not $script:cmbCluster.SelectedItem)     { $script:cmbCluster.SelectedIndex = 0 }
    if ($script:cmbDatastore.Items.Count -gt 0 -and -not $script:cmbDatastore.SelectedItem) { $script:cmbDatastore.SelectedIndex = 0 }
    if ($script:cmbNetwork.Items.Count -gt 0 -and -not $script:cmbNetwork.SelectedItem)     { $script:cmbNetwork.SelectedIndex = 0 }
    if ($script:cmbFolder.Items.Count -gt 0 -and -not $script:cmbFolder.SelectedItem)       { $script:cmbFolder.SelectedIndex = 0 }
    if ($script:cmbCustSpec.Items.Count -gt 0 -and -not $script:cmbCustSpec.SelectedItem)   { $script:cmbCustSpec.SelectedIndex = 0 }

    Write-Log ("Inventory loaded. vCenter Templates={0}, Content Library Items={1}, Clusters={2}, Datastores={3}, Networks={4}, Folders={5}, CustomizationSpecs={6}" -f $vcTemplateCount, $clTemplateCount, $clusters.Count, $datastores.Count, $networks.Count, $folders.Count, ([Math]::Max(0, $custSpecs.Count - 1)))
}

function Connect-VCenterUi {
    $server = ($script:txtVCenterFqdn.Text + '').Trim()
    $user   = ($script:txtVCenterUser.Text + '').Trim()
    $pass   = ($script:pbVCenterPass.Password + '')

    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
        throw 'vCenter server, username, and password are required.'
    }

    if (-not (Ensure-Module -Name 'VCF.PowerCLI')) { throw 'VCF.PowerCLI could not be installed/imported.' }
    Import-Module VCF.PowerCLI -ErrorAction SilentlyContinue | Out-Null
    Set-PowerCliCertBehavior

    $existing = $global:DefaultVIServers | Where-Object { $_.Name -eq $server -and $_.IsConnected } | Select-Object -First 1
    if ($existing) {
        $script:ViServer = $existing
    } else {
        $cred = [pscredential]::new($user,(ConvertTo-SecureString $pass -AsPlainText -Force))
        $script:ViServer = Connect-VIServer -Server $server -Credential $cred -WarningAction SilentlyContinue -ErrorAction Stop
    }
    Refresh-Inventory
    return $script:ViServer
}

function Find-FirstAvailableNumber {
    param([Parameter(Mandatory)][string]$Pattern,[int]$Minimum=1)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { throw 'Naming pattern is required.' }
    if ($Minimum -lt 0) { $Minimum = 0 }
    $regex = '^{0}-(\d{{3}})$' -f [regex]::Escape($Pattern)
    $used = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($name in (Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name)) {
            if ($name -match $regex) { [void]$used.Add([int]$Matches[1]) }
        }
    } catch {}
    $n = $Minimum
    while ($used.Contains($n)) { $n++ }
    return $n
}

function New-ClonePlan {
    param([Parameter(Mandatory)][string]$Pattern,[Parameter(Mandatory)][int]$StartNumber,[Parameter(Mandatory)][int]$Count)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { throw 'Naming pattern is required.' }
    if ($StartNumber -lt 0) { throw 'Start number must be 0 or greater.' }
    if ($Count -lt 1) { throw 'VM count must be at least 1.' }
    $names = @()
    for ($i=0; $i -lt $Count; $i++) { $names += ('{0}-{1:D3}' -f $Pattern, ($StartNumber + $i)) }
    return $names
}

function Get-UiValues {
    $count = 0; $start = 0; $batch = 0; $cpu = 0; $mem = 0.0
    [void][int]::TryParse(($script:txtVmCount.Text + '').Trim(), [ref]$count)
    [void][int]::TryParse(($script:txtStartNumber.Text + '').Trim(), [ref]$start)
    [void][int]::TryParse(($script:txtBatchSize.Text + '').Trim(), [ref]$batch)
    [void][int]::TryParse(($script:txtCpu.Text + '').Trim(), [ref]$cpu)
    [void][double]::TryParse(($script:txtMemoryGB.Text + '').Trim(), [ref]$mem)

    $templateSelection = if ($script:cmbTemplate.SelectedItem) { $script:cmbTemplate.SelectedItem.ToString() } else { '' }
    $templateSource = $null
    if ($templateSelection -and $script:TemplateSourceMap.ContainsKey($templateSelection)) {
        $templateSource = $script:TemplateSourceMap[$templateSelection]
    }

    [pscustomobject]@{
        Template      = $templateSelection
        TemplateSource= $templateSource
        Cluster       = if ($script:cmbCluster.SelectedItem)   { $script:cmbCluster.SelectedItem.ToString() } else { '' }
        Datastore     = if ($script:cmbDatastore.SelectedItem) { $script:cmbDatastore.SelectedItem.ToString() } else { '' }
        Network       = if ($script:cmbNetwork.SelectedItem)   { $script:cmbNetwork.SelectedItem.ToString() } else { '' }
        Folder        = if ($script:cmbFolder.SelectedItem)    { $script:cmbFolder.SelectedItem.ToString() } else { '' }
        CustSpec      = if ($script:cmbCustSpec.SelectedItem)  { $script:cmbCustSpec.SelectedItem.ToString() } else { '<None>' }
        Pattern       = ($script:txtNamingPattern.Text + '').Trim()
        Start         = $start
        Count         = $count
        Batch         = $batch
        Cpu           = $cpu
        MemoryGB      = $mem
        AutoDetectStart = [bool]$script:chkAutoStart.IsChecked
        VCenter       = ($script:txtVCenterFqdn.Text + '').Trim()
        Username      = ($script:txtVCenterUser.Text + '').Trim()
        Password      = ($script:pbVCenterPass.Password + '')
    }
}

function Test-DeploymentInputs {
    $v = Get-UiValues
    $errs = New-Object System.Collections.Generic.List[string]
    if (-not $script:ViServer)                        { $null = $errs.Add('Connect to vCenter first.') }
    if ([string]::IsNullOrWhiteSpace($v.Template))    { $null = $errs.Add('Select a template.') }
    if ([string]::IsNullOrWhiteSpace($v.Cluster))     { $null = $errs.Add('Select a cluster.') }
    if ([string]::IsNullOrWhiteSpace($v.Datastore))   { $null = $errs.Add('Select a datastore.') }
    if ([string]::IsNullOrWhiteSpace($v.Network))     { $null = $errs.Add('Select a network / port group.') }
    if ([string]::IsNullOrWhiteSpace($v.Folder))      { $null = $errs.Add('Select a VM folder.') }
    if ([string]::IsNullOrWhiteSpace($v.Pattern))     { $null = $errs.Add('Naming pattern is required.') }
    if ($v.Start -lt 0)                               { $null = $errs.Add('Start number must be a non-negative integer.') }
    if ($v.Count -lt 1)                               { $null = $errs.Add('Number of VMs must be a positive integer.') }
    if ($v.Batch -lt 1 -or $v.Batch -gt 6)            { $null = $errs.Add('Parallel clone count must be between 1 and 6.') }
    if (($script:txtCpu.Text + '').Trim() -and $v.Cpu -lt 1)      { $null = $errs.Add('CPU override must be blank or a positive integer.') }
    if (($script:txtMemoryGB.Text + '').Trim() -and $v.MemoryGB -le 0) { $null = $errs.Add('Memory override (GB) must be blank or greater than 0.') }
    if ($errs.Count -gt 0) { throw ($errs -join [Environment]::NewLine) }
    return $v
}

function Show-PreviewPlan {
    $v = Test-DeploymentInputs
    if ($v.AutoDetectStart) {
        $detected = Find-FirstAvailableNumber -Pattern $v.Pattern -Minimum $v.Start
        $script:txtStartNumber.Text = [string]$detected
        $v.Start = $detected
        Write-Log ("Auto-detected next available start number: {0}" -f $detected)
    }
    $names = New-ClonePlan -Pattern $v.Pattern -StartNumber $v.Start -Count $v.Count
    $plan = @()
    for ($i=0; $i -lt $names.Count; $i++) {
        $plan += [pscustomobject]@{ Name=$names[$i]; Number=('{0:D3}' -f ($v.Start + $i)) }
    }
    $script:dgPlan.ItemsSource = $null
    $script:dgPlan.ItemsSource = $plan
    Write-Log ("Preview created for {0} VM(s)." -f $plan.Count)
    return [pscustomobject]@{ Ui=$v; Plan=$plan; VmNames=$names }
}

function Validate-Deployment {
    $preview = Show-PreviewPlan
    $v = $preview.Ui
    $names = $preview.VmNames
    Write-Log 'Running validation checks...'
    Update-ProgressUi -Percent 10 -Text 'Validation running...'
    Pump-Ui

    $source = Resolve-SelectedTemplateSource -Selection $v.Template
    if ($source.SourceType -eq 'vCenterTemplate') {
        $template = Get-Template -Name $source.Name -ErrorAction Stop
    } else {
        $lib = Get-ContentLibrary -Name $source.Library -ErrorAction Stop | Select-Object -First 1
        $template = Get-ContentLibraryItem -ContentLibrary $lib -Name $source.Name -ErrorAction Stop | Select-Object -First 1
    }

    $cluster   = Get-Cluster -Name $v.Cluster -ErrorAction Stop
    $datastore = Get-Datastore -Name $v.Datastore -ErrorAction Stop
    $folder    = Get-Folder -Type VM -Name $v.Folder -ErrorAction Stop | Select-Object -First 1
    $rp        = Get-DefaultResourcePool -Cluster $cluster
    $hosts     = Get-ConnectedHostsForCluster -Cluster $cluster
    $portNames = @(Get-PortGroupNames)
    $custObj = $null
    if ($v.CustSpec -and $v.CustSpec -ne '<None>') { $custObj = Get-OSCustomizationSpec -Name $v.CustSpec -ErrorAction Stop }

    if ($portNames -notcontains $v.Network) { throw "Selected network / port group [$($v.Network)] was not found in current inventory." }
    $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) { throw ("Duplicate VM names in plan: {0}" -f (($dupes | Select-Object -ExpandProperty Name) -join ', ')) }
    $existing = @()
    try { $existing = @(Get-VM -Name $names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) } catch {}
    if ($existing.Count -gt 0) { throw ("The following VM names already exist: {0}" -f ($existing -join ', ')) }

    foreach ($line in @(
        ("Validation OK - Template Source: {0}" -f $source.Display),
        ("Validation OK - Cluster: {0}" -f $cluster.Name),
        ("Validation OK - Datastore: {0}" -f $datastore.Name),
        ("Validation OK - Network / Port Group: {0}" -f $v.Network),
        ("Validation OK - VM Folder: {0}" -f $folder.Name),
        ("Validation OK - Resource Pool: {0}" -f $rp.Name),
        ("Validation OK - Connected hosts in cluster: {0}" -f $hosts.Count),
        ("Validation OK - Planned VM count: {0}" -f $names.Count),
        ("Validation OK - Parallel clones: {0}" -f $v.Batch),
        ("Validation OK - CPU override: {0}" -f $(if ($v.Cpu -gt 0) { $v.Cpu } else { '<template default>' })),
        ("Validation OK - Memory override (GB): {0}" -f $(if ($v.MemoryGB -gt 0) { $v.MemoryGB } else { '<template default>' })),
        'Validation OK - Name collision check: No duplicates found'
    )) { Write-Log $line }

    if ($source.SourceType -eq 'ContentLibraryItem' -and $custObj) {
        Write-Log ("Validation WARN - OSCustomizationSpec [{0}] is selected, but New-VM -ContentLibraryItem does not support OSCustomizationSpec. The content library deployment will continue without applying the customization spec during deployment." -f $custObj.Name) 'WARN'
    } elseif ($custObj) {
        Write-Log ("Validation OK - Customization Spec: {0}" -f $custObj.Name)
    } else {
        Write-Log 'Validation OK - Customization Spec: <None>'
    }

    Update-ProgressUi -Percent 100 -Text 'Validation complete.'
    Write-Log 'Validation completed successfully.'
    return [pscustomobject]@{ Ui=$v; Plan=$preview.Plan; VmNames=$names; Source=$source; Template=$template; Cluster=$cluster; Datastore=$datastore; Folder=$folder; ResourcePool=$rp; Hosts=$hosts; Customization=$custObj }
}

function Start-CloneJobs {
    param([Parameter(Mandatory)][psobject]$Context)
    Import-Module ThreadJob -ErrorAction SilentlyContinue | Out-Null
    $jobs = @(); $index = 0
    foreach ($vmName in $Context.VmNames) {
        $targetHost = $Context.Hosts[$index % $Context.Hosts.Count]; $index++
        Write-Log ("Queueing clone job for {0} on host {1} from source [{2}]" -f $vmName, $targetHost.Name, $Context.Source.Display)
        $job = Start-ThreadJob -Name $vmName -ThrottleLimit $Context.Ui.Batch -ArgumentList @(
            $Context.Ui.VCenter,
            $Context.Ui.Username,
            $Context.Ui.Password,
            $Context.Source.SourceType,
            $Context.Source.Library,
            $Context.Source.Name,
            $Context.Ui.Cluster,
            $Context.Ui.Datastore,
            $Context.Ui.Network,
            $Context.Ui.Folder,
            $Context.Ui.CustSpec,
            $Context.Ui.Cpu,
            $Context.Ui.MemoryGB,
            $vmName,
            $targetHost.Name
        ) -ScriptBlock {
            param($Server,$User,$Pass,$SourceType,$SourceLibrary,$SourceName,$ClusterNameInner,$DatastoreName,$PortGroup,$FolderName,$CustSpecName,$CpuOverride,$MemoryGBOverride,$VmName,$HostName)
            $ErrorActionPreference = 'Stop'
            Import-Module VCF.PowerCLI -ErrorAction SilentlyContinue | Out-Null
            try {
                Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope User | Out-Null
            } catch {
                try { Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null } catch {}
            }

            $viServer = $null
            try {
                $cred = [pscredential]::new($User,(ConvertTo-SecureString $Pass -AsPlainText -Force))
                $viServer = Connect-VIServer -Server $Server -Credential $cred -WarningAction SilentlyContinue -ErrorAction Stop

                $ds        = Get-Datastore -Server $viServer -Name $DatastoreName -ErrorAction Stop
                $cluster   = Get-Cluster -Server $viServer -Name $ClusterNameInner -ErrorAction Stop
                $vmHostObj = Get-VMHost -Server $viServer -Name $HostName -ErrorAction Stop
                $folder    = Get-Folder -Server $viServer -Type VM -Name $FolderName -ErrorAction Stop | Select-Object -First 1
                $rp        = Get-ResourcePool -Server $viServer -Location $cluster -Name 'Resources' -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $rp) {
                    $rp = Get-ResourcePool -Server $viServer -Location $cluster -ErrorAction Stop | Select-Object -First 1
                }

                $custIgnored = $false
                if ($SourceType -eq 'ContentLibraryItem') {
                    $lib = Get-ContentLibrary -Server $viServer -Name $SourceLibrary -ErrorAction Stop | Select-Object -First 1
                    $cli = Get-ContentLibraryItem -Server $viServer -ContentLibrary $lib -Name $SourceName -ErrorAction Stop | Select-Object -First 1
                    $newVmParams = @{
                        Name               = $VmName
                        ContentLibraryItem = $cli
                        Datastore          = $ds
                        VMHost             = $vmHostObj
                        ResourcePool       = $rp
                        Location           = $folder
                        Server             = $viServer
                        ErrorAction        = 'Stop'
                    }
                    if ($CustSpecName -and $CustSpecName -ne '<None>') { $custIgnored = $true }
                    $vm = New-VM @newVmParams
                } else {
                    $tmpl = Get-Template -Server $viServer -Name $SourceName -ErrorAction Stop
                    $newVmParams = @{
                        Name         = $VmName
                        Template     = $tmpl
                        Datastore    = $ds
                        VMHost       = $vmHostObj
                        ResourcePool = $rp
                        Location     = $folder
                        Server       = $viServer
                        ErrorAction  = 'Stop'
                    }
                    if ($CustSpecName -and $CustSpecName -ne '<None>') {
                        $newVmParams['OSCustomizationSpec'] = (Get-OSCustomizationSpec -Server $viServer -Name $CustSpecName -ErrorAction Stop)
                    }
                    $vm = New-VM @newVmParams
                }

                foreach ($nic in @(Get-NetworkAdapter -VM $vm -Server $viServer -ErrorAction SilentlyContinue)) {
                    Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $PortGroup -Connected:$true -StartConnected:$true -Confirm:$false -ErrorAction Stop | Out-Null
                }
                if ($CpuOverride -gt 0 -or $MemoryGBOverride -gt 0) {
                    $setParams = @{ VM=$vm; Confirm=$false; ErrorAction='Stop' }
                    if ($CpuOverride -gt 0)      { $setParams['NumCpu'] = [int]$CpuOverride }
                    if ($MemoryGBOverride -gt 0) { $setParams['MemoryGB'] = [double]$MemoryGBOverride }
                    $vm = Set-VM @setParams
                }
                Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null

                $sourceSummary = if ($SourceType -eq 'ContentLibraryItem') {
                    "ContentLibrary={0}/{1}" -f $SourceLibrary, $SourceName
                } else {
                    "vCenterTemplate={0}" -f $SourceName
                }
                $custNote = if ($custIgnored) { '; OSCustomizationSpec ignored for content library deployment' } else { '' }
                [pscustomobject]@{
                    VMName  = $VmName
                    Host    = $HostName
                    Status  = 'Success'
                    Details = ('{0}; Folder={1}; Datastore={2}; Network={3}; CPU={4}; MemoryGB={5}{6}' -f $sourceSummary,$FolderName,$DatastoreName,$PortGroup,($(if ($CpuOverride -gt 0) { $CpuOverride } else { 'template' })),($(if ($MemoryGBOverride -gt 0) { $MemoryGBOverride } else { 'template' })),$custNote)
                }
            } catch {
                [pscustomobject]@{
                    VMName  = $VmName
                    Host    = $HostName
                    Status  = 'Failed'
                    Details = $_.Exception.Message
                }
            } finally {
                try {
                    if ($viServer) {
                        Disconnect-VIServer -Server $viServer -Force -Confirm:$false | Out-Null
                    }
                } catch {}
            }
        }
        $jobs += $job
    }
    return $jobs
}

function Cancel-Execution {
    $script:CancelRequested = $true
    Write-Log 'Cancel requested by user.' 'WARN'
    foreach ($job in @($script:CurrentJobs)) {
        try {
            if ($job.State -notin @('Completed','Failed','Stopped')) {
                Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Log ("Cancelled job for VM [{0}]" -f $job.Name) 'WARN'
            }
        } catch {}
    }
    Update-ProgressUi -Percent 0 -Text 'Cancellation requested.'
    try { $script:btnCancel.IsEnabled = $false } catch {}
}

function Wait-CloneJobsWithProgress {
    param([Parameter(Mandatory)][System.Collections.IEnumerable]$Jobs,[Parameter(Mandatory)][int]$TotalCount)
    $jobList = @($Jobs)
    if ($TotalCount -lt 1) { $TotalCount = [Math]::Max(1,$jobList.Count) }
    $results = @(); $received = New-Object 'System.Collections.Generic.HashSet[string]'; $lastState = @{}
    foreach ($job in $jobList) {
        $lastState[$job.Id.ToString()] = ''
        Write-Log ("Execution state - VM [{0}] -> Queued" -f $job.Name)
    }
    Update-ProgressUi -Percent 0 -Text 'Deployment started...'
    try { $script:btnCancel.IsEnabled = $true } catch {}
    while ($true) {
        $doneCount = 0
        foreach ($job in $jobList) {
            $idKey = $job.Id.ToString(); $state = [string]$job.State
            if ($lastState[$idKey] -ne $state) {
                $lastState[$idKey] = $state
                Write-Log ("Execution state - VM [{0}] -> {1}" -f $job.Name, $state)
            }
            switch ($state) {
                'Completed' {
                    $doneCount++
                    if (-not $received.Contains($idKey)) {
                        try {
                            $res = Receive-Job -Job $job -ErrorAction SilentlyContinue
                            if ($res) { $results += $res; Write-Log ("Execution result - VM [{0}] -> {1}; Host={2}; {3}" -f $res.VMName,$res.Status,$res.Host,$res.Details) }
                            else { $results += [pscustomobject]@{ VMName=$job.Name; Host=''; Status='Completed'; Details='No output returned' }; Write-Log ("Execution result - VM [{0}] -> Completed; No output returned" -f $job.Name) 'WARN' }
                        } catch {
                            $results += [pscustomobject]@{ VMName=$job.Name; Host=''; Status='Failed'; Details=$_.Exception.Message }
                            Write-Log ("Execution result - VM [{0}] -> Failed; {1}" -f $job.Name,$_.Exception.Message) 'ERROR'
                        }
                        [void]$received.Add($idKey)
                    }
                }
                'Failed' {
                    $doneCount++
                    if (-not $received.Contains($idKey)) {
                        try {
                            $res = Receive-Job -Job $job -ErrorAction SilentlyContinue
                            if ($res) { $results += $res; Write-Log ("Execution result - VM [{0}] -> {1}; Host={2}; {3}" -f $res.VMName,$res.Status,$res.Host,$res.Details) 'ERROR' }
                            else { $results += [pscustomobject]@{ VMName=$job.Name; Host=''; Status='Failed'; Details='Job failed without returned object' }; Write-Log ("Execution result - VM [{0}] -> Failed; Job failed without returned object" -f $job.Name) 'ERROR' }
                        } catch {
                            $results += [pscustomobject]@{ VMName=$job.Name; Host=''; Status='Failed'; Details=$_.Exception.Message }
                            Write-Log ("Execution result - VM [{0}] -> Failed; {1}" -f $job.Name,$_.Exception.Message) 'ERROR'
                        }
                        [void]$received.Add($idKey)
                    }
                }
                'Stopped' {
                    $doneCount++
                    if (-not $received.Contains($idKey)) {
                        $results += [pscustomobject]@{ VMName=$job.Name; Host=''; Status='Cancelled'; Details='Job stopped' }
                        Write-Log ("Execution result - VM [{0}] -> Cancelled; Job stopped" -f $job.Name) 'WARN'
                        [void]$received.Add($idKey)
                    }
                }
                default { }
            }
        }
        $percent = [Math]::Round(($doneCount / $TotalCount) * 100,0)
        if ($script:CancelRequested) { Update-ProgressUi -Percent $percent -Text ("Cancelling... {0}/{1} finalised" -f $doneCount,$TotalCount) }
        else { Update-ProgressUi -Percent $percent -Text ("Deploying VMs... {0}/{1} complete" -f $doneCount,$TotalCount) }
        Pump-Ui
        if ($doneCount -ge $TotalCount) { break }
        Start-Sleep -Milliseconds 300
    }
    foreach ($job in $jobList) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {} }
    try { $script:btnCancel.IsEnabled = $false } catch {}
    if ($script:CancelRequested) { Update-ProgressUi -Percent 0 -Text 'Cancelled.' } else { Update-ProgressUi -Percent 100 -Text 'Deployment complete.' }
    Pump-Ui
    return $results
}

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VCF9 Clone Bulk Virtual Machines (v{#VER#})"
        Height="960" Width="1540" MinHeight="820" MinWidth="1280"
        WindowStartupLocation="CenterScreen"
        Background="#0f0f10" Foreground="#f3f3f3">
    <Window.Resources>
        <SolidColorBrush x:Key="Bg" Color="#0f0f10"/>
        <SolidColorBrush x:Key="PanelBg" Color="#1c1c1e"/>
        <SolidColorBrush x:Key="Fg" Color="#f3f3f3"/>
        <SolidColorBrush x:Key="Border" Color="#3a3a3a"/>
        <SolidColorBrush x:Key="HeaderBg" Color="#2a2a2c"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HotTrackBrushKey}" Color="#f3f3f3"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#f3f3f3"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#1c1c1e"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#1c1c1e"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#f3f3f3"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#3a3a3a"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#f3f3f3"/>

        <Style TargetType="GroupBox"><Setter Property="Margin" Value="8"/><Setter Property="Padding" Value="8"/><Setter Property="BorderBrush" Value="{StaticResource Border}"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Background" Value="{StaticResource Bg}"/></Style>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Margin" Value="8,0,8,6"/></Style>
        <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Margin" Value="8,4,8,4"/></Style>
        <Style x:Key="InputTextBoxStyle" TargetType="TextBox"><Setter Property="Margin" Value="8"/><Setter Property="Padding" Value="4"/><Setter Property="Height" Value="28"/><Setter Property="Background" Value="{StaticResource PanelBg}"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="BorderBrush" Value="{StaticResource Border}"/></Style>
        <Style TargetType="PasswordBox"><Setter Property="Margin" Value="8"/><Setter Property="Padding" Value="4"/><Setter Property="Height" Value="28"/><Setter Property="Background" Value="{StaticResource PanelBg}"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="BorderBrush" Value="#565656"/></Style>
        <Style TargetType="ComboBox">
            <Setter Property="Margin" Value="8"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="Height" Value="28"/>
            <Setter Property="Foreground" Value="{StaticResource Fg}"/>
            <Setter Property="Background" Value="{StaticResource PanelBg}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2">
                                            <Grid>
                                                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="22"/></Grid.ColumnDefinitions>
                                                <ContentPresenter Grid.Column="0" Margin="6,3" VerticalAlignment="Center" Content="{Binding RelativeSource={RelativeSource TemplatedParent}, Path=TemplatedParent.SelectionBoxItem}" TextElement.Foreground="{StaticResource Fg}"/>
                                                <Path Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Center" Fill="{StaticResource Fg}" Data="M 0 0 L 4 4 L 8 0 Z"/>
                                            </Grid>
                                        </Border>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False">
                                <Border Background="{StaticResource PanelBg}" BorderBrush="{StaticResource Border}" BorderThickness="1" CornerRadius="2">
                                    <ScrollViewer Margin="4" SnapsToDevicePixels="True"><ItemsPresenter/></ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Background" Value="{StaticResource PanelBg}"/><Setter Property="Padding" Value="6,3"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Style.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#3a3a3a"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#3a3a3a"/></Trigger></Style.Triggers></Style>
        <Style TargetType="Button"><Setter Property="Margin" Value="8,6,8,6"/><Setter Property="Padding" Value="8,4"/><Setter Property="Height" Value="28"/><Setter Property="Background" Value="#2a2a2c"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="BorderBrush" Value="#565656"/></Style>
        <Style TargetType="ProgressBar"><Setter Property="Margin" Value="8"/><Setter Property="Height" Value="20"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/></Style>
        <Style TargetType="DataGrid"><Setter Property="Margin" Value="8"/><Setter Property="Background" Value="{StaticResource PanelBg}"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="GridLinesVisibility" Value="All"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="BorderBrush" Value="{StaticResource Border}"/><Setter Property="AlternationCount" Value="2"/><Setter Property="RowBackground" Value="#19191b"/><Setter Property="AlternatingRowBackground" Value="#151517"/><Setter Property="HorizontalGridLinesBrush" Value="#303034"/><Setter Property="VerticalGridLinesBrush" Value="#303034"/><Setter Property="SelectionUnit" Value="FullRow"/></Style>
        <Style TargetType="DataGridColumnHeader"><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Background" Value="{StaticResource HeaderBg}"/><Setter Property="BorderBrush" Value="{StaticResource Border}"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    </Window.Resources>
    <Grid Margin="8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
        <Grid Grid.Column="0">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <GroupBox Header="Prerequisites" Grid.Row="0">
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0"><TextBlock x:Name="lblPS" Text="PowerShell: (checking...)"/><TextBlock x:Name="lblWPF" Text=".NET/WPF: (checking...)"/><TextBlock x:Name="lblVCFPCLI" Text="VCF.PowerCLI: (checking...)"/><TextBlock x:Name="lblThreadJob" Text="ThreadJob: (checking...)"/></StackPanel><StackPanel Grid.Column="1" VerticalAlignment="Center"><Button x:Name="btnRecheck" Content="Recheck" MinWidth="110"/></StackPanel><StackPanel Grid.Column="2" VerticalAlignment="Center"><Button x:Name="btnInstallVCFPCLI" Content="Install VCF.PowerCLI" MinWidth="170"/></StackPanel></Grid>
            </GroupBox>
            <GroupBox Header="vCenter Connection" Grid.Row="1">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="2*"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions><TextBlock Grid.Row="0" Grid.Column="0" Text="vCenter FQDN / IP" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="1" Text="Username" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="2" Text="Password" Margin="8,0,8,2"/><TextBox Grid.Row="1" Grid.Column="0" x:Name="txtVCenterFqdn" Style="{StaticResource InputTextBoxStyle}"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="txtVCenterUser" Style="{StaticResource InputTextBoxStyle}"/><PasswordBox Grid.Row="1" Grid.Column="2" x:Name="pbVCenterPass"/><StackPanel Grid.Row="2" Grid.ColumnSpan="3" Orientation="Horizontal"><Button x:Name="btnConnect" Content="Connect / Refresh Inventory" MinWidth="220"/><TextBlock x:Name="lblConnStatus" Text="Not connected" Margin="10,4,0,0" Foreground="#bfbfbf"/></StackPanel></Grid>
            </GroupBox>
            <GroupBox Header="Deployment Selections" Grid.Row="2">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="1*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions><TextBlock Grid.Row="0" Grid.Column="0" Text="Template / Content Library Item" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="1" Text="Cluster" Margin="8,0,8,2"/><ComboBox Grid.Row="1" Grid.Column="0" x:Name="cmbTemplate"/><ComboBox Grid.Row="1" Grid.Column="1" x:Name="cmbCluster"/><TextBlock Grid.Row="2" Grid.Column="0" Text="Datastore" Margin="8,0,8,2"/><TextBlock Grid.Row="2" Grid.Column="1" Text="Network / Port Group" Margin="8,0,8,2"/><ComboBox Grid.Row="3" Grid.Column="0" x:Name="cmbDatastore"/><ComboBox Grid.Row="3" Grid.Column="1" x:Name="cmbNetwork"/><TextBlock Grid.Row="4" Grid.Column="0" Text="VM Folder" Margin="8,0,8,2"/><TextBlock Grid.Row="4" Grid.Column="1" Text="Customization Spec" Margin="8,0,8,2"/><ComboBox Grid.Row="5" Grid.Column="0" x:Name="cmbFolder"/><ComboBox Grid.Row="5" Grid.Column="1" x:Name="cmbCustSpec"/></Grid>
            </GroupBox>
            <GroupBox Header="Clone Options" Grid.Row="3">
                <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="0.9*"/><ColumnDefinition Width="0.9*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions><TextBlock Grid.Row="0" Grid.Column="0" Text="Naming Pattern" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="1" Text="Start Number" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="2" Text="Number of VMs" Margin="8,0,8,2"/><TextBlock Grid.Row="0" Grid.Column="3" Text="Parallel Clones (1-6)" Margin="8,0,8,2"/><TextBox Grid.Row="1" Grid.Column="0" x:Name="txtNamingPattern" Text="APP" Style="{StaticResource InputTextBoxStyle}"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="txtStartNumber" Text="10" Style="{StaticResource InputTextBoxStyle}"/><TextBox Grid.Row="1" Grid.Column="2" x:Name="txtVmCount" Text="1" Style="{StaticResource InputTextBoxStyle}"/><TextBox Grid.Row="1" Grid.Column="3" x:Name="txtBatchSize" Text="2" Style="{StaticResource InputTextBoxStyle}"/><StackPanel Grid.Row="2" Grid.ColumnSpan="2" Orientation="Horizontal"><CheckBox x:Name="chkAutoStart" Content="Auto detect first available number starting at Start Number" IsChecked="True"/><Button x:Name="btnDetectStart" Content="Detect Now" MinWidth="110"/></StackPanel><Grid Grid.Row="3" Grid.ColumnSpan="4"><Grid.ColumnDefinitions><ColumnDefinition Width="1*"/><ColumnDefinition Width="1*"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0"><TextBlock Text="CPU Override" Margin="8,0,8,2"/><TextBox x:Name="txtCpu" Text="" Style="{StaticResource InputTextBoxStyle}"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="Memory Override (GB)" Margin="8,0,8,2"/><TextBox x:Name="txtMemoryGB" Text="" Style="{StaticResource InputTextBoxStyle}"/></StackPanel><TextBlock Grid.Column="2" VerticalAlignment="Center" Text="Names are generated as &lt;pattern&gt;-00x. Leave CPU / Memory blank to keep template defaults." Foreground="#bfbfbf" FontSize="11" Margin="8,18,8,6"/></Grid></Grid>
            </GroupBox>
            <GroupBox Header="Actions" Grid.Row="4">
                <StackPanel><WrapPanel><Button x:Name="btnPreview" Content="Preview Names" MinWidth="120"/><Button x:Name="btnValidate" Content="Validate" MinWidth="120"/><Button x:Name="btnExecute" Content="Execute" MinWidth="120"/><Button x:Name="btnCancel" Content="Cancel Running Jobs" MinWidth="150" IsEnabled="False"/><Button x:Name="btnOpenRun" Content="Open Run Folder" MinWidth="140"/><Button x:Name="btnCloseWindow" Content="Close Window" MinWidth="120"/></WrapPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><ProgressBar Grid.Column="0" x:Name="pbExec" Value="0"/><TextBlock Grid.Column="1" x:Name="lblProgress" Text="Idle" Margin="8,2,8,2" VerticalAlignment="Center"/></Grid></StackPanel>
            </GroupBox>
        </Grid>
        <Grid Grid.Column="1"><Grid.RowDefinitions><RowDefinition Height="2*"/><RowDefinition Height="3*"/></Grid.RowDefinitions><GroupBox Header="Planned VM Names" Grid.Row="0"><DataGrid x:Name="dgPlan" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"><DataGrid.Columns><DataGridTextColumn Header="VM Name" Binding="{Binding Name}" Width="*"/><DataGridTextColumn Header="Index" Binding="{Binding Number}" Width="120"/></DataGrid.Columns></DataGrid></GroupBox><GroupBox Header="Log" Grid.Row="1"><Grid><TextBox x:Name="txtLog" Style="{x:Null}" Margin="8" Padding="6" AcceptsReturn="True" TextWrapping="NoWrap" VerticalAlignment="Stretch" HorizontalAlignment="Stretch" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#050505" Foreground="#f3f3f3" BorderBrush="#3a3a3a" FontFamily="Consolas" FontSize="12"/></Grid></GroupBox></Grid>
    </Grid>
</Window>
"@

$xaml = $xaml.Replace('{#VER#}', $Global:VCFCloneUiVersion)
try { $script:window = [Windows.Markup.XamlReader]::Parse($xaml) }
catch {
    [System.Windows.MessageBox]::Show("XAML parse failed:`r`n$($_.Exception.Message)", 'VCF Clone UI', 'OK', 'Error') | Out-Null
    throw
}

$script:lblPS             = $script:window.FindName('lblPS')
$script:lblWPF            = $script:window.FindName('lblWPF')
$script:lblVCFPCLI        = $script:window.FindName('lblVCFPCLI')
$script:lblThreadJob      = $script:window.FindName('lblThreadJob')
$script:btnRecheck        = $script:window.FindName('btnRecheck')
$script:btnInstallVCFPCLI = $script:window.FindName('btnInstallVCFPCLI')
$script:txtVCenterFqdn    = $script:window.FindName('txtVCenterFqdn')
$script:txtVCenterUser    = $script:window.FindName('txtVCenterUser')
$script:pbVCenterPass     = $script:window.FindName('pbVCenterPass')
$script:btnConnect        = $script:window.FindName('btnConnect')
$script:lblConnStatus     = $script:window.FindName('lblConnStatus')
$script:cmbTemplate       = $script:window.FindName('cmbTemplate')
$script:cmbCluster        = $script:window.FindName('cmbCluster')
$script:cmbDatastore      = $script:window.FindName('cmbDatastore')
$script:cmbNetwork        = $script:window.FindName('cmbNetwork')
$script:cmbFolder         = $script:window.FindName('cmbFolder')
$script:cmbCustSpec       = $script:window.FindName('cmbCustSpec')
$script:txtNamingPattern  = $script:window.FindName('txtNamingPattern')
$script:txtStartNumber    = $script:window.FindName('txtStartNumber')
$script:txtVmCount        = $script:window.FindName('txtVmCount')
$script:txtBatchSize      = $script:window.FindName('txtBatchSize')
$script:chkAutoStart      = $script:window.FindName('chkAutoStart')
$script:btnDetectStart    = $script:window.FindName('btnDetectStart')
$script:txtCpu            = $script:window.FindName('txtCpu')
$script:txtMemoryGB       = $script:window.FindName('txtMemoryGB')
$script:btnPreview        = $script:window.FindName('btnPreview')
$script:btnValidate       = $script:window.FindName('btnValidate')
$script:btnExecute        = $script:window.FindName('btnExecute')
$script:btnCancel         = $script:window.FindName('btnCancel')
$script:btnOpenRun        = $script:window.FindName('btnOpenRun')
$script:btnCloseWindow    = $script:window.FindName('btnCloseWindow')
$script:pbExec            = $script:window.FindName('pbExec')
$script:lblProgress       = $script:window.FindName('lblProgress')
$script:dgPlan            = $script:window.FindName('dgPlan')
$script:txtLog            = $script:window.FindName('txtLog')

function Prereq-Check {
    $isPs7 = $PSVersionTable.PSVersion.Major -ge 7
    Set-StatusText -Label $script:lblPS -Text ("PowerShell {0}" -f $PSVersionTable.PSVersion) -State ($(if ($isPs7) { 'OK' } else { 'FAIL' }))
    Set-StatusText -Label $script:lblWPF -Text '.NET/WPF: OK' -State 'OK'
    Set-StatusText -Label $script:lblVCFPCLI -Text ($(if (Has-Module 'VCF.PowerCLI') { 'VCF.PowerCLI: Found' } else { 'VCF.PowerCLI: Not found' })) -State ($(if (Has-Module 'VCF.PowerCLI') { 'OK' } else { 'WARN' }))
    Set-StatusText -Label $script:lblThreadJob -Text ($(if ((Has-Module 'ThreadJob') -or $PSVersionTable.PSVersion.Major -ge 7) { 'ThreadJob: Found' } else { 'ThreadJob: Not found' })) -State ($(if ((Has-Module 'ThreadJob') -or $PSVersionTable.PSVersion.Major -ge 7) { 'OK' } else { 'WARN' }))
}

$script:window.Add_ContentRendered({
    try {
        if (-not $script:RunDir) { $null = New-RunDir }
        Write-Log "==== VCF9 Clone Bulk Virtual Machines started (v$Global:VCFCloneUiVersion) ===="
        Write-Log "Run folder: $script:RunDir"
        Prereq-Check
        Update-ProgressUi -Percent 0 -Text 'Idle'
    } catch {}
})

$script:btnRecheck.Add_Click({ Prereq-Check })
$script:btnInstallVCFPCLI.Add_Click({ Ensure-Module -Name 'VCF.PowerCLI' | Out-Null; Prereq-Check })
$script:btnConnect.Add_Click({
    try {
        Write-Log 'Connect / Refresh Inventory clicked.'
        Update-ProgressUi -Percent 0 -Text 'Connecting to vCenter...'
        $null = Connect-VCenterUi
        $script:lblConnStatus.Text = 'Connected'
        $script:lblConnStatus.Foreground = [Windows.Media.Brushes]::LightGreen
        Update-ProgressUi -Percent 100 -Text 'Inventory loaded.'
        Write-Log 'Connected to vCenter successfully.'
    } catch {
        $script:lblConnStatus.Text = 'Connect failed'
        $script:lblConnStatus.Foreground = [Windows.Media.Brushes]::Tomato
        Update-ProgressUi -Percent 0 -Text 'Connect failed.'
        Write-Log ("vCenter connect failed: {0}" -f $_.Exception.Message) 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'VCF Clone UI', 'OK', 'Error') | Out-Null
    }
})
$script:btnDetectStart.Add_Click({
    try {
        $pattern = ($script:txtNamingPattern.Text + '').Trim(); if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Naming pattern is required before auto-detect can run.' }
        $min = 1; [void][int]::TryParse(($script:txtStartNumber.Text + '').Trim(), [ref]$min)
        $n = Find-FirstAvailableNumber -Pattern $pattern -Minimum $min
        $script:txtStartNumber.Text = [string]$n
        Write-Log ("Detected first available number for pattern [{0}] as {1}" -f $pattern,$n)
    } catch {
        Write-Log ("Auto-detect failed: {0}" -f $_.Exception.Message) 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'VCF Clone UI', 'OK', 'Error') | Out-Null
    }
})
$script:btnPreview.Add_Click({
    try { Update-ProgressUi -Percent 0 -Text 'Building preview...'; $null = Show-PreviewPlan; Update-ProgressUi -Percent 100 -Text 'Preview ready.' }
    catch { Update-ProgressUi -Percent 0 -Text 'Preview failed.'; Write-Log ("Preview failed: {0}" -f $_.Exception.Message) 'ERROR'; [System.Windows.MessageBox]::Show($_.Exception.Message, 'VCF Clone UI', 'OK', 'Error') | Out-Null }
})
$script:btnValidate.Add_Click({
    try { $null = Validate-Deployment; [System.Windows.MessageBox]::Show('Validation completed successfully. Details were written to the log.', 'VCF Clone UI', 'OK', 'Information') | Out-Null }
    catch { Update-ProgressUi -Percent 0 -Text 'Validation failed.'; Write-Log ("Validation failed: {0}" -f $_.Exception.Message) 'ERROR'; [System.Windows.MessageBox]::Show($_.Exception.Message, 'VCF Clone UI', 'OK', 'Error') | Out-Null }
})
$script:btnCancel.Add_Click({ Cancel-Execution })
$script:btnExecute.Add_Click({
    try {
        $ctx = Validate-Deployment
        $confirmText = "Execute deployment for $($ctx.VmNames.Count) VM(s)?`n`nTemplate Source: $($ctx.Source.Display)`nCluster: $($ctx.Ui.Cluster)`nDatastore: $($ctx.Ui.Datastore)`nNetwork: $($ctx.Ui.Network)`nFolder: $($ctx.Ui.Folder)`nCustomization Spec: $($ctx.Ui.CustSpec)`nParallel clones: $($ctx.Ui.Batch)`nCPU Override: $(if ($ctx.Ui.Cpu -gt 0) { $ctx.Ui.Cpu } else { '<template>' })`nMemory Override GB: $(if ($ctx.Ui.MemoryGB -gt 0) { $ctx.Ui.MemoryGB } else { '<template>' })"
        $confirm = [System.Windows.MessageBox]::Show($confirmText, 'Confirm Deployment', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { return }
        $script:CancelRequested = $false
        $script:CurrentJobs = @()
        $script:IsExecuting = $true
        Write-Log ("Starting deployment of {0} VM(s)..." -f $ctx.VmNames.Count)
        Update-ProgressUi -Percent 0 -Text 'Starting clone jobs...'
        $script:CurrentJobs = Start-CloneJobs -Context $ctx
        $rawResults = Wait-CloneJobsWithProgress -Jobs $script:CurrentJobs -TotalCount $ctx.VmNames.Count
        $ok  = @($rawResults | Where-Object { $_.Status -eq 'Success' }).Count
        $bad = @($rawResults | Where-Object { $_.Status -eq 'Failed' }).Count
        $can = @($rawResults | Where-Object { $_.Status -eq 'Cancelled' }).Count
        Write-Log ("Deployment completed. Success={0}, Failed={1}, Cancelled={2}" -f $ok,$bad,$can)
        $resultFile = Join-Path $script:RunDir ("CloneResults-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        $rawResults | ConvertTo-Json -Depth 5 | Set-Content -Path $resultFile -Encoding utf8
        Write-Log "Results saved to $resultFile"
        if ($script:CancelRequested) { [System.Windows.MessageBox]::Show(("Execution was cancelled.`nSuccess: {0}`nFailed: {1}`nCancelled: {2}`n`nResults saved to:`n{3}" -f $ok,$bad,$can,$resultFile), 'VCF Clone UI', 'OK', 'Warning') | Out-Null }
        else { [System.Windows.MessageBox]::Show(("Deployment completed.`nSuccess: {0}`nFailed: {1}`nCancelled: {2}`n`nResults saved to:`n{3}" -f $ok,$bad,$can,$resultFile), 'VCF Clone UI', 'OK', 'Information') | Out-Null }
    } catch {
        Update-ProgressUi -Percent 0 -Text 'Execution failed.'
        try { $script:btnCancel.IsEnabled = $false } catch {}
        Write-Log ("Execution failed: {0}" -f $_.Exception.Message) 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'VCF Clone UI', 'OK', 'Error') | Out-Null
    } finally {
        $script:IsExecuting = $false
    }
})
$script:btnOpenRun.Add_Click({ try { if ($script:RunDir -and (Test-Path $script:RunDir)) { Start-Process $script:RunDir | Out-Null } } catch {} })
$script:btnCloseWindow.Add_Click({
    try {
        $active = @($script:CurrentJobs | Where-Object { $_.State -notin @('Completed','Failed','Stopped') }).Count -gt 0
        if ($active) {
            $msg = "Clone jobs are still running.`n`n'Close Window' only closes the UI. It does NOT cancel running clone jobs.`nUse 'Cancel Running Jobs' if you want to stop them first.`n`nClose the window anyway?"
            $ans = [System.Windows.MessageBox]::Show($msg, 'Close Window', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { return }
        }
        $script:window.Close()
    } catch {}
})

$null = $script:window.ShowDialog()
# SIG # Begin signature block
# MIIHgQYJKoZIhvcNAQcCoIIHcjCCB24CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCuMC2pfyCQ70v8
# 7ny05dVW0S6IRRXBHssrNmHOFGVFKKCCBFIwggROMIICtqADAgECAhAX4wkOnJTB
# oUFWHys0l6dUMA0GCSqGSIb3DQEBCwUAMD8xPTA7BgNVBAMMNFZDRkNsb25lVUkg
# TG9jYWwgQ29kZSBTaWduaW5nICh4YWRtaW5ASE9NRU9GRklDRUxBQikwHhcNMjYw
# MzIyMTIzNjEwWhcNMzEwMzIyMTI0NjEwWjA/MT0wOwYDVQQDDDRWQ0ZDbG9uZVVJ
# IExvY2FsIENvZGUgU2lnbmluZyAoeGFkbWluQEhPTUVPRkZJQ0VMQUIpMIIBojAN
# BgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAr7YmjeWzGcOtdfIC/gAeMNkz0bZZ
# pP+RQghyz91VV9E0no0Ta8w3qP2HtkzQ6B1iW1ebFnzbrGxWE31mzNftQLu7zw+l
# DrBgPTpdtGnial6fWTs9l2FIir4qKonQHPoQp5CU7buPS8UFDYXEmyOiABkg8fhH
# gRMo7hrZPr59vaKJ2T4jqVqtWeKXdX8PQc69MDU4lLGIN7mYUkP4DFEROkFiX3ng
# l30bjQ1KWbCcKv1DMFZfwrRZ1YKz/bsvqyxevOoKbmWjW5NuO0GYYZcSQe+0TdH2
# 0/KKXYJqCEhd/5GEA8e6vHvcHzNOZCeaCESED1OoBN3+iccktsX2rFtLEr9R0Dqa
# HpXF1j3fuaCKjGA1TlK+gIZUvHoU9tTY82ybS/1KKawnWB+uThZgvUo8wkGrRu1k
# toAkR5EL7yjVxBZ5pIEIRoEiemyGjM8F7xsYKOiUh3TOyuWvnioZMftJ+YR/UgR7
# Cbh6i07xci8RUTIlxFB87+giX0ChvtobWljxAgMBAAGjRjBEMA4GA1UdDwEB/wQE
# AwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQUiFtkWXIdcUox8BuB
# 5BNDfmMfljAwDQYJKoZIhvcNAQELBQADggGBAKkzObJqTrosFoqGJ7R9TLf/aoRQ
# viPvMzSMvxkKTcnYak+2cicOfe24ASSEDixCHZ3CdESGsf/nhu/+T8MgMONQI+wM
# OytkfvTDlR5w+z5Tga8D+ZkTUDyhALobca1DZtd1nsmOmp4yzLerGZ4iXSTe+ljO
# bguzFd865YhWjklUF6Mk/OmzJcI0tLZ1tqFXvXXA/57KGopK03RzFCCEl5H9h2l3
# yHNZGYvE32L8UTUskZe5UPTg9cLbO4Nod2vnFM6MVpSDqCP143f1k5m1f+JQc9sD
# D2kgM82ZNVkAqLajiERt5eu7b0I+zIYXjwDMxE8DT4A+aGtzgpPWyjJRuc+rHvey
# dX1lDyw9CnCvudBdiDhERbcPIzjnUUGt3ORgBddxM/tbNmpLdQTlAzRrSD28Ahtp
# t7Tdxt2q1jNMBTiyj0T6aroKA0WjXiYt51d2i39EAxWZUVXYKlIdVji25uT05zEW
# Fr+Nm1GEy+9cM87dMGrlU7RFQ9KRLRnQPoXE+zGCAoUwggKBAgEBMFMwPzE9MDsG
# A1UEAww0VkNGQ2xvbmVVSSBMb2NhbCBDb2RlIFNpZ25pbmcgKHhhZG1pbkBIT01F
# T0ZGSUNFTEFCKQIQF+MJDpyUwaFBVh8rNJenVDANBglghkgBZQMEAgEFAKCBhDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEi
# BCB7z8eKknzMxnFCyGklbknfG9U2xXWhUGoJXDIbD46U7DANBgkqhkiG9w0BAQEF
# AASCAYA4C72nLbhmD1n4xTQKmER71CR+NsjEDXPB/oE+Mxca90gCY1dXNIbRRwzx
# +8cRh+JfZsTfJyZWS8b1Ad+U67OWQuHFfWKV83b4JHjqbKmeZOn39XSbLR7KSXiw
# 2lquk6m7oHBRplWlPU8IYtWDlRP9zar+DTWMVambuyj5BnocQu8fEi6e+WMRP2yx
# rHPX7tN/7EROXaPfP93TgUzHsEZTAF2GmEWB+IMjTRTMDK8WqwvRg/wszuDYXJIk
# KaDABEMY/M+coSHiB4YX6sevJE2+fwtqQa0E2ooljqezhW2TqIHq+bRV4rYsybtY
# z67krHTrbD4+zASg8fUFUN1ChkaGERfS1Z0VwoPb3W+0US85qObzLAhkhmrlRPXd
# FvBR0IUpIuVS9+WoYs+u3edF4IccV++Rwfztfj/2JKW1Y6B+VZUzmkaVqpfy4S3h
# lvmJmVdS436MNgqCNoThz9WC3kGbEDYqUXbV7hixzJFF3yGZFG6l3Nc2ENzgPHBW
# Xe5woyY=
# SIG # End signature block
