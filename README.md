# 📊 DotnetReportGenerator

Una herramienta de línea de comandos para generar reportes de **cobertura de código .NET** con [coverlet.console](https://github.com/coverlet-coverage/coverlet) y [ReportGenerator](https://github.com/danielpalme/ReportGenerator), y abrirlos directamente en el navegador.

Funciona en **Windows, Linux y macOS** con **PowerShell 7**.

```text
generateCodeCoverageReport
```

Un comando. Detecta la solución, encuentra los tests, compila una vez, mide la cobertura de cada proyecto y genera un reporte HTML navegable con historial y umbral de calidad.

---

## ✨ Qué hace

- 🔍 **Autodetecta** la solución (`.sln` y `.slnx`) subiendo por los directorios padre hasta la raíz del repositorio git.
- 🧪 **Detecta los proyectos de test** con `IsTestProject` y, como respaldo, por la referencia a `Microsoft.NET.Test.Sdk`.
- 🧩 **Soporta multi-target**: ejecuta una pasada por cada TFM, o solo la indicada con `-Framework`.
- 📦 **Compila una sola vez** la solución y mide cada proyecto con `coverlet … --no-build`.
- 📈 **Combina toda la cobertura** en un único reporte con ReportGenerator.
- 📊 **Resumen global** en consola: líneas, ramas y métodos.
- 🚦 **Umbral de calidad global** (`-Threshold`) con código de salida distinto de cero.
- 🕘 **Historial de tendencias** entre ejecuciones, salvo con `-NoHistory`.
- 🌐 **Abre el `index.html`** en el navegador, también en WSL.
- 🧹 **Limpia la salida** en cada ejecución, conservando `history`.
- 🛡️ **Comprueba herramientas y rutas** antes de empezar y avisa de problemas de `.gitignore`.

---

## 📋 Requisitos

| Requisito | Detalle |
|---|---|
| PowerShell | **7.0 o superior** (`pwsh`). Windows PowerShell 5.1 no es compatible. |
| .NET SDK | **8.0 o superior** (se usa `dotnet msbuild -getProperty`). |
| Herramientas | `coverlet.console` y `dotnet-reportgenerator-globaltool`. El instalador las instala. |
| Git | Opcional. Se usa para la búsqueda de la raíz del repositorio y el aviso de `.gitignore`. |
| Navegador | Opcional, para abrir el reporte. Usa `-NoOpen` en CI. |

### Instalar PowerShell 7

```powershell
# Windows
winget install --id Microsoft.PowerShell --source winget

# macOS
brew install --cask powershell

# Linux (ejemplo Debian/Ubuntu)
sudo apt-get install powershell
```

Más opciones: <https://learn.microsoft.com/powershell/scripting/install/installing-powershell>.

### Instalar el SDK de .NET

El instalador **no instala el SDK**. Si falta, muestra las instrucciones para tu sistema. Puedes usar:

```powershell
# Windows
winget install Microsoft.DotNet.SDK.8

# macOS
brew install --cask dotnet-sdk

# Linux: consulta tu distribución
# https://learn.microsoft.com/dotnet/core/install/linux
```

Comprueba con:

```bash
dotnet --list-sdks
```

---

## 🚀 Instalación

Clona el repositorio y ejecuta el instalador con PowerShell 7:

```powershell
git clone <url-del-repositorio>
cd DotnetReportGenerator

pwsh ./install.ps1
```

El instalador es **idempotente**: puedes ejecutarlo las veces que quieras.

### Qué hace el instalador

1. Comprueba PowerShell 7 y el SDK de .NET.
2. Instala las herramientas globales que falten:
   - `coverlet.console`
   - `dotnet-reportgenerator-globaltool`
3. Añade `~/.dotnet/tools` al `PATH` si es necesario.
4. Copia `generateCodeCoverageReport.ps1` a:
   - **Windows:** `%LOCALAPPDATA%\CodeCoverageReport`
   - **Linux/macOS:** `~/.local/share/code-coverage-report`
5. Registra el comando `generateCodeCoverageReport`:
   - **Windows:** entrada persistente en el `PATH` del usuario y shim `generateCodeCoverageReport.cmd` para cmd.exe.
   - **Linux/macOS:** wrapper ejecutable en `~/.local/bin`.
6. Comprueba la `ExecutionPolicy` en Windows y ofrece soluciones **sin cambiarla sin permiso**.
7. Guarda un manifiesto para que `-Uninstall` pueda limpiar todo.

> **Nota:** si `~/.local/bin` o `%LOCALAPPDATA%\CodeCoverageReport` no estaban en el `PATH`, abre una terminal nueva después de instalar.

### Opciones del instalador

```powershell
# Instalar o actualizar
pwsh ./install.ps1

# Actualizar coverlet y ReportGenerator
pwsh ./install.ps1 -UpdateTools

# Instalar y crear el alias corto "ccr"
pwsh ./install.ps1 -Alias ccr

# Desinstalar
pwsh ./install.ps1 -Uninstall

# Desinstalar también las herramientas globales, sin preguntar
pwsh ./install.ps1 -Uninstall -UninstallTools
```

| Parámetro | Descripción |
|---|---|
| `-UpdateTools` | Actualiza las herramientas globales si ya existen; si no, las instala. |
| `-Alias <nombre>` | Registra además un alias corto, por ejemplo `ccr`. |
| `-Uninstall` | Elimina comandos, shims, alias, carpeta de instalación y entradas de `PATH` propias. |
| `-UninstallTools` | Junto con `-Uninstall`, desinstala las herramientas globales sin preguntar. |

> En Linux/macOS, `gcov` suele existir ya (forma parte de GCC). Usa otro alias, como `ccr` o `cov`.

### Windows: ExecutionPolicy

Si la política bloquea el script, el instalador lo detecta y ofrece:

```powershell
Unblock-File .\generateCodeCoverageReport.ps1
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

La segunda orden **solo se ejecuta si la aceptas explícitamente**.

---

## ⚡ Uso rápido

Desde la carpeta de tu solución:

```powershell
generateCodeCoverageReport
```

Salida típica:

```text
  ============================================================
   Cobertura de código .NET
   coverlet.console + ReportGenerator
  ============================================================

==> Comprobación de herramientas
    [OK] coverlet: /home/tu-usuario/.dotnet/tools/coverlet
    [OK] reportgenerator: /home/tu-usuario/.dotnet/tools/reportgenerator

==> Búsqueda de la solución
    [OK] Solución: /ruta/al/repo/MiApp.slnx

==> Detección de proyectos de test
    [OK] MiApp.Tests [net8.0]

==> Compilando la solución (Debug)
    [OK] Compilación completada.

==> Midiendo cobertura: MiApp.Tests [net8.0]
    [OK] Cobertura recogida: 001-MiApp.Tests-net8.0.cobertura.xml

==> Generando el reporte
    [OK] Reporte generado en /ruta/al/repo/coverage-report

  ------------------------------------------------------------
   Cobertura global
  ------------------------------------------------------------
   Líneas   : 82.40 % (412/500)
   Ramas    : 71.10 % (64/90)
   Métodos  : 78.90 % (30/38)
  ------------------------------------------------------------
```

---

## ⚙️ Parámetros

```powershell
Get-Help ./generateCodeCoverageReport.ps1 -Full
```

| Parámetro | Tipo | Defecto | Descripción |
|---|---|---|---|
| `-Solution` | `string` | autodetección | Ruta al `.sln`/`.slnx` o a la carpeta que lo contiene. |
| `-TestProject` | `string[]` | todos los de test | Uno o varios `.csproj` de test (o carpetas). Ignora la autodetección. |
| `-Output` | `string` | `<raíz solución>/coverage-report` | Carpeta de salida del reporte. |
| `-Configuration` | `string` | `Debug` | Configuración de compilación. |
| `-Framework` | `string` | todos | TFM concreto para proyectos multi-target. |
| `-Filter` | `string` | — | Filtro para `dotnet test --filter`. |
| `-Formats` | `string[]` | `Html, TextSummary, Cobertura` | Tipos de reporte de ReportGenerator. |
| `-Exclude` | `string[]` | `[*.Tests]*`, `[*.Test]*`, `[*.UnitTests]*`, `[*.IntegrationTests]*` | Filtros de exclusión de coverlet. |
| `-ExcludeByFile` | `string[]` | `**/Migrations/*.cs`, `**/*.g.cs`, `**/*.Designer.cs` | Archivos excluidos de la cobertura. |
| `-Threshold` | `int` | — | Cobertura mínima global (0–100). |
| `-ThresholdType` | `string` | `Line` | `Line`, `Branch` o `Method`. |
| `-NoBuild` | `switch` | — | No compila; usa una compilación previa. |
| `-NoOpen` | `switch` | — | No abre el navegador. |
| `-NoHistory` | `switch` | — | No guarda ni usa historial. |
| `-Force` | `switch` | — | Genera el reporte aunque fallen los tests. |
| `-KeepRaw` | `switch` | — | Conserva los XML intermedios en `<salida>/raw`. |

> `JsonSummary` se añade siempre internamente para calcular el resumen y el umbral globales. No se usa `--threshold` de coverlet porque se aplica por proyecto, no al total.

---

## 💡 Ejemplos

### Generar el reporte y abrirlo

```powershell
generateCodeCoverageReport
```

### CI: sin navegador, sin historial y con umbral

```powershell
generateCodeCoverageReport -NoOpen -NoHistory -Threshold 80 -ThresholdType Line
```

### Una solución concreta en Release

```powershell
generateCodeCoverageReport -Solution ./src/MiApp.sln -Configuration Release
```

### Solo un proyecto de test

```powershell
generateCodeCoverageReport -TestProject ./tests/MiApp.Tests/MiApp.Tests.csproj
```

### Filtrar tests

```powershell
generateCodeCoverageReport -Filter "FullyQualifiedName~Checkout"
```

### Un TFM concreto

```powershell
generateCodeCoverageReport -Framework net8.0
```

### Excluir más código

```powershell
generateCodeCoverageReport `
  -Exclude '[*.Legacy]*' `
  -ExcludeByFile '**/Generated/*.cs', '**/*.Generated.cs'
```

### Generar sin recompilar y conservar los XML

```powershell
generateCodeCoverageReport -NoBuild -KeepRaw
```

### Reporte solo de texto

```powershell
generateCodeCoverageReport -Formats TextSummary -NoOpen
```

---

## 🔄 Cómo funciona por dentro

```text
 1. Comprobar coverlet y reportgenerator
              │
 2. Buscar la solución (.sln / .slnx)
              │
 3. Detectar proyectos de test (IsTestProject / Test.Sdk)
              │
 4. Preparar la salida (conservar history, comprobar .gitignore)
              │
 5. dotnet build <solución> -c <configuración>
              │
 6. Por cada proyecto de test y TFM:
       coverlet <dll> --target dotnet \
         --targetargs "test <proj> --no-build -c <cfg>" \
         --format cobertura
              │
 7. reportgenerator -reports:<todos> -targetdir:<salida> \
       -historydir:<salida>/history
              │
 8. Leer Summary.json (líneas, ramas, métodos)
              │
 9. Umbral global + resumen en consola + abrir index.html
```

### Por qué `--no-build`

Coverlet instrumenta la DLL del proyecto de test (y los ensamblados de su carpeta de salida). Si `dotnet test` recompilara, sobrescribiría la DLL instrumentada y se perdería la cobertura. Por eso:

1. se compila la solución una vez;
2. coverlet instrumenta;
3. `dotnet test` se ejecuta con `--no-build`.

---

## 🚪 Códigos de salida

| Código | Significado |
|---|---|
| `0` | Éxito. |
| `1` | Error de configuración, de solución, de compilación o de herramientas. |
| `2` | Tests fallidos (sin `-Force`). |
| `3` | Umbral de cobertura no alcanzado. |

Con `-Force`, si los tests fallan pero el umbral se alcanza, el código es `0`. Si además falla el umbral, prevalece `3`.

---

## 🕘 Historial y `.gitignore`

ReportGenerator guarda el historial en:

```text
<salida>/history/
```

Se conserva entre ejecuciones para mostrar tendencias en el reporte HTML. Usa `-NoHistory` para no generarlo ni usarlo.

La primera vez, el script comprueba si la carpeta de salida está dentro de un repositorio git y no aparece en `.gitignore`; en ese caso muestra un aviso (no modifica el archivo). Añádela manualmente:

```gitignore
coverage-report/
```

> La carpeta de salida se limpia antes de cada ejecución, **excepto** `history`. Con `-KeepRaw`, los XML quedan en `<salida>/raw`, pero también se eliminan en la siguiente ejecución. Usa una carpeta dedicada: el script rechaza rutas que contengan la solución o el directorio actual para no borrar código fuente.

---

## 🤖 Integración en CI

### GitHub Actions

```yaml
name: Coverage

on: [push, pull_request]

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'

      - name: Generar cobertura
        shell: pwsh
        run: |
          ./install.ps1
          ./generateCodeCoverageReport.ps1 `
            -Solution ./MiApp.sln `
            -NoOpen -NoHistory -Threshold 80

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: coverage-report
          path: coverage-report/
```

### Azure DevOps

```yaml
- task: UseDotNet@2
  inputs:
    version: '8.x'

- task: PowerShell@2
  displayName: Instalar herramientas
  inputs:
    filePath: install.ps1
    pwsh: true

- task: PowerShell@2
  displayName: Cobertura
  inputs:
    filePath: generateCodeCoverageReport.ps1
    arguments: '-NoOpen -NoHistory -Threshold 80'
    pwsh: true
```

> En CI, invoca los scripts con `pwsh ./generateCodeCoverageReport.ps1` en lugar de depender del `PATH` de una terminal nueva.

---

## 🧹 Desinstalación

```powershell
pwsh ./install.ps1 -Uninstall
```

Elimina:

- el comando y el alias;
- los shims/wrappers;
- la carpeta de instalación;
- las entradas de `PATH` y de `.bashrc`/`.zshrc` que añadió el instalador.

Pregunta si quieres desinstalar también `coverlet.console` y `reportgenerator`; **por defecto no lo hace**.

```powershell
# Sin preguntar: conserva las herramientas
pwsh ./install.ps1 -Uninstall -UninstallTools:$false

# Sin preguntar: elimina también las herramientas
pwsh ./install.ps1 -Uninstall -UninstallTools
```

---

## 🩺 Solución de problemas

### `coverlet` o `reportgenerator` no se encuentran

1. Abre una terminal nueva (el `PATH` pudo cambiar).
2. Comprueba:

   ```bash
   dotnet tool list --global
   ```

3. Vuelve a ejecutar el instalador:

   ```powershell
   pwsh ./install.ps1
   ```

4. Verifica las rutas:
   - **Windows:** `%USERPROFILE%\.dotnet\tools`
   - **Linux/macOS:** `~/.dotnet/tools`

El script también busca las herramientas en esa carpeta aunque el `PATH` de la sesión esté desactualizado.

### El comando `generateCodeCoverageReport` no existe

- Abre una terminal nueva.
- Linux/macOS: comprueba que `~/.local/bin` está en el `PATH` y que el wrapper es ejecutable.
- Windows: comprueba el `PATH` del usuario y que existe `%LOCALAPPDATA%\CodeCoverageReport\generateCodeCoverageReport.cmd`.
- Ejecuta `pwsh ./install.ps1` de nuevo: es idempotente.

### Windows bloquea el script

```powershell
Unblock-File .\generateCodeCoverageReport.ps1
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### La cobertura sale al 0 %

- Comprueba que el proyecto de test referencia los proyectos de producción.
- No uses `-NoBuild` sin haber compilado esa configuración/TFM.
- Revisa `-Configuration` y `-Framework`.
- Revisa los `--exclude` y `--exclude-by-file`.
- Coverlet necesita PDBs; compila en `Debug` o genera símbolos en `Release`.
- Algunos escenarios (single-file, ReadyToRun, recortes agresivos) pueden no instrumentarse.

### Multi-target falla en un TFM

Se ejecuta una pasada por cada TFM. Cada uno necesita su **runtime** instalado, aunque el SDK sea más nuevo. Por ejemplo, un proyecto `net8.0;net10.0` requiere el runtime de .NET 8 y el de .NET 10. Usa `-Framework net10.0` para limitar la ejecución.

### `.slnx` no soportado

`dotnet sln list` necesita un SDK que entienda `.slnx` (**.NET SDK 9.0.200 o superior**). Si tu SDK no lo soporta, el script lo indica. Usa un `.sln` clásico o actualiza el SDK.

### Tests fallidos

El script no genera el reporte y sale con `2`. Corrige los tests o usa `-Force`:

```powershell
generateCodeCoverageReport -Force
```

### El umbral falla pero quiero el reporte igualmente

El reporte se genera **antes** de comprobar el umbral. El código `3` indica que el reporte existe pero la cobertura no llega al mínimo.

### No se abre el navegador

- En Linux sin entorno gráfico no hay navegador que abrir. Usa `-NoOpen` y publica `coverage-report/` como artefacto.
- En WSL se usa `wslview` si está disponible; si no, `xdg-open`.
- La ruta del reporte se imprime siempre al terminar.

### No se encontró la DLL del proyecto de test

Compila primero o revisa `-Configuration`/`-Framework`. Con `-NoBuild` se asume que la DLL ya existe.

### ReportGenerator no genera `Summary.json`

Actualiza las herramientas:

```powershell
pwsh ./install.ps1 -UpdateTools
```

---

## 📁 Estructura del repositorio

```text
DotnetReportGenerator/
├── install.ps1                        # Instalador y desinstalador
├── generateCodeCoverageReport.ps1     # Script principal
└── README.md
```

---

## ⚠️ Suposiciones y limitaciones

- **Modelo de instrumentación:** `coverlet.console` instrumenta la DLL del proyecto de test y los ensamblados de su carpeta de salida. Es el modelo estándar cuando los proyectos de producción se referencian con `ProjectReference`.
- **Detección de tests:** se basa en `IsTestProject`, `Microsoft.NET.Test.Sdk` o `MSTest.Sdk`. Frameworks personalizados pueden requerir `-TestProject`.
- **Microsoft.Testing.Platform:** proyectos configurados con MTP (por ejemplo, algunas configuraciones de xUnit v3) pueden no ser compatibles con el envolvimiento de `dotnet test` que hace `coverlet.console`. En ese caso, usa el runner de VSTest o `dotnet-coverage`.
- **Umbral global:** es único para todo el reporte. No hay umbrales por proyecto ni por clase.
- **Métodos:** `methodcoverage` depende del parser de ReportGenerator. Si no hay datos, se muestra `N/D` y el umbral de métodos lo trata como 0 %.
- **Un solo nivel de solución:** no se recorren soluciones anidadas; se elige una y se miden sus proyectos.
- **Limpieza de salida:** se borra todo excepto `history`. Usa siempre una carpeta dedicada para `-Output`.
- **Códigos de coverlet:** `1`/`3` se interpretan como tests fallidos; `101` u otros se tratan como error de herramienta.
- **Plataformas:** el flujo completo se ha validado en Linux. Windows y macOS usan APIs estándar de PowerShell/.NET (`SetEnvironmentVariable`, `Start-Process`, `open`, `xdg-open`), pero conviene ejecutar `install.ps1` una vez en cada sistema para validar shims y políticas.
- **Idioma:** los mensajes de usuario están en español; el código, nombres de funciones y comentarios están en inglés.

---

## 📄 Licencia

Este repositorio no incluye actualmente un archivo de licencia. Añade el que corresponda antes de distribuirlo.
