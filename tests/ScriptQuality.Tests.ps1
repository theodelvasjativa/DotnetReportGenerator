BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Scripts = @(
        (Join-Path $script:RepoRoot 'generateCodeCoverageReport.ps1')
        (Join-Path $script:RepoRoot 'install.ps1')
    )
}

Describe 'Calidad de los scripts' {
    It 'todos los scripts se pueden parsear sin errores' {
        foreach ($path in $script:Scripts) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null

            $errors | Should -BeNullOrEmpty -Because "$path no debe tener errores de sintaxis"
        }
    }

    It 'todos los scripts tienen ayuda comentada' {
        foreach ($path in $script:Scripts) {
            $help = Get-Help -Name $path -ErrorAction Stop
            $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$path debe documentarse con #Requires/#.SYNOPSIS"
        }
    }

    It 'no se usa Invoke-Expression' {
        foreach ($path in $script:Scripts) {
            $found = @(Select-String -LiteralPath $path -Pattern 'Invoke-Expression' -SimpleMatch)
            $found | Should -BeNullOrEmpty -Because "$path no debe evaluar cadenas como código"
        }
    }
}
