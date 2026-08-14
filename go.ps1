[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$ProjectName,

    [Parameter(Mandatory, Position = 1)]
    [ValidateRange(2, 32768)]
    [int]$VideoWidth,

    [Parameter(Mandatory, Position = 2)]
    [ValidateRange(2, 32768)]
    [int]$VideoHeight,

    [Parameter(Mandatory, Position = 3)]
    [ValidateRange(1, 1000)]
    [int]$Framerate,

    [Alias('s')]
    [switch]$SmoketestOnly,

    [Alias('n')]
    [switch]$SkipSmoketest,

    [Alias('h')]
    [switch]$AudioHints,

    [Alias('x')]
    [switch]$AudioSfx,

    [Alias('c')]
    [ValidateSet('CUDA', 'HIP')]
    [string]$ComputeLang = 'CUDA',

    [Alias('q')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build'
$activeProject = Join-Path $repoRoot 'src\Projects\.active_project.cpp'
$sampleRate = 48000
$result = 0
$outputDir = $null

function Find-VcVars64 {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $found = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Auxiliary\Build\vcvars64.bat' | Select-Object -First 1
        if ($found) { return $found.Trim() }
    }
    throw 'Unable to locate vcvars64.bat. Install Visual Studio 2022 with the C++ workload.'
}

function Get-FileIdentity([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        Path = $item.FullName
        Length = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.Ticks
    }
}

function Get-DirectoryState([string[]]$Paths) {
    $state = @()
    foreach ($path in $Paths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $state += Get-ChildItem -LiteralPath $path -Directory | ForEach-Object {
            [ordered]@{ Name = $_.FullName; LastWriteTimeUtc = $_.LastWriteTimeUtc.Ticks }
        }
    }
    return @($state | Sort-Object -Property Name)
}

function Get-FileSha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $hasher.Dispose()
    }
}

