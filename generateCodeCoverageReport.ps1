<#
.SYNOPSIS
    Genera un reporte de cobertura de código para una solución .NET.

.DESCRIPTION
    Detecta la solución y los proyectos de test, compila una sola vez, mide la
    cobertura con coverlet.console, combina los resultados con ReportGenerator y
    abre el reporte HTML en el navegador predeterminado.

    Funciona en Windows, Linux, macOS y WSL con PowerShell 7.

.PARAMETER Solution
    Ruta al archivo .sln/.slnx o a la carpeta que lo contiene. Si se omite, se
    busca en el directorio actual y en los directorios padre hasta la raíz del
    repositorio git o del volumen.

.PARAMETER TestProject
    Uno o varios archivos .csproj de test (o carpetas que los contengan). Si se
    indica, se ignora la autodetección de proyectos de test.

.PARAMETER Output
    Carpeta donde se genera el reporte. Por defecto:
    <carpeta de la solución>/coverage-report.

.PARAMETER Configuration
    Configuración de compilación. Por defecto: Debug.

.PARAMETER Framework
    Target Framework concreto para proyectos multi-target (por ejemplo net8.0).
    Si se omite, se ejecuta una pasada por cada TFM declarado.

.PARAMETER Filter
    Filtro que se pasa a dotnet test --filter (por ejemplo "FullyQualifiedName~MiTest").

.PARAMETER Formats
    Tipos de reporte de ReportGenerator. Por defecto:
    Html, TextSummary, Cobertura.

.PARAMETER Exclude
    Filtros de exclusión de coverlet. Por defecto se excluyen los ensamblados
    de test más habituales.

.PARAMETER ExcludeByFile
    Patrones glob de archivos que se excluyen de la cobertura.

.PARAMETER Threshold
    Cobertura mínima en porcentaje. Si no se alcanza, el script termina con el
    código de salida 3. El umbral se calcula sobre el reporte global. Si se
    omite, no se comprueba ningún umbral.

.PARAMETER ThresholdType
    Métrica del umbral: Line, Branch o Method. Por defecto: Line.

.PARAMETER NoBuild
    No compila la solución; asume que ya existe una compilación previa.

.PARAMETER NoOpen
    No abre el reporte en el navegador.

.PARAMETER NoHistory
    No guarda ni usa el historial de ReportGenerator.

.PARAMETER Force
    Genera el reporte aunque fallen los tests.

.PARAMETER KeepRaw
    Conserva los archivos XML de cobertura intermedios en <salida>/raw.

.EXAMPLE
    ./generateCodeCoverageReport.ps1

    Busca la solución, detecta los tests, mide la cobertura y abre el reporte.

.EXAMPLE
    ./generateCodeCoverageReport.ps1 -Solution ./MiApp.sln -NoOpen

    Genera el reporte sin abrir el navegador, útil en CI.

.EXAMPLE
    ./generateCodeCoverageReport.ps1 -TestProject ./tests/App.Tests/App.Tests.csproj -Configuration Release

    Mide únicamente el proyecto de test indicado en configuración Release.

.EXAMPLE
    ./generateCodeCoverageReport.ps1 -Threshold 80 -ThresholdType Branch

    Falla con código 3 si la cobertura global de ramas es inferior al 80 %.

.EXAMPLE
    ./generateCodeCoverageReport.ps1 -Filter "FullyQualifiedName~Unit" -NoHistory -KeepRaw

    Ejecuta solo los tests que coinciden con el filtro y conserva los XML.

