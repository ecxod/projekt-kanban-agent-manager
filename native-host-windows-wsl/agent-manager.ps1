[CmdletBinding()]
param(
    [string]$InitialDistribution = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GitHubRepository = 'https://github.com/ecxod/projekt-kanban-agent-manager'
$GitHubReleasesApi = 'https://api.github.com/repos/ecxod/projekt-kanban-agent-manager/releases?per_page=20'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace ProjektKanbanAgentManager {
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern bool ShowScrollBar(IntPtr hWnd, uint wBar, bool bShow);
    }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDirectory = Split-Path -Parent $ScriptDirectory
$InstallScript = Join-Path $ScriptDirectory 'install.ps1'
$UninstallScript = Join-Path $ScriptDirectory 'uninstall.ps1'
$InstallDirectory = Join-Path $env:LOCALAPPDATA 'ProjektKanbanAgent'
$InstalledHost = Join-Path $InstallDirectory 'kanban_agent_host.py'
$VersionFile = Join-Path $PackageDirectory 'VERSION'
if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) {
    throw "Die Versionsdatei fehlt: $VersionFile"
}
$ManagerVersion = ((Get-Content -LiteralPath $VersionFile -TotalCount 1) -join '').Trim()
if (-not [regex]::IsMatch($ManagerVersion, '^\d+(\.\d+){3}$')) {
    throw "Ungültige Manager-Version in VERSION: $ManagerVersion"
}
$WslCommand = Get-Command 'wsl.exe' -ErrorAction Stop

function Normalize-DistributionName {
    param([string]$Name)
    return $Name.Replace([string][char]0, [string]::Empty).Trim([char]0xfeff).Trim()
}

function Get-WslDistributions {
    $Names = New-Object System.Collections.Generic.List[string]
    try {
        $Raw = ((& $WslCommand.Path --list --quiet 2>$null) | Out-String).Replace([string][char]0, [string]::Empty)
        foreach ($Line in ($Raw -split "`r?`n")) {
            $Name = Normalize-DistributionName $Line
            if ($Name -and -not $Names.Contains($Name)) { $Names.Add($Name) }
        }
    } catch {}

    try {
        $LxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $Lxss = Get-ItemProperty -LiteralPath $LxssPath -ErrorAction Stop
        if ($Lxss.DefaultDistribution) {
            $DefaultPath = Join-Path $LxssPath ([string]$Lxss.DefaultDistribution)
            $DefaultName = Normalize-DistributionName ([string](Get-ItemProperty -LiteralPath $DefaultPath -ErrorAction Stop).DistributionName)
            if ($DefaultName) {
                if ($Names.Contains($DefaultName)) { [void]$Names.Remove($DefaultName) }
                $Names.Insert(0, $DefaultName)
            }
        }
    } catch {}
    return $Names.ToArray()
}

function Add-Label {
    param([string]$Text, [int]$Top, [System.Windows.Forms.TabPage]$Page)
    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = $Text
    $Label.Left = 16
    $Label.Top = $Top
    $Label.Width = 180
    $Label.Height = 24
    $Label.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $Page.Controls.Add($Label)
    return $Label
}

function New-TextBox {
    param([int]$Top, [string]$Value = '', [System.Windows.Forms.TabPage]$Page)
    $Control = New-Object System.Windows.Forms.TextBox
    $Control.Left = 205
    $Control.Top = $Top - 3
    $Control.Width = 455
    $Control.Height = 28
    $Control.Text = $Value
    $Control.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $Page.Controls.Add($Control)
    return $Control
}

