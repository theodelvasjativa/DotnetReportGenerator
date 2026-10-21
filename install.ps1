<#
.SYNOPSIS
    Instala, actualiza o desinstala la herramienta generateCodeCoverageReport.

.DESCRIPTION
    Instalador idempotente para Windows, Linux y macOS con PowerShell 7.

    Comprueba PowerShell, el SDK de .NET y las herramientas globales necesarias,
    copia el script principal a una carpeta propia, registra el comando en el PATH
    y, opcionalmente, crea un alias corto.

.PARAMETER Uninstall
    Desinstala el comando, los shims, la carpeta de instalación y las entradas de
    PATH creadas por este instalador.

.PARAMETER UpdateTools
    Actualiza coverlet.console y dotnet-reportgenerator-globaltool si ya están
    instalados. Si no lo están, los instala.

.PARAMETER UninstallTools
    Junto con -Uninstall, desinstala también las herramientas globales sin
    preguntar. Por defecto no se desinstalan.

.PARAMETER Alias
    Nombre de un alias corto adicional (por ejemplo gcov) que se registrará
    junto al comando principal.

.EXAMPLE
    pwsh ./install.ps1

.EXAMPLE
    pwsh ./install.ps1 -UpdateTools -Alias gcov

.EXAMPLE
    pwsh ./install.ps1 -Uninstall

.NOTES
    Códigos de salida:
      0  Instalación o desinstalación correcta.
      1  Error de requisitos, permisos o ejecución.
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$UpdateTools,
    [switch]$UninstallTools,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]*$')]
    [string]$Alias
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:ToolName = 'generateCodeCoverageReport'
$script:MainScriptName = 'generateCodeCoverageReport.ps1'
$script:ManifestName = 'install-manifest.json'
$script:MarkerMain = 'generateCodeCoverageReport'
$script:MarkerTools = 'dotnet-tools-path'
$script:RequiredTools = @(
    [pscustomobject]@{ Id = 'coverlet.console'; Command = 'coverlet' }
    [pscustomobject]@{ Id = 'dotnet-reportgenerator-globaltool'; Command = 'reportgenerator' }
)

$script:Installed = New-Object System.Collections.Generic.List[string]
$script:Existing = New-Object System.Collections.Generic.List[string]
$script:Updated = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

$script:NeedsNewTerminal = $false
$script:PathEntriesAdded = New-Object System.Collections.Generic.List[string]
$script:RcFilesModified = New-Object System.Collections.Generic.List[string]
$script:ToolsPathAdded = $false
$script:AliasSpecified = $PSBoundParameters.ContainsKey('Alias')
$script:UninstallToolsSpecified = $PSBoundParameters.ContainsKey('UninstallTools')

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   generateCodeCoverageReport - instalador' -ForegroundColor Cyan
    Write-Host '   Cobertura .NET con coverlet + ReportGenerator' -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "    $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "    [AVISO] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "    [ERROR] $Message" -ForegroundColor Red
}

function Write-Detail {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "         $Message" -ForegroundColor DarkGray
}

function Add-Installed { param([string]$Message) $script:Installed.Add($Message) }
function Add-Existing { param([string]$Message) $script:Existing.Add($Message) }
function Add-Updated { param([string]$Message) $script:Updated.Add($Message) }
function Add-WarningMessage { param([string]$Message) $script:Warnings.Add($Message) }

# ---------------------------------------------------------------------------
# Platform helpers
# ---------------------------------------------------------------------------

function Test-WindowsPlatform {
    if ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
        return [bool]$IsWindows
    }

    return ($env:OS -eq 'Windows_NT')
}

function Test-MacPlatform {
    if ($null -ne (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue)) {
        return [bool]$IsMacOS
    }

    return $false
}

function Get-PlatformName {
    if (Test-WindowsPlatform) { return 'Windows' }
    if (Test-MacPlatform) { return 'macOS' }
    return 'Linux'
}

function Test-Interactive {
    if (-not [string]::IsNullOrEmpty($env:CI)) { return $false }
    if ($env:TF_BUILD -eq 'True') { return $false }

    try {
        return -not [Console]::IsInputRedirected
    }
    catch {
        return $false
    }
}