.NOTES
    Códigos de salida:
      0  Éxito.
      1  Error de configuración, de solución o de herramientas.
      2  Tests fallidos (sin -Force).
      3  Umbral de cobertura no alcanzado.

    Requiere PowerShell 7 o superior y las herramientas globales
    coverlet.console y dotnet-reportgenerator-globaltool. Usa install.ps1
    para instalarlas.
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Ruta a la solución .sln/.slnx o a su carpeta.')]
    [string]$Solution,

    [Parameter(HelpMessage = 'Proyectos .csproj de test concretos.')]
    [string[]]$TestProject,

    [Parameter(HelpMessage = 'Carpeta de salida del reporte.')]
    [string]$Output,

    [Parameter(HelpMessage = 'Configuración de compilación.')]
    [ValidateNotNullOrEmpty()]
    [string]$Configuration = 'Debug',

    [Parameter(HelpMessage = 'Target Framework para proyectos multi-target.')]
    [string]$Framework,

    [Parameter(HelpMessage = 'Filtro para dotnet test.')]
    [string]$Filter,

    [Parameter(HelpMessage = 'Tipos de reporte de ReportGenerator.')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Formats = @('Html', 'TextSummary', 'Cobertura'),

    [Parameter(HelpMessage = 'Filtros de exclusión de coverlet.')]
    [string[]]$Exclude = @('[*.Tests]*', '[*.Test]*', '[*.UnitTests]*', '[*.IntegrationTests]*'),

    [Parameter(HelpMessage = 'Patrones de archivos excluidos de la cobertura.')]
    [string[]]$ExcludeByFile = @('**/Migrations/*.cs', '**/*.g.cs', '**/*.Designer.cs'),

    [Parameter(HelpMessage = 'Cobertura mínima en porcentaje.')]
    [ValidateRange(0, 100)]
    [int]$Threshold,

    [Parameter(HelpMessage = 'Métrica del umbral: Line, Branch o Method.')]
    [ValidateSet('Line', 'Branch', 'Method')]
    [string]$ThresholdType = 'Line',

    [Parameter(HelpMessage = 'No compila la solución.')]
    [switch]$NoBuild,

    [Parameter(HelpMessage = 'No abre el navegador.')]
    [switch]$NoOpen,

    [Parameter(HelpMessage = 'No guarda ni usa historial.')]
    [switch]$NoHistory,

    [Parameter(HelpMessage = 'Genera el reporte aunque fallen los tests.')]
    [switch]$Force,

    [Parameter(HelpMessage = 'Conserva los XML de cobertura intermedios.')]
    [switch]$KeepRaw
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class CoverageException : System.Exception {
    [int]$ExitCode

    CoverageException([string]$Message, [int]$ExitCode) : base($Message) {
        $this.ExitCode = $ExitCode
    }
}

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------

$global:LASTEXITCODE = 0

$script:IsWindowsHost = $IsWindows
$script:IsMacHost = $IsMacOS
$script:ConfigurationValue = $Configuration
$script:FrameworkValue = $Framework
$script:FilterValue = $Filter
$script:ThresholdSpecified = $PSBoundParameters.ContainsKey('Threshold')
$script:ThresholdValue = $Threshold
$script:ThresholdTypeValue = $ThresholdType
$script:NoHistoryValue = $NoHistory.IsPresent
$script:ForceValue = $Force.IsPresent
$script:KeepRawValue = $KeepRaw.IsPresent
$script:NoOpenValue = $NoOpen.IsPresent
$script:TempDirectory = $null
$script:CoverletPath = $null
$script:ReportGeneratorPath = $null
$script:FinalExitCode = 1

if ($script:IsWindowsHost) {
    $script:DotnetToolsDirectory = Join-Path $env:USERPROFILE '.dotnet\tools'
}
else {
    $script:DotnetToolsDirectory = Join-Path (Join-Path $HOME '.dotnet') 'tools'
}

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   Cobertura de código .NET' -ForegroundColor Cyan
    Write-Host '   coverlet.console + ReportGenerator' -ForegroundColor DarkGray
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

function Write-Detail {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "         $Message" -ForegroundColor DarkGray
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

function Test-IsInteractive {
    if (-not [string]::IsNullOrEmpty($env:CI)) { return $false }
    if ($env:TF_BUILD -eq 'True') { return $false }

    try {
        return -not [Console]::IsInputRedirected
    }
    catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Get-PathComparison {
    if ($script:IsWindowsHost) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }

    return [System.StringComparison]::Ordinal
}

function Resolve-UserPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $leftValue = [System.IO.Path]::GetFullPath($Left).TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar)
    $rightValue = [System.IO.Path]::GetFullPath($Right).TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar)

    return [string]::Equals($leftValue, $rightValue, (Get-PathComparison))
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $childValue = [System.IO.Path]::GetFullPath($Child).TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar)
    $parentValue = [System.IO.Path]::GetFullPath($Parent).TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar)

    if ([string]::Equals($childValue, $parentValue, (Get-PathComparison))) { return $true }

    $prefix = $parentValue + $separator
    return $childValue.StartsWith($prefix, (Get-PathComparison))
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)

    $result = $Value
    foreach ($character in [System.IO.Path]::GetInvalidFileNameChars()) {
        $result = $result.Replace([string]$character, '_')
    }

    $result = $result -replace '\s+', '-'
    return $result
}

function New-CoverageTempDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('code-coverage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-CoverageTempDirectory {
    if ($null -eq $script:TempDirectory) { return }
    if (-not (Test-Path -LiteralPath $script:TempDirectory -PathType Container)) { return }

    Remove-Item -LiteralPath $script:TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

function Find-GitRoot {
    param([Parameter(Mandatory = $true)][string]$StartPath)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-Path -LiteralPath $StartPath -PathType Container)) { return $null }

    $output = & git -C $StartPath rev-parse --show-toplevel 2>$null
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) { return $null }

    $firstLine = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Select-Object -First 1
    if ($null -eq $firstLine) { return $null }

    return ([string]$firstLine).Trim()
}

function Test-OutputIsIgnored {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $true }

    $gitRoot = Find-GitRoot -StartPath $OutputPath
    if ($null -eq $gitRoot) { return $true }

    $relativePath = [System.IO.Path]::GetRelativePath($gitRoot, $OutputPath)
    if ($relativePath.StartsWith('..', [System.StringComparison]::Ordinal)) { return $true }

    $relativePath = $relativePath -replace '\\', '/'

    & git -C $gitRoot check-ignore -q -- $relativePath 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Show-GitIgnoreWarning {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    if (Test-OutputIsIgnored -OutputPath $OutputPath) { return }

    Write-Warn "La carpeta de salida no está en .gitignore: $OutputPath"
    Write-Info 'Añádela manualmente para no ensuciar el repositorio, por ejemplo:'
    Write-Detail 'coverage-report/'
}

# ---------------------------------------------------------------------------
# Solution discovery
# ---------------------------------------------------------------------------

function Select-Solution {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Candidates)

    Write-Host ''
    Write-Info 'Se encontraron varias soluciones:'
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        Write-Host ("    [{0}] {1}" -f ($index + 1), $Candidates[$index].FullName) -ForegroundColor White
    }

    while ($true) {
        $answer = Read-Host "Elige una solución (1-$($Candidates.Count))"
        $selected = 0
        if ([int]::TryParse($answer, [ref]$selected) -and
            $selected -ge 1 -and $selected -le $Candidates.Count) {
            return $Candidates[$selected - 1]
        }

        Write-Warn 'Opción no válida.'
    }
}