function Read-JsonCache([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-StateEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return (($Left | ConvertTo-Json -Depth 20 -Compress) -eq
            ($Right | ConvertTo-Json -Depth 20 -Compress))
}

function Write-JsonCache([string]$Path, $Value) {
    try {
        $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } catch {
        if ($temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Import-VcVars64([string]$VcVarsPath) {
    # Run vcvars64.bat in a child with a deliberately small environment. A
    # developer shell can retain enough stale VS variables to exceed cmd.exe's
    # 8191-character input-line limit even after PATH itself is shortened.
    $originalPath = $env:PATH

    $canonicalVcVars = (Get-Item -LiteralPath $VcVarsPath).FullName
    $vcRoot = Split-Path (Split-Path (Split-Path $canonicalVcVars -Parent) -Parent) -Parent
    $toolchainRoots = @(
        (Join-Path $vcRoot 'Tools\MSVC'),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Include",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Lib",
        "$env:ProgramFiles\Windows Kits\10\Include",
        "$env:ProgramFiles\Windows Kits\10\Lib"
    )
    $currentKey = [ordered]@{
        SchemaVersion = 2
        VcVars = Get-FileIdentity $canonicalVcVars
        ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        ToolchainDirectories = Get-DirectoryState $toolchainRoots
    }
    $cachePath = Join-Path $buildDir 'vcvars-cache.json'
    $cachedData = Read-JsonCache $cachePath

    if ($cachedData -and (Test-StateEqual $cachedData.Metadata $currentKey) -and $cachedData.Environment.PATH) {
        # Restore environment variables
        foreach ($prop in $cachedData.Environment.PSObject.Properties) {
            if ($prop.Name -ne 'PATH') {
                [Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, 'Process')
            }
        }

        $vcPath = $cachedData.Environment.PATH
        $callerPath = @($originalPath -split ';') |
            Where-Object { $_ -and $_ -notmatch '(?i)\\Microsoft Visual Studio\\|\\Windows Kits\\' }
        $mergedPath = @(($vcPath -split ';') + $callerPath) |
            Where-Object { $_ } |
            Select-Object -Unique
        $env:PATH = $mergedPath -join ';'
        return
    }

    $minimalPath = @(
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    ) -join ';'

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = "/d /s /c `"`"$VcVarsPath`" >nul && set`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.EnvironmentVariables.Clear()

    $baselineNames = @(
        'SystemRoot', 'windir', 'SystemDrive', 'ComSpec', 'TEMP', 'TMP',
        'USERPROFILE', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)',
        'CommonProgramFiles', 'CommonProgramFiles(x86)', 'OS', 'PATHEXT',
        'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS'
    )
    foreach ($name in $baselineNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) {
            $startInfo.EnvironmentVariables[$name] = $value
        }
    }
    $startInfo.EnvironmentVariables['PATH'] = $minimalPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start isolated vcvars64.bat process.' }
    $environmentText = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $vcVarsExitCode = $process.ExitCode
    $process.Dispose()
    if ($vcVarsExitCode -ne 0) {
        throw "vcvars64.bat failed with exit code $vcVarsExitCode."
    }

    $vcPath = $null
    $envToCache = [ordered]@{}
    $environmentLines = $environmentText -split '\r?\n'
    foreach ($line in $environmentLines) {
        if ($line -match '^([^=][^=]*)=(.*)$') {
            $name = $matches[1]
            $value = $matches[2]
            if ($name -ieq 'PATH') {
                $vcPath = $value
                $envToCache['PATH'] = $value
            } else {
                if ($baselineNames -notcontains $name) {
                    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
                    $envToCache[$name] = $value
                }
            }
        }
    }
    if (-not $vcPath) { throw 'vcvars64.bat did not return a PATH variable.' }

    Write-JsonCache $cachePath ([ordered]@{
            Metadata = $currentKey
            Environment = $envToCache
        })

    $callerPath = @($originalPath -split ';') |
        Where-Object { $_ -and $_ -notmatch '(?i)\\Microsoft Visual Studio\\|\\Windows Kits\\' }
    $mergedPath = @(($vcPath -split ';') + $callerPath) |
        Where-Object { $_ } |
        Select-Object -Unique
    $env:PATH = $mergedPath -join ';'
}

function Find-Msys2Root {
    $userProfilePath = [Environment]::GetFolderPath('UserProfile')
    $candidates = @(
        'C:\msys64',
        (Join-Path $userProfilePath 'scoop\apps\msys2\current')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'mingw64\include\glib-2.0\glib.h') -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Assert-Msys2PackageLock([string]$Msys2Root) {
    $lockPath = Join-Path $repoRoot 'windows-msys2.lock'
    $pacman = Join-Path $Msys2Root 'usr\bin\pacman.exe'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "Missing Windows dependency lock file: $lockPath"
    }
    if (-not (Test-Path -LiteralPath $pacman -PathType Leaf)) {
        throw "Unable to verify MSYS2 dependency versions because pacman.exe was not found at $pacman"
    }

    $dbDir = Join-Path $Msys2Root 'var\lib\pacman\local'
    if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) {
        throw "MSYS2 package database was not found at $dbDir"
    }
    $currentMsysKey = [ordered]@{
        SchemaVersion = 2
        Msys2Root = (Get-Item -LiteralPath $Msys2Root).FullName
        LockHash = Get-FileSha256 $lockPath
        Pacman = Get-FileIdentity $pacman
        PackageDatabase = Get-DirectoryState @($dbDir)
    }

    $msysCachePath = Join-Path $buildDir 'msys-validation-cache.json'
    $cachedMsysKey = Read-JsonCache $msysCachePath
    if (Test-StateEqual $cachedMsysKey $currentMsysKey) { return }

    # If cache not valid, perform verification calling pacman -Q only once
    $pacmanOutput = & $pacman -Q 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $pacmanOutput) {
        throw "Failed to query installed MSYS2 packages using pacman."
    }

    $installedLookup = @{}
    foreach ($line in $pacmanOutput) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $parts = $trimmed -split '\s+'
        if ($parts.Count -ge 2) {
            $installedLookup[$parts[0]] = $parts[1]
        }
    }

    $mismatches = @()
    foreach ($line in Get-Content -LiteralPath $lockPath) {
        $entry = $line.Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        $parts = $entry -split '\s+'
        if ($parts.Count -ne 2) { throw "Invalid entry in ${lockPath}: $entry" }

        $packageName = $parts[0]
        $requiredVersion = $parts[1]

        if (-not $installedLookup.ContainsKey($packageName)) {
            $mismatches += "${packageName}: required $requiredVersion, not installed"
        } else {
            $installedVersion = $installedLookup[$packageName]
            if ($installedVersion -ne $requiredVersion) {
                $mismatches += "${packageName}: required $requiredVersion, found $installedVersion"
            }
        }
    }

    if ($mismatches.Count -gt 0) {
        throw "MSYS2 dependency versions do not match windows-msys2.lock:`n  $($mismatches -join "`n  ")`nSee WINDOWS.md for the exact installation command."
    }

    Write-JsonCache $msysCachePath $currentMsysKey
}