function Confirm-Action {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [bool]$Default = $false
    )

    $suffix = '[s/N]'
    if ($Default) { $suffix = '[S/n]' }

    if (-not (Test-Interactive)) {
        Write-Info "$Question $suffix -> se usa el valor por defecto."
        return $Default
    }

    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }

    $normalized = $answer.Trim().ToLowerInvariant()
    return ($normalized -in @('s', 'si', 'sí', 'y', 'yes'))
}

function Get-UserHome {
    if (-not [string]::IsNullOrWhiteSpace($HOME)) { return $HOME }

    return [Environment]::GetFolderPath('UserProfile')
}

function Get-InstallDirectory {
    if (Test-WindowsPlatform) {
        return (Join-Path $env:LOCALAPPDATA 'CodeCoverageReport')
    }

    return (Join-Path (Join-Path (Get-UserHome) '.local/share') 'code-coverage-report')
}

function Get-DotnetToolsDirectory {
    if (Test-WindowsPlatform) {
        return (Join-Path $env:USERPROFILE '.dotnet\tools')
    }

    return (Join-Path (Join-Path (Get-UserHome) '.dotnet') 'tools')
}

function Get-UnixBinDirectory {
    return (Join-Path (Get-UserHome) '.local/bin')
}

function Get-ManifestPath {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)

    return (Join-Path $InstallDirectory $script:ManifestName)
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Get-ObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }

    return $property.Value
}

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
    }
    catch {
        Write-Warn "El manifiesto de instalación está dañado y se ignorará: $Path"
        return $null
    }
}

