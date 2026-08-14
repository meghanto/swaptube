# Building and running SwapTube on Windows

This fork has a native Windows workflow. Run it from a normal **64-bit
PowerShell** window; Git Bash, WSL, and a manually opened Visual Studio
Developer Prompt are not required.

The supported and tested configuration is:

- 64-bit Windows 10 or 11
- an NVIDIA GPU and the CUDA compute backend
- Visual Studio 2022 Build Tools (MSVC)
- CMake and Ninja
- shared FFmpeg development files
- GLib, Cairo, librsvg, GdkPixbuf, and libpng from MSYS2
- MicroTeX, built in a sibling directory next to the SwapTube checkout

SwapTube compiles CUDA code and renders on the GPU. A CPU-only Windows build is
not currently supported. The PowerShell script accepts `-c HIP`, but the native
Windows HIP path is not part of the tested setup described here.

## 1. Install Visual Studio 2022 Build Tools

Download either [Visual Studio 2022 Community or Build
Tools](https://visualstudio.microsoft.com/downloads/). In the Visual Studio
Installer, select **Desktop development with C++**. Keep these included
components selected:

- MSVC v143 x64/x86 build tools
- a Windows 10 or Windows 11 SDK
- C++ CMake tools for Windows

`go.ps1` discovers Visual Studio/MSVC in the standard installation locations or
through `vswhere.exe`. It runs `vcvars64.bat` in an isolated child process to
avoid `cmd.exe`'s input-length limit, then caches the validated result in
`build\vcvars-cache.json`.

After a successful run, the validated MSVC environment remains available in
the current PowerShell process for faster consecutive builds. If initialization
or any later step fails, `go.ps1` restores the process environment and working
directory to their exact pre-run values.

## 2. Install the NVIDIA driver and CUDA Toolkit

The machine needs a [CUDA-capable NVIDIA
GPU](https://developer.nvidia.com/cuda-gpus). Install a current NVIDIA driver,
then download and install the [CUDA Toolkit for
Windows](https://developer.nvidia.com/cuda-downloads). NVIDIA's full procedure
is in the [CUDA Installation Guide for Microsoft
Windows](https://docs.nvidia.com/cuda/cuda-installation-guide-microsoft-windows/).

Use a CUDA Toolkit version that supports both your installed Visual Studio
toolset and your GPU. CUDA 13 no longer targets compute capabilities below 6.0;
older Maxwell GPUs may therefore require CUDA 12.x.

Open a new PowerShell window and verify the installation:

```powershell
nvidia-smi
nvcc --version
```

### Adaptive CUDA architecture selection

By default, `go.ps1` and `CMakeLists.txt` use adaptive CUDA architecture
selection: `CMAKE_CUDA_ARCHITECTURES` is set to `native`, which automatically
queries the host machine's active NVIDIA GPU during configuration and targets
its specific compute capability.

If you need to cross-compile or override this automatic detection (for instance,
to target a different GPU architecture or to bypass native query issues), create
a `local.cmake` file in the SwapTube root folder and specify the target
capability:

```cmake
set(CMAKE_CUDA_ARCHITECTURES 75 CACHE STRING "CUDA compute capability" FORCE)
```

Then rerun `go.ps1`. Delete or comment out this entry in `local.cmake` to
return to automatic, adaptive GPU architecture selection.

## 3. Install Git, CMake, Ninja, and shared FFmpeg

SwapTube requires Git, CMake 3.24 or newer, and Ninja to be installed by the
caller and available in `PATH`. The build script uses those CMake and Ninja
executables and stops if either is missing.

A shared FFmpeg build is required, including headers, import libraries such as
`avcodec.lib`, and runtime DLLs. `go.ps1` searches the standard Chocolatey and
Scoop layouts for `ffmpeg-shared`. For another layout, set the `FFMPEG_ROOT`
CMake cache variable in `local.cmake`.

Both [Chocolatey](https://chocolatey.org/install) and
[Scoop](https://scoop.sh/) can install these packages. With Chocolatey, run in
an Administrator PowerShell window:

```powershell
choco install git cmake ninja ffmpeg-shared -y
```

With Scoop, run in a normal PowerShell window:

```powershell
scoop install git cmake ninja ffmpeg-shared
```

Close and reopen PowerShell, then verify the caller-installed tools:

```powershell
git --version
cmake --version
ninja --version
ffmpeg -version
```

## 4. Install the graphics libraries with MSYS2

Install [MSYS2](https://www.msys2.org/) using its official installer in the
default location, `C:\msys64`, or install it with Scoop:

```powershell
scoop install msys2
```

`go.ps1` recognizes both `C:\msys64` and Scoop's
`%USERPROFILE%\scoop\apps\msys2\current` layout. Open **MSYS2 MSYS** from the
Start menu, or launch the Scoop-installed MSYS2 shell, and fully update it:

```bash
pacman -Syu
```

If MSYS2 asks you to close the terminal, reopen **MSYS2 MSYS** and run
`pacman -Syu` again. Then install the 64-bit MinGW libraries and the tools used
to build MicroTeX:

```bash
pacman -S --needed \
  mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-cairo \
  mingw-w64-x86_64-librsvg \
  mingw-w64-x86_64-gdk-pixbuf2 \
  mingw-w64-x86_64-libpng
```

SwapTube records the graphics/runtime versions validated by the native Windows
build in `windows-msys2.lock`. Because MSYS2 is a rolling distribution,
`go.ps1` checks the installed packages against that file and stops on a version
mismatch.

The lock does not limit CPU speed or NVIDIA GPU capability. Its packages are
x86-64 DLLs, so newer x86-64 Windows CPUs do not require different MSYS2
packages, while CUDA architecture selection is handled separately through
`CMAKE_CUDA_ARCHITECTURES=native`.
The practical limitation is software availability: fresh MSYS2 installations
may need the historical package archive to obtain the exact versions. MSYS2 has
also deprecated the MINGW64 environment used by this workflow, so these pins
are a reproducible compatibility lane, not a permanent substitute for testing
newer UCRT64 packages.

Native Windows ARM64 is not supported by this workflow. It currently uses
`vcvars64.bat`, the `mingw64` prefix, and `mingw-w64-x86_64-*` packages. MSYS2's
preliminary CLANGARM64 environment would require a separate port and lock file.

To install the exact locked packages from MSYS2's official archive, run this
from **MSYS2 MSYS** in the SwapTube directory:

```bash
mapfile -t locked_packages < <(
  awk '!/^#/ && NF == 2 {
    printf "https://repo.msys2.org/mingw/mingw64/%s-%s-any.pkg.tar.zst\n", $1, $2
  }' windows-msys2.lock
)
pacman -U --needed "${locked_packages[@]}"
```

Do not run `pacman -Syu` afterward without also updating and validating the
lock file; doing so may replace the locked packages with newer rolling builds.

`go.ps1` detects the selected MSYS2 installation and supplies its `mingw64`
prefix to CMake. Do not add the general MSYS2 include directory to MSVC
manually.

## 5. Clone and build MicroTeX

MicroTeX is required even when the selected demo does not visibly use LaTeX,
because `go.ps1` validates it before configuring SwapTube. "Built beside" means
that the `swaptube` and `MicroTeX-master` directories must have the same parent
directory. MicroTeX does **not** go inside the SwapTube directory. SwapTube uses
the relative path `..\MicroTeX-master` to find it. For example:

```text
C:\Projects\
|-- swaptube\
`-- MicroTeX-master\
```

Here, `C:\Projects` is an example shared parent directory. The exact parent path
and the SwapTube directory name may differ, but the MicroTeX directory must be
named `MicroTeX-master` and remain directly next to the SwapTube directory.

From PowerShell, clone it with the directory name expected by SwapTube:

```powershell
Set-Location C:\Projects
git clone https://github.com/NanoMichael/MicroTeX.git MicroTeX-master
```

Open **MSYS2 MinGW x64** from the Start menu and build MicroTeX. Adjust
`/c/Projects` if the repositories are elsewhere:

```bash
cd /c/Projects/MicroTeX-master
cmake -S . -B build-mingw-headless -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-mingw-headless --parallel
```

Confirm that this file now exists:

```text
C:\Projects\MicroTeX-master\build-mingw-headless\LaTeX.exe
```

SwapTube also recognizes `MicroTeX-master\build\LaTeX.exe`.

## 6. Clone and render SwapTube

In a normal PowerShell window:

```powershell
Set-Location C:\Projects
git clone https://github.com/meghanto/swaptube.git swaptube
Set-Location .\swaptube
Set-ExecutionPolicy -Scope Process Bypass
```

First run a small smoketest. After compiling, SwapTube performs a fast
count-only planning pass and then renders one test frame per discovered
microblock:

```powershell
.\go.ps1 MandelbrotDemo 640 360 30 -s -c CUDA
```

Then render the demo:

```powershell
.\go.ps1 MandelbrotDemo 640 360 30 -n -c CUDA -q
```

The arguments are project name, even video width, even video height, and frame
rate. `go.ps1` finds the project below `src\Projects`, configures CMake with
Ninja and MSVC, builds on all CPU cores, runs SwapTube, and opens the completed
video.

Useful switches:

- `-s`: run planning and the smoketest, but skip the full render
- `-n`: skip the smoketest and perform planning followed by the full render
- `-q`: suppress noninteractive CMake, Ninja, and SwapTube console output, and
  disable periodic terminal frame previews; interactive `UIDemo` output remains
  visible
- `-h`: enable audio hints
- `-x`: enable sound effects
- `-c CUDA`: select the NVIDIA CUDA backend

Do not combine `-s` and `-n`.

Rendered files are written to:

```text
out\<ProjectName>\<yyyy-MM-dd_HH.mm.ss>\
```

The separate `record_audios.py` voice-recording helper currently depends on
Linux ALSA and is not supported on Windows. This does not prevent building,
smoketesting, rendering, or playing projects whose required audio assets are
already present.

To replay the newest render later:

```powershell
.\play.ps1 MandelbrotDemo
```

`play.ps1` prefers VLC or mpv when installed, otherwise it opens the video with
the Windows default file association. A specific player may be supplied as the
second argument:

```powershell
.\play.ps1 MandelbrotDemo "C:\Program Files\VideoLAN\VLC\vlc.exe"
```

## Troubleshooting

### A required command was not found

Open a new PowerShell window after installing or upgrading tools. Check
`cmake --version`, `ninja --version`, `nvcc --version`, and `ffmpeg -version`.
You do not need to launch PowerShell through Git Bash or a Visual Studio prompt.

### Required Windows dependencies were not found

Confirm that the selected MSYS2 installation contains
`mingw64\include\glib-2.0\glib.h`, and that the Chocolatey or Scoop
`ffmpeg-shared` directory contains both `include\libavcodec\avcodec.h` and
`lib\avcodec.lib`. A static-only or executable-only FFmpeg package is not
sufficient.

### MicroTeX was not found

The checkout must be named `MicroTeX-master` and must be beside SwapTube, not
inside it. Rebuild it and confirm that `LaTeX.exe` is in one of the two paths
listed above.

### Playback hangs or reports a WASAPI endpoint error

This commonly occurs when `ffplay` runs in a remote or noninteractive session.
Use `play.ps1`, VLC, mpv, or open the generated video directly. Rendering does
not require an active audio playback endpoint.

### Windows runtime stderr suppression and diagnostics

Like upstream `go.sh`, `go.ps1` redirects only the SwapTube executable's runtime
stderr to `$null` during smoketests and renders. This hides FFmpeg's verbose
Matroska diagnostics. CMake and Ninja diagnostics remain visible unless `-q` is
used. Runtime failures still return a nonzero exit code and produce the
wrapper's concise failure message, but their detailed stderr is intentionally
hidden for upstream parity.