function Find-Solution {
    param([Parameter(Mandatory = $true)][string]$StartDirectory)

    $directory = [System.IO.Path]::GetFullPath($StartDirectory)
    $gitRoot = Find-GitRoot -StartPath $directory

    while ($true) {
        $candidates = @()
        foreach ($filter in @('*.sln', '*.slnx')) {
            $candidates += @(Get-ChildItem -LiteralPath $directory -File -Filter $filter -ErrorAction SilentlyContinue)
        }

        $candidates = @($candidates | Sort-Object -Property FullName)

        if ($candidates.Count -eq 1) { return $candidates[0] }
        if ($candidates.Count -gt 1) {
            if (-not (Test-IsInteractive)) {
                throw [CoverageException]::new(
                    "Se encontraron varias soluciones en '$directory'. Usa -Solution para indicar cuál usar.",
                    1
                )
            }

            return (Select-Solution -Candidates $candidates)
        }

        if ($null -ne $gitRoot -and (Test-SamePath -Left $directory -Right $gitRoot)) { break }

        $parent = [System.IO.Path]::GetDirectoryName($directory)
        if ([string]::IsNullOrEmpty($parent) -or (Test-SamePath -Left $parent -Right $directory)) { break }

        $directory = $parent
    }

    return $null
}

function New-SolutionInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return [pscustomobject]@{
        Path      = $fullPath
        Directory = [System.IO.Path]::GetDirectoryName($fullPath)
        Root      = [System.IO.Path]::GetDirectoryName($fullPath)
        Extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    }
}

function Resolve-SolutionInfo {
    param([string]$SolutionArgument)

    if (-not [string]::IsNullOrWhiteSpace($SolutionArgument)) {
        $resolved = Resolve-UserPath -Path $SolutionArgument

        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $resolved -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.sln', '.slnx') } |
                Sort-Object -Property FullName)

            if ($candidates.Count -eq 0) {
                throw [CoverageException]::new("No se encontró ninguna solución .sln/.slnx en '$resolved'.", 1)
            }

            if ($candidates.Count -gt 1) {
                if (-not (Test-IsInteractive)) {
                    throw [CoverageException]::new(
                        "Se encontraron varias soluciones en '$resolved'. Usa -Solution con la ruta del archivo.",
                        1
                    )
                }

                $resolved = (Select-Solution -Candidates $candidates).FullName
            }
            else {
                $resolved = $candidates[0].FullName
            }
        }
        elseif (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw [CoverageException]::new("No existe la solución indicada: $resolved", 1)
        }

        $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
        if ($extension -notin @('.sln', '.slnx')) {
            throw [CoverageException]::new("La ruta indicada no es un archivo .sln o .slnx: $resolved", 1)
        }

        return (New-SolutionInfo -Path $resolved)
    }

    $found = Find-Solution -StartDirectory (Get-Location).ProviderPath
    if ($null -eq $found) {
        throw [CoverageException]::new(
            'No se encontró ninguna solución .sln/.slnx en el directorio actual ni en sus padres. Usa -Solution.',
            1
        )
    }

    return (New-SolutionInfo -Path $found.FullName)
}

function Get-SolutionProjects {
    param([Parameter(Mandatory = $true)]$SolutionInfo)

    Write-Info "Leyendo proyectos de la solución..."
    $output = & dotnet sln $SolutionInfo.Path list 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $details = (@($output) | Out-String).Trim()

        if ($SolutionInfo.Extension -eq '.slnx') {
            throw [CoverageException]::new(
                "No se pudo leer la solución .slnx. Tu SDK de .NET no soporta este formato. " +
                "Actualiza a .NET SDK 9.0.200 o superior, o usa un archivo .sln.`n$details",
                1
            )
        }

        throw [CoverageException]::new("No se pudo leer la solución con 'dotnet sln list'.`n$details", 1)
    }

    $projects = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($output)) {
        $text = ([string]$line).Trim()
        if ($text -match '\.(cs|fs|vb)proj$') {
            $fullPath = $text
            if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
                $fullPath = Join-Path $SolutionInfo.Directory $fullPath
            }

            $fullPath = [System.IO.Path]::GetFullPath($fullPath)
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $projects.Add($fullPath)
            }
        }
    }

    if ($projects.Count -eq 0) {
        throw [CoverageException]::new("No se encontraron proyectos dentro de $($SolutionInfo.Path).", 1)
    }

    return @($projects | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# MSBuild and test project detection
# ---------------------------------------------------------------------------

function Get-MsBuildProperty {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [hashtable]$Properties = @{}
    )

    $arguments = @('msbuild', $ProjectPath, "-getProperty:$PropertyName", '-nologo', '-v:q')
    foreach ($key in $Properties.Keys) {
        $arguments += "-p:$key=$($Properties[$key])"
    }

    $output = & dotnet @arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) { return $null }

    $lines = @($output |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -ne '' })

    if ($lines.Count -eq 0) { return $null }

    return $lines[$lines.Count - 1]
}