function Write-Manifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Get-PathEntries {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    $separator = [string][System.IO.Path]::PathSeparator
    return @($Value -split [regex]::Escape($separator) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' })
}

function Normalize-PathEntry {
    param([string]$Entry)

    $value = $Entry.Trim()
    if ($value.Length -gt 1) {
        $value = $value.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    if (Test-WindowsPlatform) {
        $value = $value.Replace('/', '\')
    }

    return $value
}

function Test-PathContains {
    param(
        [string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $comparison = [System.StringComparison]::Ordinal
    if (Test-WindowsPlatform) {
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
    }

    $normalized = Normalize-PathEntry $Entry
    foreach ($item in (Get-PathEntries $PathValue)) {
        if ([string]::Equals((Normalize-PathEntry $item), $normalized, $comparison)) {
            return $true
        }
    }

    return $false
}

function Add-ToCurrentPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (Test-PathContains $env:Path $Directory) { return }

    $separator = [string][System.IO.Path]::PathSeparator
    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        $env:Path = $Directory
    }
    else {
        $env:Path = $env:Path.TrimEnd([System.IO.Path]::PathSeparator) + $separator + $Directory
    }
}

function Get-ShellProfilePath {
    $shell = [System.IO.Path]::GetFileName($env:SHELL)
    $homeDirectory = Get-UserHome

    switch ($shell) {
        'zsh' { return (Join-Path $homeDirectory '.zshrc') }
        'bash' { return (Join-Path $homeDirectory '.bashrc') }
        'fish' { return (Join-Path $homeDirectory '.config/fish/config.fish') }
        default { return (Join-Path $homeDirectory '.profile') }
    }
}

function Get-PortableExportLine {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $homeDirectory = Normalize-PathEntry (Get-UserHome)
    $normalized = Normalize-PathEntry $Directory

    if ($normalized.StartsWith($homeDirectory, [System.StringComparison]::Ordinal)) {
        $relative = $normalized.Substring($homeDirectory.Length).TrimStart('/', '\')
        $relative = $relative -replace '\\', '/'
        return 'export PATH="$HOME/' + $relative + ':$PATH"'
    }

    return 'export PATH="' + ($normalized -replace '\\', '/') + ':$PATH"'
}

function Add-UnixProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    $profilePath = Get-ShellProfilePath
    if ([System.IO.Path]::GetFileName($env:SHELL) -eq 'fish') {
        Write-Warn "Se detectó fish. Añade manualmente esta línea a $profilePath`:"
        Write-Detail ('set -gx PATH ' + (Normalize-PathEntry $Directory) + ' $PATH')
        return $null
    }

    $markerStart = "# >>> $Marker >>>"
    $markerEnd = "# <<< $Marker <<<"
    $exportLine = Get-PortableExportLine $Directory

    $profileDirectory = [System.IO.Path]::GetDirectoryName($profilePath)
    if ($profileDirectory -and -not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $content = Get-Content -LiteralPath $profilePath -Raw -Encoding utf8
    if ($null -eq $content) { $content = '' }

    if ($content.Contains($markerStart)) {
        Write-Info "La entrada de PATH ya existe en $profilePath."
        return $null
    }

    $block = $markerStart + [Environment]::NewLine +
        $exportLine + [Environment]::NewLine +
        $markerEnd + [Environment]::NewLine

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($profilePath, $content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $block, $encoding)

    return $profilePath
}

function Test-UnixProfileBlock {
    param([Parameter(Mandatory = $true)][string]$Marker)

    $profilePath = Get-ShellProfilePath
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $profilePath -Raw -Encoding utf8
    if ($null -eq $content) { return $false }

    return $content.Contains("# >>> $Marker >>>")
}

function Remove-UnixProfileBlock {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$Marker
    )

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $ProfilePath -Raw -Encoding utf8
    if ($null -eq $content) { return $false }

    $markerStart = [regex]::Escape("# >>> $Marker >>>")
    $markerEnd = [regex]::Escape("# <<< $Marker <<<")
    $pattern = '(?ms)^' + $markerStart + '\r?\n.*?^' + $markerEnd + '\r?\n?'
    $newContent = [regex]::Replace($content, $pattern, '')

    if ($newContent -eq $content) { return $false }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ProfilePath, $newContent, $encoding)
    return $true
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

function Show-PowerShellInstructions {
    $platform = Get-PlatformName

    Write-Err "Se requiere PowerShell 7 o superior. Versión actual: $($PSVersionTable.PSVersion)."
    Write-Host ''
    Write-Info 'Cómo instalar PowerShell 7:'
    Write-Host ''

    switch ($platform) {
        'Windows' {
            Write-Detail 'winget install --id Microsoft.PowerShell --source winget'
            Write-Detail 'O descarga el instalador MSI desde:'
            Write-Detail 'https://github.com/PowerShell/PowerShell/releases/latest'
        }
        'macOS' {
            Write-Detail 'brew install --cask powershell'
            Write-Detail 'O descarga el paquete desde:'
            Write-Detail 'https://github.com/PowerShell/PowerShell/releases/latest'
        }
        default {
            Write-Detail 'Consulta las instrucciones para tu distribución:'
            Write-Detail 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux'
            Write-Detail 'Ejemplo Debian/Ubuntu: sudo apt-get install powershell'
        }
    }

    Write-Host ''
    Write-Info 'Después, vuelve a ejecutar este instalador con pwsh:'
    Write-Detail 'pwsh ./install.ps1'
}

function Show-DotnetInstructions {
    $platform = Get-PlatformName

    Write-Err 'No se encontró el SDK de .NET o no hay ningún SDK instalado.'
    Write-Host ''
    Write-Info 'Este instalador NO instala el SDK automáticamente.'
    Write-Info 'Instala el SDK de .NET 8 o superior y vuelve a intentarlo.'
    Write-Host ''

    switch ($platform) {
        'Windows' {
            Write-Detail 'winget install Microsoft.DotNet.SDK.8'
            Write-Detail 'https://dotnet.microsoft.com/download'
            Write-Detail 'Script sin privilegios: irm https://dot.net/v1/dotnet-install.ps1 | iex'
        }
        'macOS' {
            Write-Detail 'brew install --cask dotnet-sdk'
            Write-Detail 'https://dotnet.microsoft.com/download'
            Write-Detail 'Script sin privilegios: curl -sSL https://dot.net/v1/dotnet-install.sh | bash'
        }
        default {
            Write-Detail 'https://learn.microsoft.com/dotnet/core/install/linux'
            Write-Detail 'Debian/Ubuntu: sudo apt-get install dotnet-sdk-8.0'
            Write-Detail 'Fedora: sudo dnf install dotnet-sdk-8.0'
            Write-Detail 'Arch: sudo pacman -S dotnet-sdk'
            Write-Detail 'Script sin privilegios: curl -sSL https://dot.net/v1/dotnet-install.sh | bash'
        }
    }

    Write-Host ''
    Write-Detail 'Comprueba la instalación con: dotnet --list-sdks'
}

function Test-Prerequisites {
    param([bool]$RequireDotnet = $true)

    $currentVersion = $PSVersionTable.PSVersion
    if ($currentVersion.Major -lt 7) {
        Show-PowerShellInstructions
        return $false
    }

    Write-Ok "PowerShell $currentVersion detectado."

    if (-not $RequireDotnet) { return $true }

    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnetCommand) {
        Show-DotnetInstructions
        return $false
    }

    $sdkOutput = & dotnet --list-sdks 2>&1
    $sdkExitCode = $LASTEXITCODE
    $sdks = @($sdkOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($sdkExitCode -ne 0 -or $sdks.Count -eq 0) {
        Show-DotnetInstructions
        return $false
    }

    Write-Ok "SDK de .NET detectado ($($sdks[0]))."
    return $true
}

# ---------------------------------------------------------------------------
# Global .NET tools
# ---------------------------------------------------------------------------

function Get-InstalledGlobalTools {
    $output = & dotnet tool list --global 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "No se pudo obtener la lista de herramientas globales (dotnet tool list --global)."
    }

    $result = @{}
    foreach ($line in @($output)) {
        $text = [string]$line
        if ($text -match '^\s*(coverlet\.console|dotnet-reportgenerator-globaltool)\s+(\S+)') {
            $result[$Matches[1].ToLowerInvariant()] = $Matches[2]
        }
    }

    return $result
}

function Install-GlobalTool {
    param([Parameter(Mandatory = $true)][string]$Id)

    Write-Info "Instalando $Id..."
    & dotnet tool install --global $Id
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo instalar la herramienta global '$Id'."
    }
}

function Update-GlobalTool {
    param([Parameter(Mandatory = $true)][string]$Id)

    Write-Info "Actualizando $Id..."
    & dotnet tool update --global $Id
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo actualizar la herramienta global '$Id'."
    }
}

