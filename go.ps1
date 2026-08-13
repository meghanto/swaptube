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

function Import-VcVars64([string]$VcVarsPath) {
    # Run vcvars64.bat in a child with a deliberately small environment. A
    # developer shell can retain enough stale VS variables to exceed cmd.exe's
    # 8191-character input-line limit even after PATH itself is shortened.
    $originalPath = $env:PATH
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
    $environmentLines = $environmentText -split '\r?\n'
    foreach ($line in $environmentLines) {
        if ($line -match '^([^=][^=]*)=(.*)$') {
            if ($matches[1] -ieq 'PATH') {
                $vcPath = $matches[2]
            } else {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
            }
        }
    }
    if (-not $vcPath) { throw 'vcvars64.bat did not return a PATH variable.' }

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

    $vcVars = Find-VcVars64
    Import-VcVars64 $vcVars

    $cmakeArgs = @('-G', 'Ninja', '..', '-DCMAKE_BUILD_TYPE=Release', "-DCOMPUTE_LANG=$ComputeLang")
    $msys2Root = Find-Msys2Root
    if ($msys2Root) {
        $cmakeArgs += "-DMSYS2_ROOT=$msys2Root"
        $env:PATH = "$(Join-Path $msys2Root 'mingw64\bin');$env:PATH"
    }
    $ffmpegRoot = Find-FfmpegRoot
    if ($ffmpegRoot) {
        $cmakeArgs += "-DFFMPEG_ROOT=$ffmpegRoot"
        $env:PATH = "$(Join-Path $ffmpegRoot 'bin');$env:PATH"
    }

    Remove-Item -LiteralPath $ioIn, $ioOut -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $ioIn, (Join-Path $ioOut 'frames') | Out-Null
    Copy-Item -Path (Join-Path $inputDir '*') -Destination $ioIn -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "go.ps1: Building $ProjectName with MSVC; output is $outputDir"
    Push-Location $buildDir
    try {
        Invoke-Native { & $cmakeExecutable @cmakeArgs } 1 'CMake configuration'
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