function Get-ProjectTargetFrameworks {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $multiple = Get-MsBuildProperty -ProjectPath $ProjectPath -PropertyName 'TargetFrameworks'
    if (-not [string]::IsNullOrWhiteSpace($multiple)) {
        return @($multiple -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' })
    }

    $single = Get-MsBuildProperty -ProjectPath $ProjectPath -PropertyName 'TargetFramework'
    if (-not [string]::IsNullOrWhiteSpace($single)) {
        return @($single.Trim())
    }

    return @()
}

function Test-TestSdkReference {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$SolutionRoot
    )

    $files = New-Object System.Collections.Generic.List[string]
    $files.Add($ProjectPath)

    $directory = [System.IO.Path]::GetDirectoryName($ProjectPath)
    while (-not [string]::IsNullOrEmpty($directory)) {
        $propsPath = Join-Path $directory 'Directory.Build.props'
        if (Test-Path -LiteralPath $propsPath -PathType Leaf) {
            $files.Add($propsPath)
        }

        if (Test-SamePath -Left $directory -Right $SolutionRoot) { break }

        $parent = [System.IO.Path]::GetDirectoryName($directory)
        if ([string]::IsNullOrEmpty($parent) -or (Test-SamePath -Left $parent -Right $directory)) { break }
        $directory = $parent
    }

    foreach ($file in $files) {
        try {
            $content = Get-Content -LiteralPath $file -Raw -Encoding utf8 -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($content -match 'Microsoft\.NET\.Test\.Sdk') { return $true }
        if ($content -match 'MSTest\.Sdk') { return $true }
        if ($content -match 'IsTestProject\s*>\s*true') { return $true }
    }

    return $false
}

function Test-ProjectIsTest {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$SolutionRoot
    )

    $value = Get-MsBuildProperty -ProjectPath $ProjectPath -PropertyName 'IsTestProject'
    if ($null -ne $value -and $value.Trim() -eq 'true') { return $true }

    return (Test-TestSdkReference -ProjectPath $ProjectPath -SolutionRoot $SolutionRoot)
}

function New-TestProjectInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return [pscustomobject]@{
        Path             = $fullPath
        Name             = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
        TargetFrameworks = @(Get-ProjectTargetFrameworks -ProjectPath $fullPath)
    }
}

function Get-TestProjects {
    param(
        [Parameter(Mandatory = $true)][string[]]$ProjectPaths,
        [Parameter(Mandatory = $true)][string]$SolutionRoot
    )

    $tests = New-Object System.Collections.Generic.List[object]
    foreach ($projectPath in $ProjectPaths) {
        if (-not (Test-ProjectIsTest -ProjectPath $projectPath -SolutionRoot $SolutionRoot)) {
            Write-Detail "No es de test: $([System.IO.Path]::GetFileName($projectPath))"
            continue
        }

        $project = New-TestProjectInfo -Path $projectPath
        $tests.Add($project)
        Write-Ok "$($project.Name) [$($project.TargetFrameworks -join ', ')]"
    }

    return $tests.ToArray()
}

function Resolve-TestProjectArguments {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    $result = New-Object System.Collections.Generic.List[object]

    foreach ($value in $Values) {
        $resolved = Resolve-UserPath -Path $value

        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $projects = @(Get-ChildItem -LiteralPath $resolved -File -Filter '*.csproj' -ErrorAction SilentlyContinue |
                Sort-Object -Property FullName)

            if ($projects.Count -eq 0) {
                throw [CoverageException]::new("No se encontró ningún .csproj en '$resolved'.", 1)
            }

            foreach ($project in $projects) {
                $result.Add((New-TestProjectInfo -Path $project.FullName))
            }
        }
        elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
            if ([System.IO.Path]::GetExtension($resolved).ToLowerInvariant() -ne '.csproj') {
                throw [CoverageException]::new("El proyecto indicado no es un archivo .csproj: $resolved", 1)
            }

            $result.Add((New-TestProjectInfo -Path $resolved))
        }
        else {
            throw [CoverageException]::new("No existe el proyecto de test indicado: $resolved", 1)
        }
    }

    return @($result | Sort-Object -Property Path -Unique)
}

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------

function Get-OutputDirectory {
    param(
        [string]$OutputArgument,
        [Parameter(Mandatory = $true)][string]$SolutionRoot
    )

    if ([string]::IsNullOrWhiteSpace($OutputArgument)) {
        return [System.IO.Path]::GetFullPath((Join-Path $SolutionRoot 'coverage-report'))
    }

    return [System.IO.Path]::GetFullPath((Resolve-UserPath -Path $OutputArgument))
}

function Assert-OutputDirectoryIsSafe {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SolutionRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)

    if (Test-SamePath -Left $fullPath -Right $SolutionRoot) {
        throw [CoverageException]::new(
            "La carpeta de salida no puede ser la raíz de la solución ($fullPath). Usa una subcarpeta dedicada.",
            1
        )
    }

    if (Test-PathInside -Child $SolutionRoot -Parent $fullPath) {
        throw [CoverageException]::new(
            "La carpeta de salida ($fullPath) contiene la solución y se borraría el código fuente. Usa otra carpeta.",
            1
        )
    }

    if (Test-SamePath -Left $fullPath -Right $volumeRoot) {
        throw [CoverageException]::new("La carpeta de salida no puede ser la raíz del volumen ($fullPath).", 1)
    }

    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        if (Test-SamePath -Left $fullPath -Right $HOME) {
            throw [CoverageException]::new(
                "La carpeta de salida no puede ser el directorio personal ($fullPath). Usa una carpeta dedicada.",
                1
            )
        }

        if (Test-PathInside -Child $HOME -Parent $fullPath) {
            throw [CoverageException]::new(
                "La carpeta de salida ($fullPath) contiene el directorio personal y se borrarían datos del usuario.",
                1
            )
        }
    }

    if (Test-SamePath -Left $fullPath -Right (Get-Location).ProviderPath) {
        throw [CoverageException]::new(
            "La carpeta de salida no puede ser el directorio actual. Usa una subcarpeta dedicada.",
            1
        )
    }

    if (Test-PathInside -Child (Get-Location).ProviderPath -Parent $fullPath) {
        throw [CoverageException]::new(
            "La carpeta de salida ($fullPath) contiene el directorio actual y se borraría el trabajo en curso.",
            1
        )
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $topLevelProjects = @(Get-ChildItem -LiteralPath $fullPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.csproj', '.fsproj', '.vbproj', '.sln', '.slnx') })

        if ($topLevelProjects.Count -gt 0) {
            throw [CoverageException]::new(
                "La carpeta de salida ($fullPath) contiene archivos de proyecto o solución. Usa una carpeta dedicada.",
                1
            )
        }
    }
}