function Install-OrUpdateTools {
    Write-Step 'Herramientas globales de .NET'

    $installedTools = Get-InstalledGlobalTools

    foreach ($tool in $script:RequiredTools) {
        $key = $tool.Id.ToLowerInvariant()
        $isInstalled = $installedTools.ContainsKey($key)

        if ($isInstalled) {
            if ($UpdateTools) {
                Update-GlobalTool -Id $tool.Id
                Add-Updated $tool.Id
                Write-Ok "$($tool.Id) actualizado."
            }
            else {
                Add-Existing $tool.Id
                Write-Ok "$($tool.Id) ya estaba instalado."
            }
        }
        else {
            Install-GlobalTool -Id $tool.Id
            Add-Installed $tool.Id
            Write-Ok "$($tool.Id) instalado."
        }
    }
}

function Ensure-DotnetToolsPath {
    Write-Step 'Ruta de las herramientas globales de .NET'

    $toolsDirectory = Get-DotnetToolsDirectory
    Write-Info "Carpeta de herramientas: $toolsDirectory"

    if (Test-PathContains $env:Path $toolsDirectory) {
        Write-Ok 'La carpeta ya está en el PATH.'
        return
    }

    if (Test-WindowsPlatform) {
        $added = Add-PersistentUserPath -Directory $toolsDirectory
        if ($added) {
            $script:ToolsPathAdded = $true
            $script:PathEntriesAdded.Add($toolsDirectory)
            $script:NeedsNewTerminal = $true
            Write-Ok 'Carpeta añadida al PATH del usuario.'
        }
        else {
            Write-Warn 'No se pudo añadir la carpeta al PATH del usuario.'
            Add-WarningMessage "Añade manualmente $toolsDirectory al PATH."
        }
    }
    else {
        $profilePath = Add-UnixProfileBlock -Directory $toolsDirectory -Marker $script:MarkerTools
        if ($null -ne $profilePath) {
            $script:ToolsPathAdded = $true
            $script:RcFilesModified.Add($profilePath)
            $script:NeedsNewTerminal = $true
            Write-Ok "Carpeta añadida al PATH en $profilePath."
        }
        else {
            Write-Ok 'La carpeta ya estaba configurada en el perfil del shell.'
        }
    }

    Add-ToCurrentPath $toolsDirectory
}