function Write-Log {
    param([string]$Message)
    if ($null -eq $LogBox) {
        return
    }
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogBox.AppendText("[$Timestamp] $Message`r`n")
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.ScrollToCaret()
    Update-LogScrollBar
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-LogScrollBar {
    if ($null -eq $LogBox -or -not $LogBox.IsHandleCreated) {
        return
    }
    $LastIndex = [Math]::Max(0, $LogBox.TextLength - 1)
    $LastPosition = $LogBox.GetPositionFromCharIndex($LastIndex)
    $NeedsVerticalScrollBar = ($LastPosition.Y + $LogBox.Font.Height + 2) -gt $LogBox.ClientSize.Height
    [void][ProjektKanbanAgentManager.NativeMethods]::ShowScrollBar(
        $LogBox.Handle,
        1,
        $NeedsVerticalScrollBar
    )
}

function Write-Status {
    param([string]$Message)
    $StatusBox.ForeColor = [System.Drawing.Color]::DarkGreen
    $StatusBox.Text = $Message
    $StatusBox.SelectionStart = $StatusBox.TextLength
    $StatusBox.ScrollToCaret()
    Write-Log "INFO: $Message"
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-ErrorStatus {
    param([string]$Message)
    $StatusBox.ForeColor = [System.Drawing.Color]::DarkRed
    $StatusBox.Text = $Message
    $StatusBox.SelectionStart = $StatusBox.TextLength
    $StatusBox.ScrollToCaret()
    Write-Log "ERROR: $Message"
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ReleaseStatus {
    param([string]$Message)
    $ReleaseStatus.ForeColor = [System.Drawing.Color]::DimGray
    $ReleaseStatus.Text = $Message
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ReleaseErrorStatus {
    param([string]$Message)
    Set-ReleaseStatus $Message
    $ReleaseStatus.ForeColor = [System.Drawing.Color]::DarkRed
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-JsonPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }
    return $Property.Value
}

function Get-ReleaseVersion {
    param([object]$Release)
    $Tag = [string](Get-JsonPropertyValue $Release 'tag_name')
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return ''
    }
    return ($Tag.Trim() -replace '^v', '')
}

function Get-ReleaseBridgeAsset {
    param([object]$Release)
    $Version = Get-ReleaseVersion $Release
    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }
    $ExpectedName = "projekt-kanban-agent-manager-$Version-windows-wsl.zip"
    foreach ($Asset in @(Get-JsonPropertyValue $Release 'assets')) {
        if ([string](Get-JsonPropertyValue $Asset 'name') -eq $ExpectedName) {
            return $Asset
        }
    }
    return $null
}

function Install-BridgeFromRelease {
    param(
        [Parameter(Mandatory = $true)][object]$Release,
        [Parameter(Mandatory = $true)][object]$Asset
    )
    $Version = Get-ReleaseVersion $Release
    $DownloadUrl = [string](Get-JsonPropertyValue $Asset 'browser_download_url')
    if ([string]::IsNullOrWhiteSpace($Version) -or [string]::IsNullOrWhiteSpace($DownloadUrl)) {
        throw 'Das ausgewählte GitHub-Release enthält kein gültiges Bridge-Archiv.'
    }
    if (Get-Process -Name 'projekt-kanban-agent-wsl' -ErrorAction SilentlyContinue) {
        throw 'Firefox verwendet die Bridge noch. Firefox vollständig schließen und das Update erneut starten.'
    }

    $TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("projekt-kanban-agent-manager-update-" + [guid]::NewGuid().ToString('N'))
    $ArchivePath = Join-Path $TemporaryDirectory "projekt-kanban-agent-manager-$Version-windows-wsl.zip"
    try {
        New-Item -ItemType Directory -Path $TemporaryDirectory -Force | Out-Null
        Write-Status "Bridge-Release $Version wird von GitHub heruntergeladen …"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath -Headers @{
                Accept = 'application/zip'
                'User-Agent' = 'Projekt-Kanban-Agent-Manager'
            } -UseBasicParsing -TimeoutSec 120
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $TemporaryDirectory -Force

        $DownloadedInstaller = @(Get-ChildItem -LiteralPath $TemporaryDirectory -Filter 'install.ps1' -File -Recurse |
                Where-Object { $_.FullName -match '\\native-host-windows-wsl\\install\.ps1$' } |
                Select-Object -First 1)
        if ($DownloadedInstaller.Count -eq 0) {
            throw 'Das Bridge-Release enthält kein gültiges Windows-WSL-Installationsskript.'
        }
        $DownloadedPackageDirectory = Split-Path -Parent (Split-Path -Parent $DownloadedInstaller[0].FullName)
        $DownloadedVersionFile = Join-Path $DownloadedPackageDirectory 'VERSION'
        if (-not (Test-Path -LiteralPath $DownloadedVersionFile -PathType Leaf)) {
            throw 'Das Bridge-Release enthält keine VERSION-Datei.'
        }
        $DownloadedVersion = ((Get-Content -LiteralPath $DownloadedVersionFile -TotalCount 1) -join '').Trim()
        if ($DownloadedVersion -ne $Version) {
            throw "Versionskonflikt im Bridge-Release: Tag $Version, Paket $DownloadedVersion."
        }

        $Distribution = Get-Distribution
        $Output = @(& $DownloadedInstaller[0].FullName -Distribution $Distribution 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw ($Output -join "`n")
        }
        $Saved = Save-AgentConfiguration
        Write-Status (($Output -join "`r`n") + "`r`nBridge-Release $Version installiert. Agent-Konfiguration gespeichert.")
        Update-ActionButtons $true $Saved.agent
    } finally {
        if (Test-Path -LiteralPath $TemporaryDirectory) {
            Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GitHubReleases {
    $Tls12 = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::SecurityProtocol = $Tls12
    Write-Log "INFO: GitHub-Releases angefragt: $GitHubReleasesApi"
    $Response = Invoke-RestMethod -Method Get -Uri $GitHubReleasesApi -Headers @{
            Accept = 'application/vnd.github+json'
            'User-Agent' = 'Projekt-Kanban-Agent-Manager'
        } -UseBasicParsing -TimeoutSec 15

    if ($null -eq $Response) {
        Write-Log 'INFO: GitHub API hat eine leere Release-Liste zurückgegeben.'
        return @()
    }

    $ApiMessage = [string](Get-JsonPropertyValue $Response 'message')
    $ApiDocumentation = [string](Get-JsonPropertyValue $Response 'documentation_url')
    $ApiTag = Get-JsonPropertyValue $Response 'tag_name'
    if ($ApiMessage -and $null -eq $ApiTag) {
        $ApiDetails = if ($ApiDocumentation) { " Details: $ApiDocumentation" } else { '' }
        throw "GitHub API meldet: $ApiMessage.$ApiDetails"
    }

    return @($Response)
}

function Refresh-Releases {
    try {
        Set-ReleaseStatus 'GitHub-Releases werden geladen …'
        $Releases = @(Get-GitHubReleases)

        $ReleaseGrid.Rows.Clear()
        $Skipped = 0
        $ReleaseRows = @()
        foreach ($Release in $Releases) {
            $Tag = [string](Get-JsonPropertyValue $Release 'tag_name')
            if ([string]::IsNullOrWhiteSpace($Tag)) {
                $Skipped++
                continue
            }
            $Name = [string](Get-JsonPropertyValue $Release 'name')
            if (-not $Name) { $Name = $Tag }
            $PublishedValue = [string](Get-JsonPropertyValue $Release 'published_at')
            $PublishedAt = [datetime]::MinValue
            $Published = $PublishedValue
            if ($PublishedValue) {
                try {
                    $PublishedDate = ([datetime]$PublishedValue).ToLocalTime()
                    $PublishedAt = $PublishedDate
                    $Published = $PublishedDate.ToString('yyyy-MM-dd HH:mm')
                } catch {}
            }
            $Draft = [bool](Get-JsonPropertyValue $Release 'draft')
            $Prerelease = [bool](Get-JsonPropertyValue $Release 'prerelease')
            $State = if ($Draft) { 'Entwurf' } elseif ($Prerelease) { 'Vorabversion' } else { 'Release' }
            $Assets = @(Get-JsonPropertyValue $Release 'assets').Count
            $ReleaseRows += [pscustomobject]@{
                Release = $Release
                Tag = $Tag
                Name = $Name
                Published = $Published
                PublishedAt = $PublishedAt
                State = $State
                Assets = [string]$Assets
            }
        }
        foreach ($ReleaseRow in @($ReleaseRows | Sort-Object -Property @(
            @{ Expression = 'PublishedAt'; Descending = $true },
            @{ Expression = 'Tag'; Descending = $true }
        )) ) {
            $RowIndex = $ReleaseGrid.Rows.Add(
                $ReleaseRow.Tag,
                $ReleaseRow.Name,
                $ReleaseRow.Published,
                $ReleaseRow.State,
                $ReleaseRow.Assets
            )
            $ReleaseGrid.Rows[$RowIndex].Tag = $ReleaseRow.Release
        }
        if ($ReleaseGrid.Rows.Count -eq 0) {
            if ($Skipped -gt 0) {
                Set-ReleaseStatus "Keine gültigen Releases gefunden ($Skipped Eintrag ohne tag_name). Quelle: $GitHubRepository/releases"
            } else {
                Set-ReleaseStatus "Keine Releases gefunden. Im Manager-Repository ist noch kein Release veröffentlicht. Quelle: $GitHubRepository/releases"
            }
        } else {
            $ReleaseGrid.Rows[0].Selected = $true
            $SkippedText = if ($Skipped -gt 0) { " $Skipped Eintrag(e) übersprungen." } else { '' }
            Set-ReleaseStatus "$($ReleaseGrid.Rows.Count) Release(s) geladen.$SkippedText Nach Veröffentlichungsdatum absteigend sortiert. Für das neueste Release „Update Bridge“ klicken."
        }
        Write-Log "INFO: GitHub-Releases geladen: $($ReleaseGrid.Rows.Count); übersprungen: $Skipped"
    } catch {
        $ReleaseGrid.Rows.Clear()
        Set-ReleaseErrorStatus "GitHub-Releases konnten nicht geladen werden: $($_.Exception.Message)"
        Write-Log "ERROR: GitHub-Releases konnten nicht geladen werden: $($_.Exception.Message) Quelle: $GitHubReleasesApi"
    }
}

function Update-BridgeFromLatestRelease {
    Set-ReleaseStatus 'GitHub-Release für die Bridge wird gesucht …'
    $Releases = @(Get-GitHubReleases)
    foreach ($Release in $Releases) {
        $LatestAsset = Get-ReleaseBridgeAsset $Release
        if ($null -ne $LatestAsset) {
            $Version = Get-ReleaseVersion $Release
            Write-Log "INFO: Passendes Windows-WSL-Bridge-Archiv gefunden: Release $Version"
            Install-BridgeFromRelease $Release $LatestAsset
            Refresh-Status
            return
        }
    }
    if ($Releases.Count -eq 0) {
        throw "GitHub ist erreichbar, aber es gibt noch kein veröffentlichtes Manager-Release. Quelle: $GitHubRepository/releases"
    }
    throw "GitHub-Releases sind vorhanden, aber keines enthält das erwartete Windows-WSL-Bridge-Archiv (projekt-kanban-agent-manager-<version>-windows-wsl.zip). Quelle: $GitHubRepository/releases"
}

function Get-Distribution {
    $Value = [string]$DistributionBox.Text
    $Value = $Value.Trim()
    if (-not $Value) {
        throw 'Please select a WSL distribution.'
    }
    return $Value
}

function Get-WslHostPath {
    param([string]$Distribution)
    if (-not (Test-Path -LiteralPath $InstalledHost -PathType Leaf)) {
        throw 'The bridge is not installed yet. Open Releases and click "Update Bridge" first.'
    }
    $Output = @(& $WslCommand.Path --distribution $Distribution --exec wslpath -a -u $InstalledHost)
    if ($LASTEXITCODE -ne 0 -or $Output.Count -eq 0) {
        throw 'Der installierte Host-Pfad konnte nicht nach WSL übersetzt werden.'
    }
    return ([string]$Output[-1]).Trim()
}

function Invoke-ManagerHostForDistribution {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $HostPath = Get-WslHostPath $Distribution
    $Output = @(& $WslCommand.Path --distribution $Distribution --exec python3 $HostPath @Arguments 2>&1)
    $Text = ($Output -join "`n").Trim()
    if (-not $Text) {
        throw 'Der Native Host hat nicht geantwortet.'
    }
    try {
        $Response = $Text | ConvertFrom-Json
    } catch {
        throw "Ungültige Antwort des Native Host: $Text"
    }
    if ($LASTEXITCODE -ne 0 -or -not $Response.ok) {
        $Message = if ($Response.error.message) { [string]$Response.error.message } else { $Text }
        throw $Message
    }
    return $Response.data
}

function Invoke-ManagerHost {
    param([string[]]$Arguments)
    return Invoke-ManagerHostForDistribution (Get-Distribution) $Arguments
}

function Get-SandboxValue {
    switch ([string]$SandboxBox.SelectedItem) {
        'Read-only (Dry Run)' { return 'read-only' }
        'Workspace write' { return 'workspace-write' }
        'Unrestricted access' { return 'danger-full-access' }
        default { throw 'Please select an access mode.' }
    }
}

function Save-AgentConfigurationValues {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$AgentId,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    if (-not $AgentId -or -not $Label -or -not $Executable) {
        throw 'Agent ID, display name, and executable are required.'
    }
    if ($Sandbox -ne 'danger-full-access' -and -not $Workspace) {
        throw 'A workspace is required for this access mode.'
    }
    if ($Sandbox -eq 'danger-full-access') {
        $Workspace = '__HOME__'
    }
    return Invoke-ManagerHostForDistribution $Distribution @(
        '--manager-configure-local', $AgentId, $Label, $Executable, $Sandbox, $Workspace
    )
}

function Save-AgentConfiguration {
    $AgentInput = Get-AgentConfigurationInput
    return Save-AgentConfigurationValues `
        -Distribution $AgentInput.Distribution `
        -AgentId $AgentInput.AgentId `
        -Label $AgentInput.Label `
        -Executable $AgentInput.Executable `
        -Sandbox $AgentInput.Sandbox `
        -Workspace $AgentInput.Workspace
}

function Get-AgentConfigurationInput {
    $AgentId = $AgentIdBox.Text.Trim()
    $Label = $AgentLabelBox.Text.Trim()
    $Executable = $ExecutableBox.Text.Trim()
    $Sandbox = Get-SandboxValue
    $Workspace = $WorkspaceBox.Text.Trim()
    if (-not $AgentId -or -not $Label -or -not $Executable) {
        throw 'Agent ID, display name, and executable are required.'
    }
    if ($Sandbox -ne 'danger-full-access' -and -not $Workspace) {
        throw 'A workspace is required for this access mode.'
    }
    if ($Sandbox -eq 'danger-full-access') {
        $Workspace = '__HOME__'
    }
    return [pscustomobject]@{
        Distribution = Get-Distribution
        AgentId = $AgentId
        Label = $Label
        Executable = $Executable
        Sandbox = $Sandbox
        Workspace = $Workspace
    }
}

$SaveButton = $null
$TestButton = $null
$EnableButton = $null
$DisableButton = $null
$UninstallButton = $null
$script:ConnectionTestJob = $null
$ConnectionTestTimer = New-Object System.Windows.Forms.Timer
$ConnectionTestTimer.Interval = 250

function Update-ActionButtons {
    param([bool]$BridgeAvailable, [object]$Agent)
    $hasAgent = $null -ne $Agent
    $agentEnabled = $hasAgent -and [bool]$Agent.enabled
    if ($null -ne $SaveButton) { $SaveButton.Enabled = $BridgeAvailable }
    if ($null -ne $TestButton) { $TestButton.Enabled = $BridgeAvailable -and $agentEnabled }
    if ($null -ne $EnableButton) { $EnableButton.Enabled = $BridgeAvailable -and $hasAgent -and -not $agentEnabled }
    if ($null -ne $DisableButton) { $DisableButton.Enabled = $BridgeAvailable -and $agentEnabled }
    if ($null -ne $UninstallButton) { $UninstallButton.Enabled = $BridgeAvailable }
}

function Refresh-Status {
    try {
        $Data = Invoke-ManagerHost @('--manager-status')
        $Agent = @($Data.agents | Where-Object { $_.id -eq $AgentIdBox.Text.Trim() }) | Select-Object -First 1
        if ($null -eq $Agent) {
            Update-ActionButtons $true $null
            Write-Status "Bridge $($Data.version) is installed. The agent is not configured yet."
        } else {
            $AgentLabelBox.Text = [string]$Agent.label
            $ExecutableBox.Text = [string]$Agent.executable
            if ([string]$Agent.workspace) { $WorkspaceBox.Text = [string]$Agent.workspace }
            switch ([string]$Agent.sandbox) {
                'read-only' { $SandboxBox.SelectedItem = 'Read-only (Dry Run)' }
                'workspace-write' { $SandboxBox.SelectedItem = 'Workspace write' }
                'danger-full-access' { $SandboxBox.SelectedItem = 'Unrestricted access' }
            }
            $State = if ($Agent.enabled) { 'ENABLED' } else { 'DISABLED' }
            Update-ActionButtons $true $Agent
            Write-Status "Bridge $($Data.version) connected.`r`nAgent '$($Agent.label)': $State"
        }
    } catch {
        Update-ActionButtons $false $null
        Write-ErrorStatus $_.Exception.Message
    }
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Projekt Kanban Agent Manager $ManagerVersion"
$Form.StartPosition = 'CenterScreen'
$Form.ClientSize = New-Object System.Drawing.Size(710, 600)
$Form.MinimumSize = New-Object System.Drawing.Size(726, 639)
$Form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$Tabs = New-Object System.Windows.Forms.TabControl
$Tabs.Left = 8
$Tabs.Top = 6
$Tabs.Width = 694
$Tabs.Height = 588
$ManagerPage = New-Object System.Windows.Forms.TabPage
$ManagerPage.Text = 'Manager'
$SettingsPage = New-Object System.Windows.Forms.TabPage
$SettingsPage.Text = 'Settings'
$LogPage = New-Object System.Windows.Forms.TabPage
$LogPage.Text = 'Log'
$HelpPage = New-Object System.Windows.Forms.TabPage
$HelpPage.Text = 'Help'
[void]$Tabs.TabPages.Add($ManagerPage)
[void]$Tabs.TabPages.Add($SettingsPage)
[void]$Tabs.TabPages.Add($LogPage)
[void]$Tabs.TabPages.Add($HelpPage)
$Form.Controls.Add($Tabs)
$AnchorTopLeftRight = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorTopRight = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorLeftRight = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorBottomLeftRight = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorAll = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$Tabs.Anchor = $AnchorAll

$Title = New-Object System.Windows.Forms.Label
$Title.Text = 'Projekt Kanban Agent Manager'
$Title.Left = 16
$Title.Top = 18
$Title.Width = 500
$Title.Height = 34
$Title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$Title.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$ManagerPage.Controls.Add($Title)

$VersionLabel = New-Object System.Windows.Forms.Label
$VersionLabel.Text = "Version $ManagerVersion"
$VersionLabel.Left = 535
$VersionLabel.Top = 27
$VersionLabel.Width = 135
$VersionLabel.Height = 24
$VersionLabel.TextAlign = 'MiddleRight'
$VersionLabel.ForeColor = [System.Drawing.Color]::DimGray
$VersionLabel.Anchor = $AnchorTopRight
$ManagerPage.Controls.Add($VersionLabel)

$Description = New-Object System.Windows.Forms.Label
$Description.Text = 'Installs the Windows-WSL bridge and manages a local Codex agent.'
$Description.Left = 18
$Description.Top = 55
$Description.Width = 650
$Description.Height = 25
$Description.ForeColor = [System.Drawing.Color]::DimGray
$Description.Anchor = $AnchorTopLeftRight
$ManagerPage.Controls.Add($Description)

$SettingsTitle = New-Object System.Windows.Forms.Label
$SettingsTitle.Text = 'Agent settings'
$SettingsTitle.Left = 16
$SettingsTitle.Top = 18
$SettingsTitle.Width = 650
$SettingsTitle.Height = 34
$SettingsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$SettingsTitle.Anchor = $AnchorTopLeftRight
$SettingsPage.Controls.Add($SettingsTitle)

Add-Label 'WSL distribution' 98 $SettingsPage | Out-Null
$DistributionBox = New-Object System.Windows.Forms.ComboBox
$DistributionBox.Left = 205
$DistributionBox.Top = 94
$DistributionBox.Width = 455
$DistributionBox.DropDownStyle = 'DropDown'
$DistributionBox.Anchor = $AnchorTopLeftRight
$SettingsPage.Controls.Add($DistributionBox)

$InitialDistribution = Normalize-DistributionName $InitialDistribution
$Distributions = @(Get-WslDistributions)
foreach ($Distribution in $Distributions) { [void]$DistributionBox.Items.Add($Distribution) }
if ($InitialDistribution -and $DistributionBox.Items.Contains($InitialDistribution)) {
    $DistributionBox.SelectedItem = $InitialDistribution
} elseif ($DistributionBox.Items.Count -gt 0) {
    $DistributionBox.SelectedIndex = 0
} elseif ($InitialDistribution) {
    [void]$DistributionBox.Items.Add($InitialDistribution)
    $DistributionBox.SelectedItem = $InitialDistribution
}

Add-Label 'Agent ID' 140 $SettingsPage | Out-Null
$AgentIdBox = New-TextBox 140 'local-codex' $SettingsPage
$AgentIdBox.Anchor = $AnchorLeftRight
Add-Label 'Display name' 182 $SettingsPage | Out-Null
$AgentLabelBox = New-TextBox 182 'Codex in WSL' $SettingsPage
$AgentLabelBox.Anchor = $AnchorLeftRight
Add-Label 'Agent executable (WSL)' 224 $SettingsPage | Out-Null
$ExecutableBox = New-TextBox 224 "/mnt/c/Users/$env:USERNAME/.codex/bin/wsl/codex" $SettingsPage
$ExecutableBox.Anchor = $AnchorLeftRight
Add-Label 'Access mode' 266 $SettingsPage | Out-Null
$SandboxBox = New-Object System.Windows.Forms.ComboBox
$SandboxBox.Left = 205
$SandboxBox.Top = 262
$SandboxBox.Width = 455
$SandboxBox.DropDownStyle = 'DropDownList'
$SandboxBox.Anchor = $AnchorLeftRight
[void]$SandboxBox.Items.Add('Read-only (Dry Run)')
[void]$SandboxBox.Items.Add('Workspace write')
[void]$SandboxBox.Items.Add('Unrestricted access')
$SandboxBox.SelectedIndex = 1
$SettingsPage.Controls.Add($SandboxBox)

$WorkspaceLabel = Add-Label 'Workspace (WSL)' 308 $SettingsPage
$WorkspaceBox = New-TextBox 308 "/mnt/c/Users/$env:USERNAME/projekt-kanban" $SettingsPage
$WorkspaceBox.Anchor = $AnchorLeftRight
$WorkspaceHint = New-Object System.Windows.Forms.Label
$WorkspaceHint.Left = 205
$WorkspaceHint.Top = 337
$WorkspaceHint.Width = 455
$WorkspaceHint.Height = 36
$WorkspaceHint.Text = 'Can contain multiple projects. Unrestricted access uses the agent user home automatically.'
$WorkspaceHint.ForeColor = [System.Drawing.Color]::DimGray
$WorkspaceHint.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$WorkspaceHint.Anchor = $AnchorTopLeftRight
$SettingsPage.Controls.Add($WorkspaceHint)

$StatusBox = New-Object System.Windows.Forms.TextBox
$StatusBox.Left = 16
$StatusBox.Top = 90
$StatusBox.Width = 662
$StatusBox.Height = 300
$StatusBox.Multiline = $true
$StatusBox.ReadOnly = $true
$StatusBox.ScrollBars = 'Both'
$StatusBox.WordWrap = $false
$StatusBox.Text = 'Ready.'
$StatusBox.Anchor = $AnchorTopLeftRight
$ManagerPage.Controls.Add($StatusBox)

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true
$LogBox.ReadOnly = $true
$LogBox.ScrollBars = 'Vertical'
$LogBox.WordWrap = $true
$LogBox.Dock = 'Fill'
$LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$LogPage.Controls.Add($LogBox)

$ReleasesPage = New-Object System.Windows.Forms.TabPage
$ReleasesPage.Text = 'Releases'
[void]$Tabs.TabPages.Add($ReleasesPage)

$ReleaseGrid = New-Object System.Windows.Forms.DataGridView
$ReleaseGrid.Dock = 'Fill'
$ReleaseGrid.ReadOnly = $true
$ReleaseGrid.AllowUserToAddRows = $false
$ReleaseGrid.AllowUserToDeleteRows = $false
$ReleaseGrid.AllowUserToResizeRows = $false
$ReleaseGrid.MultiSelect = $false
$ReleaseGrid.RowHeadersVisible = $false
$ReleaseGrid.SelectionMode = 'FullRowSelect'
$ReleaseGrid.ClipboardCopyMode = 'EnableAlwaysIncludeHeaderText'
$ReleaseGrid.AutoSizeColumnsMode = 'None'
$ReleaseGrid.AutoSizeRowsMode = 'AllCells'
$ReleaseGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
$ReleaseGrid.BackgroundColor = [System.Drawing.SystemColors]::Window
$ReleaseGrid.BorderStyle = 'None'
$ReleaseGrid.GridColor = [System.Drawing.SystemColors]::ControlLight
$ReleaseGrid.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$ReleaseGrid.DefaultCellStyle.WrapMode = 'True'
[void]$ReleaseGrid.Columns.Add('version', 'Version')
[void]$ReleaseGrid.Columns.Add('name', 'Name')
[void]$ReleaseGrid.Columns.Add('published', 'Veröffentlicht')
[void]$ReleaseGrid.Columns.Add('state', 'Status')
[void]$ReleaseGrid.Columns.Add('assets', 'Dateien')
$ReleaseGrid.Columns['version'].AutoSizeMode = 'AllCells'
$ReleaseGrid.Columns['published'].AutoSizeMode = 'AllCells'
$ReleaseGrid.Columns['state'].AutoSizeMode = 'AllCells'
$ReleaseGrid.Columns['assets'].AutoSizeMode = 'AllCells'
$ReleaseGrid.Columns['name'].AutoSizeMode = 'Fill'
$ReleasesPage.Controls.Add($ReleaseGrid)

$ReleaseActionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ReleaseActionPanel.Dock = 'Bottom'
$ReleaseActionPanel.Height = 90
$ReleaseActionPanel.FlowDirection = 'TopDown'
$ReleaseActionPanel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
$ReleaseActionPanel.WrapContents = $false
$ReleasesPage.Controls.Add($ReleaseActionPanel)

$ReleaseInfoPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ReleaseInfoPanel.Width = 678
$ReleaseInfoPanel.Height = 36
$ReleaseInfoPanel.FlowDirection = 'LeftToRight'
$ReleaseInfoPanel.WrapContents = $false
$ReleaseInfoPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$ReleaseInfoPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$ReleaseActionPanel.Controls.Add($ReleaseInfoPanel)

$ReleaseButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ReleaseButtonPanel.Width = 678
$ReleaseButtonPanel.Height = 36
$ReleaseButtonPanel.FlowDirection = 'LeftToRight'
$ReleaseButtonPanel.WrapContents = $false
$ReleaseButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$ReleaseButtonPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$ReleaseActionPanel.Controls.Add($ReleaseButtonPanel)

$ReleaseStatus = New-Object System.Windows.Forms.TextBox
$ReleaseStatus.AutoSize = $false
$ReleaseStatus.Width = 380
$ReleaseStatus.Height = 32
$ReleaseStatus.Multiline = $true
$ReleaseStatus.ReadOnly = $true
$ReleaseStatus.BorderStyle = 'None'
$ReleaseStatus.BackColor = [System.Drawing.SystemColors]::Control
$ReleaseStatus.WordWrap = $true
$ReleaseStatus.ScrollBars = 'None'
$ReleaseStatus.ShortcutsEnabled = $true
$ReleaseStatus.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$ReleaseStatus.Text = 'Noch keine Releases geladen.'

$RefreshReleasesButton = New-Object System.Windows.Forms.Button
$RefreshReleasesButton.Text = 'Releases aktualisieren'
$RefreshReleasesButton.Width = 155
$RefreshReleasesButton.Height = 32
$RefreshReleasesButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$ReleaseInfoPanel.Controls.Add($RefreshReleasesButton)
$ReleaseInfoPanel.Controls.Add($ReleaseStatus)

$UpdateBridgeButton = New-Object System.Windows.Forms.Button
$UpdateBridgeButton.Text = 'Update Bridge'
$UpdateBridgeButton.Width = 170
$UpdateBridgeButton.Height = 32
$UpdateBridgeButton.Enabled = $true
$UpdateBridgeButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$ReleaseButtonPanel.Controls.Add($UpdateBridgeButton)
$ReleaseToolTip = New-Object System.Windows.Forms.ToolTip
$ReleaseToolTip.SetToolTip($UpdateBridgeButton, 'Lädt das neueste Windows-WSL-Release-Archiv von GitHub und installiert die Bridge daraus.')

$ReleaseActionPanel.Add_Resize({
    $RowWidth = [Math]::Max(0, $ReleaseActionPanel.ClientSize.Width)
    $ReleaseInfoPanel.Width = $RowWidth
    $ReleaseButtonPanel.Width = $RowWidth
})

$HelpGrid = New-Object System.Windows.Forms.DataGridView
$HelpGrid.Dock = 'Fill'
$HelpGrid.ReadOnly = $true
$HelpGrid.AllowUserToAddRows = $false
$HelpGrid.AllowUserToDeleteRows = $false
$HelpGrid.AllowUserToResizeRows = $false
$HelpGrid.MultiSelect = $false
$HelpGrid.RowHeadersVisible = $false
$HelpGrid.SelectionMode = 'FullRowSelect'
$HelpGrid.ClipboardCopyMode = 'EnableAlwaysIncludeHeaderText'
$HelpGrid.AutoSizeColumnsMode = 'Fill'
$HelpGrid.AutoSizeRowsMode = 'AllCells'
$HelpGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
$HelpGrid.BackgroundColor = [System.Drawing.SystemColors]::Window
$HelpGrid.BorderStyle = 'None'
$HelpGrid.GridColor = [System.Drawing.SystemColors]::ControlLight
$HelpGrid.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$HelpGrid.DefaultCellStyle.WrapMode = 'True'
$HelpGrid.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Highlight
$HelpGrid.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::HighlightText
[void]$HelpGrid.Columns.Add('element', 'Button / Eingabe / Tab')
[void]$HelpGrid.Columns.Add('purpose', 'Was es tut / wofür es gebraucht wird')
$HelpGrid.Columns['element'].FillWeight = 34
$HelpGrid.Columns['purpose'].FillWeight = 66

$HelpRows = @(
    @('Manager (Tab)', 'Zeigt den aktuellen Status und enthält die Aktionen für Aktivierung, Deaktivierung und Verbindungstest.'),
    @('Settings (Tab)', 'Hier werden WSL-Distribution, Agent, Zugriffsmodus und Arbeitsbereich eingestellt.'),
    @('Log (Tab)', 'Zeigt Zeitstempel sowie Informations- und Fehlermeldungen des Managers.'),
    @('Help (Tab)', 'Diese Übersicht der Tabs, Eingaben, Zugriffsmodi und Buttons.'),
    @('WSL distribution', 'Die WSL-Distribution, in der der Native Host und Codex ausgeführt werden.'),
    @('Agent ID', 'Eindeutige interne Kennung des Agenten, zum Beispiel local-codex.'),
    @('Display name', 'Lesbarer Name des Agenten, der in Statusmeldungen angezeigt wird.'),
    @('Agent executable (WSL)', 'Absoluter WSL-Pfad zum Codex-Programm, zum Beispiel /mnt/c/Users/Christian/.codex/bin/wsl/codex.'),
    @('Access mode', 'Legt fest, welche Änderungen der Agent durchführen darf.'),
    @('Workspace (WSL)', 'Arbeitsverzeichnis des Agenten. Bei eingeschränktem Zugriff darf er nur dort arbeiten.'),
    @('Read-only (Dry Run)', 'Der Agent darf analysieren und einen Plan erstellen, aber keine Dateien ändern.'),
    @('Workspace write', 'Der Agent darf innerhalb des eingestellten Arbeitsbereichs Dateien lesen und ändern.'),
    @('Unrestricted access', 'Der Agent darf auf das gesamte Benutzerkonto zugreifen. Nur verwenden, wenn dieses zusätzliche Risiko ausdrücklich akzeptiert wird.'),
    @('Save agent configuration', 'Speichert die Werte aus Settings in der Konfiguration des Native Host in WSL.'),
    @('Test Codex connection', 'Sendet eine kurze Testnachricht im Read-only-Modus an Codex und zeigt die Agent-Antwort in einem Windows-Dialog.'),
    @('Enable agent for tasks', 'Aktiviert den Agenten für neue, in Firefox bestätigte Aufgaben.'),
    @('Disable agent and cancel runs', 'Deaktiviert den Agenten und fordert die Beendigung aktiver Aufgaben an.'),
    @('Uninstall Windows bridge (Releases-Tab)', 'Entfernt die Windows-Bridge. Einstellungen und Laufhistorie in WSL bleiben erhalten.'),
    @('Firefox / Aufgabe bestätigen', 'Der Agent läuft nicht dauerhaft. Erst nach der sichtbaren Bestätigung einer Aufgabe startet Firefox den Agenten.'),
    @('relay-config.txt', 'Enthält die technische Verbindung von Windows zur WSL-Distribution. Die eigentliche Agentenkonfiguration wird separat in WSL gespeichert.'),
    @('Releases (Tab)', 'Zeigt die auf GitHub veröffentlichten Versionen tabellarisch an.'),
    @('Releases aktualisieren', 'Lädt die aktuelle Release-Liste des GitHub-Repositories neu.'),
    @('Update Bridge', 'Installiert das neueste Windows-WSL-Release-Archiv direkt von GitHub.'),
    @("Manager-Version $ManagerVersion", 'Die Version der Windows-Manager-Oberfläche. Die Native-Host-Version wird beim Bridge-Test separat geprüft.'),
    @('Fenstergröße ändern', 'Der Tab-Rahmen, die Statusanzeige und die Eingabefelder passen ihre Größe automatisch an. Die Button-Leisten bleiben unten angedockt.'),
    @('Text kopieren', 'Text in Status-, Log- und Eingabefeldern markieren und mit Strg+C kopieren. In den Tabellen eine Zeile markieren und ebenfalls Strg+C verwenden.'),
    @('GitHub-Zugriff', 'Die Release-Tabelle lädt die GitHub-API. Wenn das Repository privat ist, kann die Release-Seite trotzdem über den Update-Button im Browser geöffnet werden.')
)
foreach ($HelpRow in $HelpRows) {
    [void]$HelpGrid.Rows.Add($HelpRow[0], $HelpRow[1])
}
$HelpPage.Controls.Add($HelpGrid)

$ButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ButtonPanel.Left = 10
$ButtonPanel.Top = 400
$ButtonPanel.Width = 674
$ButtonPanel.Height = 100
$ButtonPanel.FlowDirection = 'TopDown'
$ButtonPanel.WrapContents = $false
$ButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$ButtonPanel.AutoScroll = $false
$ButtonPanel.Anchor = $AnchorBottomLeftRight
$ManagerPage.Controls.Add($ButtonPanel)

$ManagerFirstButtonRow = New-Object System.Windows.Forms.FlowLayoutPanel
$ManagerFirstButtonRow.Width = 674
$ManagerFirstButtonRow.Height = 40
$ManagerFirstButtonRow.FlowDirection = 'LeftToRight'
$ManagerFirstButtonRow.WrapContents = $false
$ManagerFirstButtonRow.Padding = New-Object System.Windows.Forms.Padding(0)
$ManagerFirstButtonRow.Margin = New-Object System.Windows.Forms.Padding(0)
$ButtonPanel.Controls.Add($ManagerFirstButtonRow)

$ManagerSecondButtonRow = New-Object System.Windows.Forms.FlowLayoutPanel
$ManagerSecondButtonRow.Width = 674
$ManagerSecondButtonRow.Height = 40
$ManagerSecondButtonRow.FlowDirection = 'LeftToRight'
$ManagerSecondButtonRow.WrapContents = $false
$ManagerSecondButtonRow.Padding = New-Object System.Windows.Forms.Padding(0)
$ManagerSecondButtonRow.Margin = New-Object System.Windows.Forms.Padding(0)
$ButtonPanel.Controls.Add($ManagerSecondButtonRow)

$SettingsButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$SettingsButtonPanel.Left = 10
$SettingsButtonPanel.Top = 400
$SettingsButtonPanel.Width = 674
$SettingsButtonPanel.Height = 100
$SettingsButtonPanel.AutoSize = $false
$SettingsButtonPanel.WrapContents = $true
$SettingsButtonPanel.Anchor = $AnchorBottomLeftRight
$SettingsPage.Controls.Add($SettingsButtonPanel)

function Resize-PageLayout {
    $ButtonMargin = 10
    $ButtonPanel.Top = [Math]::Max(400, $ManagerPage.ClientSize.Height - $ButtonPanel.Height - $ButtonMargin)
    $ManagerRightMargin = 16
    $StatusBox.Width = [Math]::Max(120, $ManagerPage.ClientSize.Width - $StatusBox.Left - $ManagerRightMargin)
    $ButtonPanel.Width = [Math]::Max(120, $ManagerPage.ClientSize.Width - $ButtonPanel.Left - $ManagerRightMargin)
    $ManagerFirstButtonRow.Width = $ButtonPanel.ClientSize.Width
    $ManagerSecondButtonRow.Width = $ButtonPanel.ClientSize.Width
    $StatusBox.Height = [Math]::Max(120, $ButtonPanel.Top - $StatusBox.Top - $ButtonMargin)
    $SettingsButtonPanel.Top = [Math]::Max(400, $SettingsPage.ClientSize.Height - $SettingsButtonPanel.Height - $ButtonMargin)
    $SettingsRightMargin = 16
    $SettingsInputWidth = [Math]::Max(200, $SettingsPage.ClientSize.Width - $DistributionBox.Left - $SettingsRightMargin)
    foreach ($Control in @($DistributionBox, $AgentIdBox, $AgentLabelBox, $ExecutableBox, $SandboxBox, $WorkspaceBox, $WorkspaceHint)) {
        $Control.Width = $SettingsInputWidth
    }
    $SettingsButtonPanel.Width = [Math]::Max(120, $SettingsPage.ClientSize.Width - $SettingsButtonPanel.Left - $SettingsRightMargin)
    Update-LogScrollBar
}

function Add-ActionButton {
    param(
        [string]$Text,
        [int]$Width,
        [scriptblock]$Action,
        [System.Windows.Forms.Control]$Panel = $ButtonPanel
    )
    $Button = New-Object System.Windows.Forms.Button
    $Button.Text = $Text
    $Button.Width = $Width
    $Button.Height = 34
    $Button.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $Button.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)
    $Button.Add_Click($Action)
    $Panel.Controls.Add($Button)
    return $Button
}

$SaveButton = Add-ActionButton 'Save agent configuration' 210 {
    try {
        $Saved = Save-AgentConfiguration
        Write-Status 'Agent configuration saved.'
        Update-ActionButtons $true $Saved.agent
    } catch { Write-ErrorStatus $_.Exception.Message }
} -Panel $SettingsButtonPanel

$EnableButton = Add-ActionButton 'Enable agent for tasks' 180 {
    try {
        $Saved = Save-AgentConfiguration
        [void](Invoke-ManagerHost @('--manager-enable', $AgentIdBox.Text.Trim()))
        Write-Status 'Agent enabled. Firefox will start it automatically for confirmed tasks.'
        Update-ActionButtons $true ([pscustomobject]@{ enabled = $true })
    } catch { Write-ErrorStatus $_.Exception.Message }
} -Panel $ManagerFirstButtonRow

$DisableButton = Add-ActionButton 'Disable agent and cancel runs' 220 {
    try {
        $Data = Invoke-ManagerHost @('--manager-disable', $AgentIdBox.Text.Trim())
        $Stopped = @($Data.cancelledRuns).Count
        Write-Status "Agent disabled. Active agent processes cancelled: $Stopped."
        Update-ActionButtons $true ([pscustomobject]@{ enabled = $false })
    } catch { Write-ErrorStatus $_.Exception.Message }
} -Panel $ManagerFirstButtonRow

$ConnectionTestJobScript = {
    param(
        [string]$WslExecutable,
        [string]$Distribution,
        [string]$InstalledHost,
        [string]$AgentId,
        [string]$Label,
        [string]$Executable,
        [string]$Sandbox,
        [string]$Workspace
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $HostPathOutput = @(& $WslExecutable --distribution $Distribution --exec wslpath -a -u $InstalledHost)
    if ($LASTEXITCODE -ne 0 -or $HostPathOutput.Count -eq 0) {
        throw 'Der installierte Host-Pfad konnte nicht nach WSL übersetzt werden.'
    }
    $HostPath = ([string]$HostPathOutput[-1]).Trim()
    if (-not $HostPath.StartsWith('/')) {
        throw "WSL hat einen ungültigen Host-Pfad zurückgegeben: $HostPath"
    }

    function Invoke-JobHost {
        param([string[]]$Arguments)
        $Output = @(& $WslExecutable --distribution $Distribution --exec python3 $HostPath @Arguments 2>&1)
        $Text = ($Output -join "`n").Trim()
        if (-not $Text) {
            throw 'Der Native Host hat nicht geantwortet.'
        }
        try {
            $Response = $Text | ConvertFrom-Json
        } catch {
            throw "Ungültige Antwort des Native Host: $Text"
        }
        if ($Response.ok -ne $true) {
            $ErrorProperty = $Response.PSObject.Properties['error']
            if ($null -ne $ErrorProperty -and $null -ne $ErrorProperty.Value) {
                $ErrorObject = $ErrorProperty.Value
                $MessageProperty = $ErrorObject.PSObject.Properties['message']
                if ($null -ne $MessageProperty -and $MessageProperty.Value) {
                    throw ([string]$MessageProperty.Value)
                }
            }
            throw $Text
        }
        return $Response.data
    }

    if ($Sandbox -eq 'danger-full-access') {
        $Workspace = '__HOME__'
    }
    $Saved = Invoke-JobHost @(
        '--manager-configure-local', $AgentId, $Label, $Executable, $Sandbox, $Workspace
    )
    $Data = Invoke-JobHost @('--manager-test', $AgentId)
    [pscustomobject]@{
        Succeeded = $true
        Saved = $Saved
        Data = $Data
    }
}

$ConnectionTestTimer.Add_Tick({
    if ($null -eq $script:ConnectionTestJob) {
        $ConnectionTestTimer.Stop()
        return
    }
    $State = [string]$script:ConnectionTestJob.State
    if ($State -in @('NotStarted', 'Running', 'Blocked')) {
        return
    }

    $Result = $null
    $ErrorMessage = $null
    try {
        if ($State -eq 'Completed') {
            $Results = @(Receive-Job -Job $script:ConnectionTestJob -ErrorAction Stop)
            if ($Results.Count -eq 0) {
                throw 'Der Verbindungstest hat kein Ergebnis zurückgegeben.'
            }
            $Result = $Results[-1]
        } else {
            $Reason = $script:ConnectionTestJob.ChildJobs[0].JobStateInfo.Reason
            $ErrorMessage = if ($null -ne $Reason) { [string]$Reason.Message } else { "Der Hintergrundtest endete mit Status: $State" }
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
    } finally {
        $ConnectionTestTimer.Stop()
        Remove-Job -Job $script:ConnectionTestJob -Force -ErrorAction SilentlyContinue
        $script:ConnectionTestJob = $null
    }

    if ($ErrorMessage) {
        Write-ErrorStatus $ErrorMessage
        Update-ActionButtons $true ([pscustomobject]@{ enabled = $true })
        return
    }
    if ($null -eq $Result -or -not $Result.Succeeded) {
        $Message = if ($null -ne $Result -and $Result.ErrorMessage) { [string]$Result.ErrorMessage } else { 'Der Verbindungstest ist fehlgeschlagen.' }
        Write-ErrorStatus $Message
        Update-ActionButtons $true ([pscustomobject]@{ enabled = $true })
        return
    }
    $Data = $Result.Data
    $Message = "Prompt: $($Data.prompt)`r`n`r`nAgent-Antwort:`r`n$($Data.message)"
    Write-Status $Message
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Agent-Verbindungstest',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    Update-ActionButtons $true $Result.Saved.agent
})

$TestButton = Add-ActionButton 'Test Codex connection' 180 {
    if ($null -ne $script:ConnectionTestJob) {
        return
    }
    try {
        $AgentInput = Get-AgentConfigurationInput
        foreach ($Button in @($SaveButton, $EnableButton, $DisableButton, $TestButton, $UninstallButton)) {
            if ($null -ne $Button) {
                $Button.Enabled = $false
            }
        }
        Write-Status 'Verbindungstest läuft im Hintergrund. Die Antwort kann bis zu 90 Sekunden dauern …'
        $script:ConnectionTestJob = Start-Job -ScriptBlock $ConnectionTestJobScript -ArgumentList @(
            [string]$WslCommand.Path,
            [string]$AgentInput.Distribution,
            [string]$InstalledHost,
            [string]$AgentInput.AgentId,
            [string]$AgentInput.Label,
            [string]$AgentInput.Executable,
            [string]$AgentInput.Sandbox,
            [string]$AgentInput.Workspace
        )
        $ConnectionTestTimer.Start()
    } catch {
        $ConnectionTestTimer.Stop()
        if ($null -ne $script:ConnectionTestJob) {
            Stop-Job -Job $script:ConnectionTestJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:ConnectionTestJob -Force -ErrorAction SilentlyContinue
            $script:ConnectionTestJob = $null
        }
        Write-ErrorStatus $_.Exception.Message
        Update-ActionButtons $true ([pscustomobject]@{ enabled = $true })
    }
} -Panel $ManagerSecondButtonRow

$UninstallButton = Add-ActionButton 'Uninstall Windows bridge' 190 {
    $Choice = [System.Windows.Forms.MessageBox]::Show(
        'Uninstall the bridge? Agent settings and run history in WSL will be kept.',
        'Projekt Kanban Agent Manager',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($Choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $Output = @(& $UninstallScript 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ($Output -join "`n") }
        Write-Status ($Output -join "`r`n")
        Update-ActionButtons $false $null
    } catch { Write-ErrorStatus $_.Exception.Message }
} -Panel $ReleaseButtonPanel

$RefreshReleasesButton.Add_Click({ Refresh-Releases })
$UpdateBridgeButton.Add_Click({
    try {
        Write-Status 'Latest GitHub bridge release is being downloaded and installed …'
        Update-BridgeFromLatestRelease
    } catch {
        Write-ErrorStatus $_.Exception.Message
    }
})

$SandboxBox.Add_SelectedIndexChanged({
    $Restricted = ([string]$SandboxBox.SelectedItem) -ne 'Unrestricted access'
    $WorkspaceLabel.Enabled = $Restricted
    $WorkspaceBox.Enabled = $Restricted
})
$ManagerPage.Add_Resize({ Resize-PageLayout })
$SettingsPage.Add_Resize({ Resize-PageLayout })
$LogPage.Add_Resize({ Update-LogScrollBar })
$DistributionBox.Add_SelectedIndexChanged({ Refresh-Status })
$Form.Add_Shown({ Resize-PageLayout; Refresh-Status; Refresh-Releases })
$Form.Add_FormClosing({
    if ($null -ne $ConnectionTestTimer) {
        $ConnectionTestTimer.Stop()
    }
    if ($null -ne $script:ConnectionTestJob) {
        Stop-Job -Job $script:ConnectionTestJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ConnectionTestJob -Force -ErrorAction SilentlyContinue
        $script:ConnectionTestJob = $null
    }
})

[void]$Form.ShowDialog()