function Initialize-OutputDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SolutionRoot,
        [bool]$KeepHistory = $true
    )

    Assert-OutputDirectoryIsSafe -OutputPath $OutputPath -SolutionRoot $SolutionRoot

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        throw [CoverageException]::new("La ruta de salida existe y es un archivo: $OutputPath", 1)
    }

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        return
    }

    $items = @(Get-ChildItem -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($KeepHistory -and $item.PSIsContainer -and $item.Name -eq 'history') { continue }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

function Resolve-ToolPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $candidates = @($Name)
    if ($script:IsWindowsHost) {
        $candidates = @($Name + '.exe', $Name)
    }

    foreach ($candidate in $candidates) {
        $path = Join-Path $script:DotnetToolsDirectory $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }

    return $null
}

function Test-CoverageTools {
    Write-Step 'Comprobación de herramientas'

    $script:CoverletPath = Resolve-ToolPath -Name 'coverlet'
    if ($null -eq $script:CoverletPath) {
        throw [CoverageException]::new(
            "No se encontró 'coverlet'. Ejecuta install.ps1 o instala la herramienta con:`n" +
            '  dotnet tool install --global coverlet.console',
            1
        )
    }

    $script:ReportGeneratorPath = Resolve-ToolPath -Name 'reportgenerator'
    if ($null -eq $script:ReportGeneratorPath) {
        throw [CoverageException]::new(
            "No se encontró 'reportgenerator'. Ejecuta install.ps1 o instala la herramienta con:`n" +
            '  dotnet tool install --global dotnet-reportgenerator-globaltool',
            1
        )
    }

    Write-Ok "coverlet: $script:CoverletPath"
    Write-Ok "reportgenerator: $script:ReportGeneratorPath"
}

# ---------------------------------------------------------------------------
# Coverage execution
# ---------------------------------------------------------------------------

function Get-FrameworksToRun {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [string]$FrameworkOverride
    )

    if (-not [string]::IsNullOrWhiteSpace($FrameworkOverride)) {
        if ($Project.TargetFrameworks.Count -gt 0 -and
            $FrameworkOverride -notin $Project.TargetFrameworks) {
            throw [CoverageException]::new(
                "El framework '$FrameworkOverride' no está declarado en $($Project.Path). " +
                "Valores disponibles: $($Project.TargetFrameworks -join ', ')",
                1
            )
        }

        return @($FrameworkOverride)
    }

    if ($Project.TargetFrameworks.Count -eq 0) { return @('') }

    return @($Project.TargetFrameworks)
}

function Get-ProjectTargetPath {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [string]$Framework,
        [Parameter(Mandatory = $true)][string]$Configuration
    )

    $properties = @{ Configuration = $Configuration }
    if (-not [string]::IsNullOrWhiteSpace($Framework)) {
        $properties['TargetFramework'] = $Framework
    }

    $targetPath = Get-MsBuildProperty -ProjectPath $Project.Path -PropertyName 'TargetPath' -Properties $properties
    if (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        return $targetPath
    }

    $outputPath = Get-MsBuildProperty -ProjectPath $Project.Path -PropertyName 'OutputPath' -Properties $properties
    $assemblyName = Get-MsBuildProperty -ProjectPath $Project.Path -PropertyName 'AssemblyName' -Properties $properties

    if (-not [string]::IsNullOrWhiteSpace($outputPath) -and -not [string]::IsNullOrWhiteSpace($assemblyName)) {
        if (-not [System.IO.Path]::IsPathRooted($outputPath)) {
            $outputPath = Join-Path ([System.IO.Path]::GetDirectoryName($Project.Path)) $outputPath
        }

        $candidate = Join-Path $outputPath ($assemblyName + '.dll')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $hint = '-NoBuild'
    throw [CoverageException]::new(
        "No se encontró la DLL compilada de $($Project.Name)" +
        $(if (-not [string]::IsNullOrWhiteSpace($Framework)) { " para $Framework" } else { '' }) +
        ". Compila la solución primero o revisa la configuración '$Configuration'. $hint",
        1
    )
}

function New-CoverletTargetArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [string]$Framework,
        [string]$Filter
    )

    if ($ProjectPath.Contains('"')) {
        throw [CoverageException]::new("La ruta del proyecto contiene comillas dobles y no se puede pasar a coverlet: $ProjectPath", 1)
    }

    $arguments = 'test "' + $ProjectPath + '" --no-build -c "' + $Configuration + '"'

    if (-not [string]::IsNullOrWhiteSpace($Framework)) {
        $arguments += ' -f "' + $Framework + '"'
    }

    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        if ($Filter.Contains('"')) {
            throw [CoverageException]::new('El filtro de tests no puede contener comillas dobles.', 1)
        }

        $arguments += ' --filter "' + $Filter + '"'
    }

    return $arguments
}