function Add-PersistentUserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $currentValue = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains $currentValue $Directory) {
        Add-ToCurrentPath $Directory
        return $false
    }

    $newValue = $Directory
    if (-not [string]::IsNullOrWhiteSpace($currentValue)) {
        $newValue = $currentValue.TrimEnd(';') + ';' + $Directory
    }

    [Environment]::SetEnvironmentVariable('Path', $newValue, 'User')
    Add-ToCurrentPath $Directory
    return $true
}

function Remove-PersistentUserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $currentValue = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($currentValue)) { return $false }

    $entries = Get-PathEntries $currentValue
    $filtered = @($entries | Where-Object {
        -not [string]::Equals((Normalize-PathEntry $_), (Normalize-PathEntry $Directory), [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($filtered.Count -eq $entries.Count) { return $false }

    $newValue = $filtered -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newValue, 'User')

    $currentProcessEntries = @(Get-PathEntries $env:Path | Where-Object {
        -not [string]::Equals((Normalize-PathEntry $_), (Normalize-PathEntry $Directory), [System.StringComparison]::OrdinalIgnoreCase)
    })
    $env:Path = $currentProcessEntries -join [System.IO.Path]::PathSeparator

    return $true
}

# ---------------------------------------------------------------------------
# Command registration
# ---------------------------------------------------------------------------

function New-WindowsShim {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ScriptName
    )

    $content = '@echo off' + "`r`n" +
        'pwsh -NoProfile -File "%~dp0' + $ScriptName + '" %*' + "`r`n" +
        'exit /b %ERRORLEVEL%' + "`r`n"

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $encoding)
}

function New-UnixWrapper {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetScript
    )

    $escapedTarget = $TargetScript.Replace("'", "''")
    $content = "#!/usr/bin/env pwsh`n" +
        "# Generado por install.ps1. No editar a mano.`n" +
        "& '$escapedTarget' @args`n" +
        "exit `$LASTEXITCODE`n"

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $encoding)

    & chmod +x $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo hacer ejecutable el wrapper: $Path"
    }
}

function Remove-CommandFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
        return $true
    }

    return $false
}

function Test-ExecutionPolicyBlocking {
    if (-not (Test-WindowsPlatform)) { return $false }

    $policy = Get-ExecutionPolicy
    return ($policy -in @('Restricted', 'AllSigned'))
}

function Register-MainCommand {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string]$MainScriptPath
    )

    Write-Step 'Registro del comando generateCodeCoverageReport'

    if (Test-WindowsPlatform) {
        $pathAdded = Add-PersistentUserPath -Directory $InstallDirectory
        if ($pathAdded) {
            $script:PathEntriesAdded.Add($InstallDirectory)
            $script:NeedsNewTerminal = $true
            Write-Ok 'Carpeta de instalación añadida al PATH del usuario.'
        }
        else {
            Write-Ok 'La carpeta de instalación ya estaba en el PATH del usuario.'
        }

        $shimPath = Join-Path $InstallDirectory ($script:ToolName + '.cmd')
        New-WindowsShim -Path $shimPath -ScriptName $script:MainScriptName
        Write-Ok "Shim de cmd creado: $shimPath"

        Unblock-File -LiteralPath $MainScriptPath -ErrorAction SilentlyContinue

        if (Test-ExecutionPolicyBlocking) {
            $policy = Get-ExecutionPolicy
            Write-Warn "La ExecutionPolicy actual ($policy) puede bloquear el script."
            Write-Info 'Se ha ejecutado Unblock-File sobre el script.'

            $changePolicy = Confirm-Action -Question '¿Establecer RemoteSigned para el usuario actual?' -Default $false
            if ($changePolicy) {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
                Write-Ok 'ExecutionPolicy RemoteSigned establecida para el usuario actual.'
            }
            else {
                Write-Info 'No se ha modificado la ExecutionPolicy. Si el script no arranca, ejecuta:'
                Write-Detail 'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned'
            }
        }
        else {
            Write-Ok 'La ExecutionPolicy no bloquea la ejecución.'
        }
    }
    else {
        $binDirectory = Get-UnixBinDirectory
        if (-not (Test-Path -LiteralPath $binDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
        }

        $wrapperPath = Join-Path $binDirectory $script:ToolName
        New-UnixWrapper -Path $wrapperPath -TargetScript $MainScriptPath
        Write-Ok "Wrapper creado: $wrapperPath"

        if (Test-PathContains $env:Path $binDirectory) {
            Write-Ok 'La carpeta ~/.local/bin ya está en el PATH.'
        }
        elseif (Test-UnixProfileBlock -Marker $script:MarkerMain) {
            Write-Ok 'La carpeta ~/.local/bin ya está configurada en el perfil del shell.'
        }
        else {
            Write-Warn 'La carpeta ~/.local/bin NO está en el PATH.'
            $exportLine = Get-PortableExportLine $binDirectory
            Write-Info 'Añade esta línea a tu .bashrc o .zshrc:'
            Write-Detail $exportLine

            $addToPath = Confirm-Action -Question '¿Añadirla automáticamente al perfil de tu shell?' -Default $true
            if ($addToPath) {
                $profilePath = Add-UnixProfileBlock -Directory $binDirectory -Marker $script:MarkerMain
                if ($null -ne $profilePath) {
                    $script:PathEntriesAdded.Add($binDirectory)
                    $script:RcFilesModified.Add($profilePath)
                    $script:NeedsNewTerminal = $true
                    Write-Ok "PATH actualizado en $profilePath."
                }
            }
            else {
                Add-WarningMessage "Añade $binDirectory al PATH para usar el comando desde cualquier terminal."
            }
        }

        Add-ToCurrentPath $binDirectory
    }
}

