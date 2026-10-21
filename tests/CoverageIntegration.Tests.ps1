BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'generateCodeCoverageReport.ps1'
    $script:SourceFixture = Join-Path $PSScriptRoot 'fixture'

    # Test-IsInteractive returns false when CI is set, so the script never
    # blocks waiting for input (for example, when validating -Output).
    $script:OriginalCI = $env:CI
    $env:CI = '1'

    $script:WorkRoot = Join-Path $TestDrive 'work'
    Copy-Item -LiteralPath $script:SourceFixture -Destination $script:WorkRoot -Recurse -Force
    $script:Solution = Join-Path $script:WorkRoot 'Smoke.slnx'

    function Invoke-CoverageScript {
        param([string[]]$Arguments)

        $output = & pwsh -NoProfile -File $script:ScriptPath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }

    function New-OutputPath {
        param([Parameter(Mandatory = $true)][string]$Name)
        return (Join-Path $script:WorkRoot $Name)
    }

    # Builds the fixture once; the rest of the tests reuse the compiled output.
    $script:FirstRun = Invoke-CoverageScript -Arguments @(
        '-Solution', $script:Solution,
        '-Output', (New-OutputPath 'out-basic'),
        '-NoOpen', '-NoHistory'
    )
}

AfterAll {
    $env:CI = $script:OriginalCI
    Remove-Item Env:SMOKE_FAIL -ErrorAction SilentlyContinue
}

Describe 'generateCodeCoverageReport.ps1' {
    It 'genera el reporte HTML y devuelve 0' {
        $script:FirstRun.ExitCode | Should -Be 0 -Because $script:FirstRun.Output

        $outputPath = New-OutputPath 'out-basic'
        Join-Path $outputPath 'Summary.json' | Should -Exist
        Join-Path $outputPath 'index.html' | Should -Exist
        Join-Path $outputPath '.coverage-report' | Should -Exist
    }

    It 'reutiliza una carpeta de salida propia en ejecuciones posteriores' {
        $result = Invoke-CoverageScript -Arguments @(
            '-Solution', $script:Solution,
            '-Output', (New-OutputPath 'out-basic'),
            '-NoOpen', '-NoHistory', '-NoBuild'
        )

        $result.ExitCode | Should -Be 0 -Because $result.Output
    }

    It 'devuelve 3 cuando no se alcanza el umbral' {
        $result = Invoke-CoverageScript -Arguments @(
            '-Solution', $script:Solution,
            '-Output', (New-OutputPath 'out-threshold'),
            '-NoOpen', '-NoHistory', '-NoBuild',
            '-Threshold', '90'
        )

        $result.ExitCode | Should -Be 3 -Because $result.Output
        $result.Output | Should -Match 'Umbral de líneas'
    }

    It 'devuelve 2 y muestra el test fallido' {
        $env:SMOKE_FAIL = '1'
        try {
            $result = Invoke-CoverageScript -Arguments @(
                '-Solution', $script:Solution,
                '-Output', (New-OutputPath 'out-fail'),
                '-NoOpen', '-NoHistory', '-NoBuild'
            )
        }
        finally {
            Remove-Item Env:SMOKE_FAIL -ErrorAction SilentlyContinue
        }

        $result.ExitCode | Should -Be 2 -Because $result.Output
        $result.Output | Should -Match 'Passes_Unless_SmokeFail_Is_Set'
    }

    It 'con -Force genera el reporte aunque fallen los tests' {
        $env:SMOKE_FAIL = '1'
        try {
            $result = Invoke-CoverageScript -Arguments @(
                '-Solution', $script:Solution,
                '-Output', (New-OutputPath 'out-force'),
                '-NoOpen', '-NoHistory', '-NoBuild', '-Force'
            )
        }
        finally {
            Remove-Item Env:SMOKE_FAIL -ErrorAction SilentlyContinue
        }

        $result.ExitCode | Should -Be 0 -Because $result.Output
        Join-Path (New-OutputPath 'out-force') 'Summary.json' | Should -Exist
    }

    It 'devuelve 1 si el filtro no coincide con ningún test' {
        $result = Invoke-CoverageScript -Arguments @(
            '-Solution', $script:Solution,
            '-Output', (New-OutputPath 'out-filter'),
            '-NoOpen', '-NoHistory', '-NoBuild',
            '-Filter', 'FullyQualifiedName~NoExiste'
        )

        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match 'no coincide con ningún test'
    }

    It 'no borra una carpeta de salida con archivos ajenos' {
        $outputPath = New-OutputPath 'out-foreign'
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outputPath 'notas.txt') -Value 'importante'

        $result = Invoke-CoverageScript -Arguments @(
            '-Solution', $script:Solution,
            '-Output', $outputPath,
            '-NoOpen', '-NoHistory', '-NoBuild'
        )

        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match 'no parecen de un reporte'
        Join-Path $outputPath 'notas.txt' | Should -Exist
    }
}