function Invoke-CoverageForProject {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Framework,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    $targetArguments = New-CoverletTargetArguments `
        -ProjectPath $Project.Path `
        -Configuration $script:ConfigurationValue `
        -Framework $Framework `
        -Filter $script:FilterValue

    $arguments = @(
        $TargetPath
        '--target', 'dotnet'
        '--targetargs', $targetArguments
        '--output', $OutputFile
        '--format', 'cobertura'
        '--verbosity', 'minimal'
    )

    foreach ($attribute in @('GeneratedCode', 'CompilerGenerated', 'ExcludeFromCodeCoverage')) {
        $arguments += @('--exclude-by-attribute', $attribute)
    }

    foreach ($pattern in $Exclude) {
        if (-not [string]::IsNullOrWhiteSpace($pattern)) {
            $arguments += @('--exclude', $pattern)
        }
    }

    foreach ($pattern in $ExcludeByFile) {
        if (-not [string]::IsNullOrWhiteSpace($pattern)) {
            $arguments += @('--exclude-by-file', $pattern)
        }
    }

    Write-Detail "coverlet $($Project.Name)"
    & $script:CoverletPath @arguments | Out-Host
    $exitCode = $LASTEXITCODE

    $isTestFailure = ($exitCode -in @(1, 3))
    $isToolError = ($exitCode -ne 0 -and -not $isTestFailure)

    return [pscustomobject]@{
        Project       = $Project
        Framework     = $Framework
        ExitCode      = $exitCode
        IsTestFailure = $isTestFailure
        IsToolError   = $isToolError
        CoverageFile  = $OutputFile
    }
}

function Build-Solution {
    param([Parameter(Mandatory = $true)]$SolutionInfo)

    Write-Step "Compilando la solución ($script:ConfigurationValue)"

    & dotnet build $SolutionInfo.Path -c $script:ConfigurationValue --nologo
    if ($LASTEXITCODE -ne 0) {
        throw [CoverageException]::new(
            "La compilación falló con código $($LASTEXITCODE). Corrige los errores y vuelve a intentarlo.",
            1
        )
    }

    Write-Ok 'Compilación completada.'
}

# ---------------------------------------------------------------------------
# Report generation and summary
# ---------------------------------------------------------------------------

function New-CoverageReport {
    param(
        [Parameter(Mandatory = $true)][string[]]$CoverageFiles,
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][string]$ReportTypes,
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$HistoryDirectory,
        [bool]$UseHistory = $true
    )

    $arguments = @(
        "-reports:$($CoverageFiles -join ';')"
        "-targetdir:$TargetDirectory"
        "-reporttypes:$ReportTypes"
        "-sourcedirs:$SourceDirectory"
        '-verbosity:Warning'
    )

    if ($UseHistory) {
        $arguments += "-historydir:$HistoryDirectory"
    }

    & $script:ReportGeneratorPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw [CoverageException]::new(
            "ReportGenerator falló con código $($LASTEXITCODE). Revisa los archivos de cobertura intermedios.",
            1
        )
    }
}

function Get-JsonNumber {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }

    return [double]$property.Value
}

function Get-CoverageSummary {
    param([Parameter(Mandatory = $true)][string]$SummaryPath)

    if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
        throw [CoverageException]::new(
            "ReportGenerator no generó '$SummaryPath'. Comprueba que la versión instalada soporta el formato JsonSummary.",
            1
        )
    }

    $data = Get-Content -LiteralPath $SummaryPath -Raw -Encoding utf8 | ConvertFrom-Json
    $summaryProperty = $data.PSObject.Properties['summary']
    if ($null -eq $summaryProperty) {
        throw [CoverageException]::new("El archivo '$SummaryPath' no tiene la estructura esperada.", 1)
    }

    $summary = $summaryProperty.Value
    return [pscustomobject]@{
        Line           = Get-JsonNumber -Object $summary -Name 'linecoverage'
        Branch         = Get-JsonNumber -Object $summary -Name 'branchcoverage'
        Method         = Get-JsonNumber -Object $summary -Name 'methodcoverage'
        CoveredLines   = Get-JsonNumber -Object $summary -Name 'coveredlines'
        CoverableLines = Get-JsonNumber -Object $summary -Name 'coverablelines'
        CoveredBranches = Get-JsonNumber -Object $summary -Name 'coveredbranches'
        TotalBranches  = Get-JsonNumber -Object $summary -Name 'totalbranches'
        CoveredMethods = Get-JsonNumber -Object $summary -Name 'coveredmethods'
        TotalMethods   = Get-JsonNumber -Object $summary -Name 'totalmethods'
    }
}

function Format-CoverageValue {
    param(
        $Percentage,
        $Covered,
        $Total
    )

    $percentageText = 'N/D'
    if ($null -ne $Percentage) {
        $percentageText = ('{0:N2} %' -f [double]$Percentage)
    }

    if ($null -ne $Covered -and $null -ne $Total -and [double]$Total -gt 0) {
        return ('{0} ({1:N0}/{2:N0})' -f $percentageText, [double]$Covered, [double]$Total)
    }

    return $percentageText
}

