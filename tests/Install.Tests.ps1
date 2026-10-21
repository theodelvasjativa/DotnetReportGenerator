BeforeDiscovery {
    $script:CanRunInstaller = (-not $IsWindows) -and
        ($null -ne (Get-Command dotnet -ErrorAction SilentlyContinue))
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallScript = Join-Path $script:RepoRoot 'install.ps1'

    $script:OriginalCI = $env:CI
    $script:OriginalHome = $env:HOME
    $script:OriginalShell = $env:SHELL

    $env:CI = '1'
    $env:HOME = Join-Path $TestDrive 'home'
    $env:SHELL = '/bin/bash'
    New-Item -ItemType Directory -Path $env:HOME -Force | Out-Null

    $script:InstallDirectory = Join-Path $env:HOME '.local/share/code-coverage-report'
    $script:ManifestPath = Join-Path $script:InstallDirectory 'install-manifest.json'
    $script:ProfilePath = Join-Path $env:HOME '.bashrc'
    $script:WrapperPath = Join-Path $env:HOME '.local/bin/generateCodeCoverageReport'
    $script:ToolsPath = Join-Path $env:HOME '.dotnet/tools/coverlet'

    function Invoke-InstallScript {
        param([string[]]$Arguments = @())

        $output = & pwsh -NoProfile -File $script:InstallScript @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }

    function Read-ManifestFile {
        return (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json)
    }
}

AfterAll {
    $env:CI = $script:OriginalCI
    $env:HOME = $script:OriginalHome
    $env:SHELL = $script:OriginalShell
}

Describe 'install.ps1' {
    It 'instala el comando y las herramientas' -Skip:(-not $script:CanRunInstaller) {
        $result = Invoke-InstallScript
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $script:WrapperPath | Should -Exist
        $script:ManifestPath | Should -Exist
        $script:ToolsPath | Should -Exist

        $profile = Get-Content -LiteralPath $script:ProfilePath -Raw
        $profile | Should -Match '# >>> generateCodeCoverageReport >>>'
        $profile | Should -Match '# >>> dotnet-tools-path >>>'
    }

    It 'es idempotente y conserva el manifiesto' -Skip:(-not $script:CanRunInstaller) {
        $result = Invoke-InstallScript
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $manifest = Read-ManifestFile
        @($manifest.rcFiles) | Should -Not -BeNullOrEmpty
        @($manifest.pathEntries) | Should -Not -BeNullOrEmpty
        $manifest.toolsPathAdded | Should -BeTrue
    }

    It 'desinstala el comando y conserva las herramientas por defecto' -Skip:(-not $script:CanRunInstaller) {
        $result = Invoke-InstallScript -Arguments @('-Uninstall', '-UninstallTools:$false')
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $script:WrapperPath | Should -Not -Exist
        $script:InstallDirectory | Should -Not -Exist
        $script:ToolsPath | Should -Exist

        $profile = Get-Content -LiteralPath $script:ProfilePath -Raw
        $profile | Should -Not -Match '# >>> generateCodeCoverageReport >>>'
        $profile | Should -Match '# >>> dotnet-tools-path >>>'
    }

    It 'desinstala también las herramientas cuando se pide' -Skip:(-not $script:CanRunInstaller) {
        Invoke-InstallScript | Out-Null
        $result = Invoke-InstallScript -Arguments @('-Uninstall', '-UninstallTools')
        $result.ExitCode | Should -Be 0 -Because $result.Output

        $script:ToolsPath | Should -Not -Exist

        $profile = Get-Content -LiteralPath $script:ProfilePath -Raw
        $profile | Should -Not -Match '# >>> dotnet-tools-path >>>'
    }
}