function Find-FfmpegRoot {
    $userProfilePath = [Environment]::GetFolderPath('UserProfile')
    $candidates = @()
    $chocoRoot = 'C:\ProgramData\chocolatey\lib\ffmpeg-shared\tools'
    if (Test-Path -LiteralPath $chocoRoot -PathType Container) {
        $candidates += Get-ChildItem -LiteralPath $chocoRoot -Directory | ForEach-Object FullName
    }
    $candidates += Join-Path $userProfilePath 'scoop\apps\ffmpeg-shared\current'
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'include\libavcodec\avcodec.h') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'lib\avcodec.lib') -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

function Find-MicroTex {
    $parent = Split-Path -Parent $repoRoot
    $candidates = @(
        (Join-Path $parent 'MicroTeX-master\build\LaTeX.exe'),
        (Join-Path $parent 'MicroTeX-master\build\LaTeX'),
        (Join-Path $parent 'MicroTeX-master\build-mingw-headless\LaTeX.exe')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Get-Item -LiteralPath $candidate).Length -gt 0) {
            return $candidate
        }
    }
    throw 'A MicroTeX LaTeX executable was not found beside this repository. See README.md.'
}

function Invoke-Native([scriptblock]$Command, [int]$FailureCode, [string]$Description, [switch]$Interactive) {
    # Windows PowerShell 5.1 wraps native stderr lines as ErrorRecord objects.
    # FFmpeg uses stderr for routine diagnostics, so never let the PowerShell
    # error preference override the native process exit code.
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet -and -not $Interactive) {
            & $Command *> $null
        } else {
            & $Command
        }
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($nativeExitCode -ne 0) {
        throw [System.ComponentModel.Win32Exception]::new($FailureCode, "$Description failed with exit code $nativeExitCode.")
    }
}

if (($VideoWidth % 2) -ne 0 -or ($VideoHeight % 2) -ne 0) {
    throw 'Video width and height must be even for 4:2:0 encoding.'
}
if ($SmoketestOnly -and $SkipSmoketest) {
    throw '-SmoketestOnly (-s) and -SkipSmoketest (-n) cannot be used together.'
}
if ($Quiet) {
    $env:SWAPTUBE_QUIET = '1'
} else {
    Remove-Item Env:SWAPTUBE_QUIET -ErrorAction SilentlyContinue
}

Set-Location $repoRoot
$projectMatches = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\Projects') -Recurse -File -Filter "$ProjectName.cpp")
if ($projectMatches.Count -eq 0) { throw "Project '$ProjectName' does not exist." }
if ($projectMatches.Count -gt 1) { throw "Project '$ProjectName' is ambiguous; multiple matching source files exist." }

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
$outputDir = Join-Path $repoRoot "out\$ProjectName\$timestamp"
$inputDir = Join-Path $repoRoot "media\$ProjectName"
$ioIn = Join-Path $buildDir 'io_in'
$ioOut = Join-Path $buildDir 'io_out'
$temporaryProjectCopied = $false

New-Item -ItemType Directory -Force -Path (Join-Path $outputDir 'frames'), (Join-Path $inputDir 'latex'), $buildDir | Out-Null
Copy-Item -LiteralPath $projectMatches[0].FullName -Destination $activeProject -Force
[System.IO.File]::SetLastWriteTimeUtc($activeProject, [DateTime]::UtcNow)
$temporaryProjectCopied = $true