function Show-CoverageSummary {
    param([Parameter(Mandatory = $true)]$Summary)

    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   Cobertura global' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ('   Líneas   : ' + (Format-CoverageValue -Percentage $Summary.Line -Covered $Summary.CoveredLines -Total $Summary.CoverableLines)) -ForegroundColor White
    Write-Host ('   Ramas    : ' + (Format-CoverageValue -Percentage $Summary.Branch -Covered $Summary.CoveredBranches -Total $Summary.TotalBranches)) -ForegroundColor White
    Write-Host ('   Métodos  : ' + (Format-CoverageValue -Percentage $Summary.Method -Covered $Summary.CoveredMethods -Total $Summary.TotalMethods)) -ForegroundColor White
    Write-Host ''
}

function Get-ThresholdPercentage {
    param(
        [Parameter(Mandatory = $true)]$Summary,
        [Parameter(Mandatory = $true)][string]$Type
    )

    switch ($Type) {
        'Line' { return $Summary.Line }
        'Branch' { return $Summary.Branch }
        'Method' { return $Summary.Method }
        default { return $null }
    }
}

function Test-CoverageThreshold {
    param(
        [Parameter(Mandatory = $true)]$Summary,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][string]$Type
    )

    $percentage = Get-ThresholdPercentage -Summary $Summary -Type $Type
    if ($null -eq $percentage) {
        Write-Warn "No hay datos de cobertura para la métrica '$Type'; se trata como 0 %."
        $percentage = 0
    }

    $label = switch ($Type) {
        'Line' { 'líneas' }
        'Branch' { 'ramas' }
        'Method' { 'métodos' }
        default { $Type }
    }

    if ([double]$percentage -lt $Minimum) {
        Write-Err ("Umbral de {0}: {1} %. Cobertura actual: {2:N2} %." -f $label, $Minimum, [double]$percentage)
        return $false
    }

    Write-Ok ("Umbral de {0} alcanzado: {1:N2} % (mínimo {2} %)." -f $label, [double]$percentage, $Minimum)
    return $true
}

# ---------------------------------------------------------------------------
# Browser
# ---------------------------------------------------------------------------

function Open-Report {
    param([Parameter(Mandatory = $true)][string]$IndexPath)

    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
        Write-Warn "No se encontró '$IndexPath'. Revisa los formatos solicitados con -Formats (se necesita Html)."
        return
    }

    Write-Step 'Abriendo el reporte en el navegador'

    if ($script:IsWindowsHost) {
        Start-Process -FilePath $IndexPath
        Write-Ok 'Reporte abierto.'
        return
    }

    if ($script:IsMacHost) {
        & open $IndexPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "No se pudo abrir el navegador. Abre manualmente: $IndexPath"
        }
        else {
            Write-Ok 'Reporte abierto.'
        }

        return
    }

    $isWsl = (-not [string]::IsNullOrEmpty($env:WSL_DISTRO_NAME))
    if (-not $isWsl -and (Test-Path -LiteralPath '/proc/version' -PathType Leaf)) {
        try {
            $procVersion = Get-Content -LiteralPath '/proc/version' -Raw
            $isWsl = ($procVersion -match 'microsoft')
        }
        catch {
            $isWsl = $false
        }
    }

    if ($isWsl -and (Get-Command wslview -ErrorAction SilentlyContinue)) {
        & wslview $IndexPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "No se pudo abrir el navegador con wslview. Abre manualmente: $IndexPath"
        }
        else {
            Write-Ok 'Reporte abierto.'
        }

        return
    }

    if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
        & xdg-open $IndexPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "No se pudo abrir el navegador. Abre manualmente: $IndexPath"
        }
        else {
            Write-Ok 'Reporte abierto.'
        }

        return
    }

    Write-Warn "No se encontró xdg-open ni wslview. Abre manualmente: $IndexPath"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