function Register-AliasCommand {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string]$MainScriptPath,
        [Parameter(Mandatory = $true)][string]$AliasName
    )

    Write-Step "Registro del alias '$AliasName'"

    $existingCommand = Get-Command $AliasName -ErrorAction SilentlyContinue
    if ($null -ne $existingCommand) {
        $isOurs = $false
        if (Test-WindowsPlatform) {
            $expectedShim = Join-Path $InstallDirectory ($AliasName + '.cmd')
            $isOurs = $existingCommand.Source -eq $expectedShim
        }
        else {
            $expectedWrapper = Join-Path (Get-UnixBinDirectory) $AliasName
            $isOurs = $existingCommand.Source -eq $expectedWrapper
        }

        if (-not $isOurs) {
            throw "El alias '$AliasName' ya existe y pertenece a otro comando ($($existingCommand.Source)). Elige otro nombre."
        }
    }

    if (Test-WindowsPlatform) {
        $aliasPath = Join-Path $InstallDirectory ($AliasName + '.cmd')
        New-WindowsShim -Path $aliasPath -ScriptName $script:MainScriptName
    }
    else {
        $aliasPath = Join-Path (Get-UnixBinDirectory) $AliasName
        New-UnixWrapper -Path $aliasPath -TargetScript $MainScriptPath
    }

    Write-Ok "Alias '$AliasName' registrado en $aliasPath."
    return $aliasPath
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Invoke-Install {
    Write-Step 'Copia del script principal'

    $sourceScript = Join-Path $PSScriptRoot $script:MainScriptName
    if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
        throw "No se encontró '$($script:MainScriptName)' junto a install.ps1. Descarga el repositorio completo."
    }

    $installDirectory = Get-InstallDirectory
    if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    }

    $manifestPath = Get-ManifestPath -InstallDirectory $installDirectory
    $previousManifest = Read-Manifest -Path $manifestPath
    $previousAlias = [string](Get-ObjectProperty -Object $previousManifest -Name 'alias' -Default '')

    $destinationScript = Join-Path $installDirectory $script:MainScriptName
    $scriptChanged = $true
    if (Test-Path -LiteralPath $destinationScript -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $sourceScript -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationScript -Algorithm SHA256).Hash
        $scriptChanged = ($sourceHash -ne $destinationHash)
    }

    Copy-Item -LiteralPath $sourceScript -Destination $destinationScript -Force

    if ($scriptChanged) {
        Add-Installed $script:MainScriptName
        Write-Ok "Script copiado en $destinationScript"
    }
    else {
        Add-Existing $script:MainScriptName
        Write-Ok "Script ya actualizado en $destinationScript"
    }

    # Remove an old alias if the user chose a different one on reinstall.
    if (-not [string]::IsNullOrEmpty($previousAlias) -and
        $script:AliasSpecified -and
        $previousAlias -ne $Alias) {
        Remove-AliasCommand -AliasName $previousAlias -InstallDirectory $installDirectory
        Write-Info "Alias anterior '$previousAlias' eliminado."
    }

    if (-not $script:AliasSpecified) {
        $effectiveAlias = $previousAlias
    }
    else {
        $effectiveAlias = $Alias
    }

    Register-MainCommand -InstallDirectory $installDirectory -MainScriptPath $destinationScript

    $aliasPath = ''
    if (-not [string]::IsNullOrWhiteSpace($effectiveAlias)) {
        $aliasPath = Register-AliasCommand -InstallDirectory $installDirectory `
            -MainScriptPath $destinationScript -AliasName $effectiveAlias
    }

    $previousPathEntries = @(Get-ObjectProperty -Object $previousManifest -Name 'pathEntriesAdded' -Default @())
    $previousRcFiles = @(Get-ObjectProperty -Object $previousManifest -Name 'rcFilesModified' -Default @())

    $allPathEntries = @($previousPathEntries + $script:PathEntriesAdded | Select-Object -Unique)
    $allRcFiles = @($previousRcFiles + $script:RcFilesModified | Select-Object -Unique)

    $manifest = [ordered]@{
        manifestVersion = 1
        installedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        platform        = Get-PlatformName
        installDir      = $installDirectory
        mainScript      = $destinationScript
        alias           = $effectiveAlias
        aliasPath       = $aliasPath
        pathEntries     = $allPathEntries
        rcFiles         = $allRcFiles
        toolsPathAdded  = ($script:ToolsPathAdded -or [bool](Get-ObjectProperty -Object $previousManifest -Name 'toolsPathAdded' -Default $false))
    }

    Write-Manifest -Path $manifestPath -Data $manifest
}

function Remove-AliasCommand {
    param(
        [Parameter(Mandatory = $true)][string]$AliasName,
        [Parameter(Mandatory = $true)][string]$InstallDirectory
    )

    if (Test-WindowsPlatform) {
        $aliasPath = Join-Path $InstallDirectory ($AliasName + '.cmd')
    }
    else {
        $aliasPath = Join-Path (Get-UnixBinDirectory) $AliasName
    }

    Remove-CommandFile -Path $aliasPath | Out-Null
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

function Invoke-Uninstall {
    Write-Step 'Desinstalación de generateCodeCoverageReport'

    $installDirectory = Get-InstallDirectory
    $manifestPath = Get-ManifestPath -InstallDirectory $installDirectory
    $manifest = Read-Manifest -Path $manifestPath

    $aliasName = [string](Get-ObjectProperty -Object $manifest -Name 'alias' -Default '')
    $rcFiles = @(Get-ObjectProperty -Object $manifest -Name 'rcFiles' -Default @())

    $removedAnything = $false

    if (Test-WindowsPlatform) {
        $shimPath = Join-Path $installDirectory ($script:ToolName + '.cmd')
        if (Remove-CommandFile -Path $shimPath) {
            Write-Ok "Shim eliminado: $shimPath"
            $removedAnything = $true
        }
    }
    else {
        $wrapperPath = Join-Path (Get-UnixBinDirectory) $script:ToolName
        if (Remove-CommandFile -Path $wrapperPath) {
            Write-Ok "Wrapper eliminado: $wrapperPath"
            $removedAnything = $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($aliasName)) {
        if (Test-WindowsPlatform) {
            $aliasPath = Join-Path $installDirectory ($aliasName + '.cmd')
        }
        else {
            $aliasPath = Join-Path (Get-UnixBinDirectory) $aliasName
        }

        if (Remove-CommandFile -Path $aliasPath) {
            Write-Ok "Alias '$aliasName' eliminado."
            $removedAnything = $true
        }
    }

    if (Test-Path -LiteralPath $installDirectory -PathType Container) {
        Remove-Item -LiteralPath $installDirectory -Recurse -Force
        Write-Ok "Carpeta de instalación eliminada: $installDirectory"
        $removedAnything = $true
    }

    if (Test-WindowsPlatform) {
        if (Remove-PersistentUserPath -Directory $installDirectory) {
            Write-Ok 'Entrada del PATH del usuario eliminada.'
            $removedAnything = $true
        }
    }
    else {
        $profilesToClean = @($rcFiles)
        if ($profilesToClean.Count -eq 0) {
            $profilesToClean = @(
                (Join-Path (Get-UserHome) '.bashrc')
                (Join-Path (Get-UserHome) '.zshrc')
                (Join-Path (Get-UserHome) '.profile')
            )
        }

        foreach ($profilePath in ($profilesToClean | Select-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace($profilePath) -and
                (Remove-UnixProfileBlock -ProfilePath $profilePath -Marker $script:MarkerMain)) {
                Write-Ok "Entrada de PATH eliminada de $profilePath"
                $removedAnything = $true
            }
        }
    }

    if (-not $removedAnything) {
        Write-Info 'No se encontró ninguna instalación previa.'
    }

    $shouldRemoveTools = $UninstallTools
    if (-not $script:UninstallToolsSpecified) {
        $shouldRemoveTools = Confirm-Action -Question '¿Desinstalar también coverlet.console y reportgenerator?' -Default $false
    }

    if ($shouldRemoveTools) {
        Write-Step 'Desinstalación de herramientas globales'

        $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($null -eq $dotnetCommand) {
            Write-Warn 'No se encontró dotnet; no se pueden desinstalar las herramientas globales.'
        }
        else {
            $installedTools = Get-InstalledGlobalTools
            foreach ($tool in $script:RequiredTools) {
                if (-not $installedTools.ContainsKey($tool.Id.ToLowerInvariant())) {
                    Write-Info "$($tool.Id) no estaba instalado."
                    continue
                }

                & dotnet tool uninstall --global $tool.Id
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "No se pudo desinstalar $($tool.Id)."
                }
                else {
                    Write-Ok "$($tool.Id) desinstalado."
                }
            }
        }
    }
    else {
        Write-Info 'Las herramientas globales se conservan.'
    }

    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   Desinstalación completada.' -ForegroundColor Green
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''

    if (-not (Test-WindowsPlatform)) {
        Write-Info 'Si tu terminal actual aún encuentra el comando, abre una terminal nueva.'
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Show-Summary {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   Resumen de la instalación' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan

    if ($script:Installed.Count -gt 0) {
        Write-Host ''
        Write-Host '  Instalado:' -ForegroundColor Green
        foreach ($item in $script:Installed) { Write-Host "    + $item" -ForegroundColor Green }
    }

    if ($script:Updated.Count -gt 0) {
        Write-Host ''
        Write-Host '  Actualizado:' -ForegroundColor Cyan
        foreach ($item in $script:Updated) { Write-Host "    ^ $item" -ForegroundColor Cyan }
    }

    if ($script:Existing.Count -gt 0) {
        Write-Host ''
        Write-Host '  Ya existía:' -ForegroundColor DarkGray
        foreach ($item in $script:Existing) { Write-Host "    = $item" -ForegroundColor DarkGray }
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  Avisos:' -ForegroundColor Yellow
        foreach ($item in $script:Warnings) { Write-Host "    ! $item" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '  Comando instalado: generateCodeCoverageReport' -ForegroundColor White
    Write-Host '  Prueba rápida:     generateCodeCoverageReport -Solution ./MiSolucion.sln -NoOpen' -ForegroundColor DarkGray

    if ($script:NeedsNewTerminal) {
        Write-Host ''
        Write-Host '  Abre una terminal nueva para que los cambios de PATH estén disponibles.' -ForegroundColor Yellow
        Write-Host '  En esta sesión ya se ha actualizado el PATH cuando ha sido posible.' -ForegroundColor DarkGray
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Write-Banner

if (-not (Test-Prerequisites -RequireDotnet (-not $Uninstall))) {
    exit 1
}

try {
    if ($Uninstall) {
        Invoke-Uninstall
    }
    else {
        Install-OrUpdateTools
        Ensure-DotnetToolsPath
        Invoke-Install
        Show-Summary
    }
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message

    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Host ''
        Write-Detail $_.ScriptStackTrace
    }

    exit 1
}

exit 0