try {
    $null = Find-MicroTex
    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
    $ninjaCommand = Get-Command ninja -ErrorAction SilentlyContinue
    if (-not $cmakeCommand) { throw "Required command 'cmake' was not found in the caller's PATH." }
    if (-not $ninjaCommand) { throw "Required command 'ninja' was not found in the caller's PATH." }
    $cmakeExecutable = $cmakeCommand.Source
    $ninjaExecutable = $ninjaCommand.Source
    $cmakeVersion = ((& $cmakeExecutable --version | Select-Object -First 1) -replace '^cmake version\s+', '').Trim()
    $ninjaVersion = ((& $ninjaExecutable --version | Select-Object -First 1)).Trim()

    $vcVars = Find-VcVars64
    Import-VcVars64 $vcVars

    $cxxCompiler = (Get-Command cl.exe -ErrorAction Stop).Source
    $cmakeArgs = @('-G', 'Ninja', '..', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_CXX_COMPILER=$cxxCompiler", "-DCMAKE_MAKE_PROGRAM=$ninjaExecutable", "-DCOMPUTE_LANG=$ComputeLang")
    $msys2Root = Find-Msys2Root
    if ($msys2Root) {
        Assert-Msys2PackageLock $msys2Root
        $cmakeArgs += "-DMSYS2_ROOT=$msys2Root"
        $env:PATH = "$(Join-Path $msys2Root 'mingw64\bin');$env:PATH"
    }
    $ffmpegRoot = Find-FfmpegRoot
    if ($ffmpegRoot) {
        $cmakeArgs += "-DFFMPEG_ROOT=$ffmpegRoot"
        $env:PATH = "$(Join-Path $ffmpegRoot 'bin');$env:PATH"
    }

    $configurationFiles = @()
    foreach ($name in @('CMakeLists.txt', 'local.cmake', 'local_override.cmake')) {
        $path = Join-Path $repoRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $identity = Get-FileIdentity $path
            $identity['Sha256'] = Get-FileSha256 $path
            $configurationFiles += $identity
        }
    }
    $computeCompilerName = if ($ComputeLang -eq 'HIP') { 'hipcc.exe' } else { 'nvcc.exe' }
    $computeCompilerCommand = Get-Command $computeCompilerName -ErrorAction SilentlyContinue
    $computeCompilerIdentity = if ($computeCompilerCommand) { Get-FileIdentity $computeCompilerCommand.Source } else { $null }
    $configurationState = [ordered]@{
        SchemaVersion = 2
        CMake = Get-FileIdentity $cmakeExecutable
        CMakeVersion = $cmakeVersion
        Ninja = Get-FileIdentity $ninjaExecutable
        NinjaVersion = $ninjaVersion
        CxxCompiler = Get-FileIdentity $cxxCompiler
        ComputeCompiler = $computeCompilerIdentity
        Arguments = @($cmakeArgs)
        ConfigurationFiles = $configurationFiles
    }

    Remove-Item -LiteralPath $ioIn, $ioOut -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $ioIn, (Join-Path $ioOut 'frames') | Out-Null
    Copy-Item -Path (Join-Path $inputDir '*') -Destination $ioIn -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "go.ps1: Building $ProjectName with MSVC; output is $outputDir"
    Push-Location $buildDir
    try {
        $buildNinja = Join-Path $buildDir 'build.ninja'
        $configurationStatePath = Join-Path $buildDir 'swaptube-configure-state.json'
        $savedConfigurationState = Read-JsonCache $configurationStatePath
        $needsConfigure = -not (Test-Path -LiteralPath $buildNinja -PathType Leaf) -or
            -not (Test-StateEqual $savedConfigurationState $configurationState)
        if ($needsConfigure) {
            Write-Host 'go.ps1: Configuration inputs changed; refreshing CMake configuration.'
            Invoke-Native { & $cmakeExecutable @cmakeArgs } 1 'CMake configuration'
            Write-JsonCache $configurationStatePath $configurationState
        }
        $jobs = [Environment]::ProcessorCount
        Invoke-Native { & $ninjaExecutable "-j$jobs" } 1 'Compilation'

        $audioHintsValue = [int]$AudioHints.IsPresent
        $audioSfxValue = [int]$AudioSfx.IsPresent
        if (-not $SkipSmoketest) {
            Invoke-Native { & .\swaptube.exe 160 90 $Framerate $sampleRate smoketest $audioHintsValue $audioSfxValue } 2 'Smoketest'
        }
        if (-not $SmoketestOnly) {
            Remove-Item -Path (Join-Path $ioOut '*') -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path (Join-Path $ioOut 'frames') | Out-Null
            Invoke-Native { & .\swaptube.exe $VideoWidth $VideoHeight $Framerate $sampleRate render $audioHintsValue $audioSfxValue } 2 'Render' -Interactive:($ProjectName -eq 'UIDemo')
        }
    } finally {
        Pop-Location
    }
} catch [System.ComponentModel.Win32Exception] {
    $result = $_.Exception.NativeErrorCode
    [Console]::Error.WriteLine("go.ps1: $($_.Exception.Message)")
} catch {
    $result = 1
    [Console]::Error.WriteLine("go.ps1: $($_.Exception.Message)")
} finally {
    if ($outputDir -and (Test-Path -LiteralPath $ioOut -PathType Container)) {
        Copy-Item -Path (Join-Path $ioOut '*') -Destination $outputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $ioIn, $ioOut -Recurse -Force -ErrorAction SilentlyContinue
    if ($temporaryProjectCopied -and (Test-Path -LiteralPath $activeProject -PathType Leaf)) {
        Move-Item -LiteralPath $activeProject -Destination $outputDir -Force
    }
}

if ($result -eq 0 -and -not $SmoketestOnly) {
    & (Join-Path $repoRoot 'play.ps1') -ProjectName $ProjectName
}
exit $result