function Invoke-Main {
    $startedAt = Get-Date
    Write-Banner

    Test-CoverageTools

    Write-Step 'Búsqueda de la solución'
    $solutionInfo = Resolve-SolutionInfo -SolutionArgument $Solution
    Write-Ok "Solución: $($solutionInfo.Path)"
    Write-Info "Configuración: $script:ConfigurationValue"

    $projectPaths = @(Get-SolutionProjects -SolutionInfo $solutionInfo)
    Write-Info "$($projectPaths.Count) proyecto(s) en la solución."

    Write-Step 'Detección de proyectos de test'

    if ($null -ne $TestProject -and $TestProject.Count -gt 0) {
        $testProjects = @(Resolve-TestProjectArguments -Values $TestProject)
        Write-Info 'Se usarán los proyectos indicados con -TestProject.'
        foreach ($project in $testProjects) {
            Write-Ok "$($project.Name) [$($project.TargetFrameworks -join ', ')]"
        }
    }
    else {
        $testProjects = @(Get-TestProjects -ProjectPaths $projectPaths -SolutionRoot $solutionInfo.Root)
    }

    if ($testProjects.Count -eq 0) {
        throw [CoverageException]::new(
            'No se encontraron proyectos de test en la solución. ' +
            'Usa -TestProject o añade IsTestProject/Microsoft.NET.Test.Sdk a tus proyectos de test.',
            1
        )
    }

    Write-Step 'Preparación de la carpeta de salida'
    $outputDirectory = Get-OutputDirectory -OutputArgument $Output -SolutionRoot $solutionInfo.Root
    Initialize-OutputDirectory `
        -OutputPath $outputDirectory `
        -SolutionRoot $solutionInfo.Root `
        -KeepHistory (-not $script:NoHistoryValue)
    Write-Ok "Salida: $outputDirectory"
    Show-GitIgnoreWarning -OutputPath $outputDirectory

    if (-not $NoBuild) {
        Build-Solution -SolutionInfo $solutionInfo
    }
    else {
        Write-Warn 'Se omite la compilación (-NoBuild). Se usará la DLL existente.'
    }

    if ($script:KeepRawValue) {
        $rawDirectory = Join-Path $outputDirectory 'raw'
        New-Item -ItemType Directory -Path $rawDirectory -Force | Out-Null
    }
    else {
        $rawDirectory = New-CoverageTempDirectory
        $script:TempDirectory = $rawDirectory
    }

    Write-Info "Cobertura intermedia: $rawDirectory"

    $coverageFiles = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[object]
    $jobIndex = 0

    foreach ($project in $testProjects) {
        $frameworks = @(Get-FrameworksToRun -Project $project -FrameworkOverride $script:FrameworkValue)

        foreach ($framework in $frameworks) {
            $jobIndex++
            $label = $project.Name
            if (-not [string]::IsNullOrWhiteSpace($framework)) {
                $label += " [$framework]"
            }

            Write-Step "Midiendo cobertura: $label"

            $targetPath = Get-ProjectTargetPath `
                -Project $project `
                -Framework $framework `
                -Configuration $script:ConfigurationValue

            $baseName = ConvertTo-SafeFileName -Value ("{0:D3}-{1}-{2}" -f $jobIndex, $project.Name, $framework)
            $coverageFile = Join-Path $rawDirectory ($baseName + '.cobertura.xml')

            $result = Invoke-CoverageForProject `
                -Project $project `
                -TargetPath $targetPath `
                -Framework $framework `
                -OutputFile $coverageFile

            if ($result.ExitCode -eq 0) {
                if (-not (Test-Path -LiteralPath $coverageFile -PathType Leaf)) {
                    throw [CoverageException]::new(
                        "coverlet terminó correctamente pero no generó el archivo de cobertura para $label.",
                        1
                    )
                }

                $coverageFiles.Add($coverageFile)
                Write-Ok "Cobertura recogida: $([System.IO.Path]::GetFileName($coverageFile))"
            }
            elseif ($result.IsTestFailure) {
                $failures.Add([pscustomobject]@{
                    Project   = $project.Name
                    Path      = $project.Path
                    Framework = $framework
                    ExitCode  = $result.ExitCode
                })

                Write-Warn "Los tests fallaron en $label (código $($result.ExitCode))."

                if (Test-Path -LiteralPath $coverageFile -PathType Leaf) {
                    $coverageFiles.Add($coverageFile)
                }
            }
            else {
                throw [CoverageException]::new(
                    "coverlet falló en $label con código $($result.ExitCode). " +
                    'Revisa la salida anterior; si es 101, suele tratarse de un problema de instrumentación.',
                    1
                )
            }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Err 'Tests fallidos:'
        foreach ($failure in $failures) {
            $frameworkText = ''
            if (-not [string]::IsNullOrWhiteSpace($failure.Framework)) {
                $frameworkText = " [$($failure.Framework)]"
            }

            Write-Host ("         - {0}{1}: {2}" -f $failure.Project, $frameworkText, $failure.Path) -ForegroundColor Red
        }

        if (-not $script:ForceValue) {
            Write-Host ''
            Write-Err 'No se generará el reporte porque hay tests fallidos. Usa -Force para generarlo igualmente.'
            $script:FinalExitCode = 2
            return
        }

        Write-Warn 'Se generará el reporte igualmente porque se indicó -Force.'
    }

    if ($coverageFiles.Count -eq 0) {
        throw [CoverageException]::new('No se generó ningún archivo de cobertura. No hay nada que reportar.', 1)
    }

    Write-Step 'Generando el reporte'
    $reportTypes = @(@($Formats) + 'JsonSummary' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) -join ';'

    $historyDirectory = Join-Path $outputDirectory 'history'
    New-CoverageReport `
        -CoverageFiles $coverageFiles.ToArray() `
        -TargetDirectory $outputDirectory `
        -ReportTypes $reportTypes `
        -SourceDirectory $solutionInfo.Root `
        -HistoryDirectory $historyDirectory `
        -UseHistory (-not $script:NoHistoryValue)

    Write-Ok "Reporte generado en $outputDirectory"

    $summaryPath = Join-Path $outputDirectory 'Summary.json'
    $summary = Get-CoverageSummary -SummaryPath $summaryPath
    Show-CoverageSummary -Summary $summary

    if ($script:ThresholdSpecified) {
        if (-not (Test-CoverageThreshold -Summary $summary -Minimum $script:ThresholdValue -Type $script:ThresholdTypeValue)) {
            $script:FinalExitCode = 3
            return
        }
    }

    if (-not $script:NoOpenValue) {
        $indexPath = Join-Path $outputDirectory 'index.html'
        Open-Report -IndexPath $indexPath
    }

    $elapsed = (Get-Date) - $startedAt
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ("   Listo en {0:N1} s." -f $elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ("   Reporte: {0}" -f $outputDirectory) -ForegroundColor White
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''

    $script:FinalExitCode = 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

$exitCode = 1

try {
    Invoke-Main
    $exitCode = $script:FinalExitCode
}
catch [CoverageException] {
    Write-Host ''
    Write-Err $_.Exception.Message
    $exitCode = $_.Exception.ExitCode
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Detail $_.ScriptStackTrace
    }
    $exitCode = 1
}
finally {
    Remove-CoverageTempDirectory
}

exit $exitCode
