#!/bin/bash

clear
check_command_available() {
    command -v "$1" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "go.sh: Error - Required command '$1' is not found. Please install it and try again."
        echo "go.sh: A list of all software dependencies can be found in README.md."
        exit 1
    fi
}

find_microtex_binary() {
    local candidates=(
        "../MicroTeX-master/build/LaTeX"
        "../MicroTeX-master/build/LaTeX.exe"
        "../MicroTeX-master/build-mingw-headless/LaTeX.exe"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -s "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

find_windows_vcvars64() {
    local candidates=(
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat"
        "/c/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat"
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat"
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/Professional/VC/Auxiliary/Build/vcvars64.bat"
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/Enterprise/VC/Auxiliary/Build/vcvars64.bat"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            cygpath -w "$c"
            return 0
        fi
    done

    if [ -f "/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" ]; then
        powershell.exe -NoProfile -Command "& '${env:ProgramFiles(x86)}\\Microsoft Visual Studio\\Installer\\vswhere.exe' -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\\Auxiliary\\Build\\vcvars64.bat'" | tr -d '\r' | head -n 1
        return 0
    fi
    return 1
}

find_windows_msys2_root() {
    local candidates=(
        "/c/msys64"
        "$HOME/scoop/apps/msys2/current"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c/mingw64/include/glib-2.0/glib.h" ]; then
            cygpath -m "$c"
            return 0
        fi
    done
    return 1
}

verify_windows_msys2_lock() {
    local msys2_root="$1"
    local lock_file="../windows-msys2.lock"
    local pacman_exe="${msys2_root}/usr/bin/pacman.exe"
    local package version installed_version
    local failed=0

    if [ ! -f "$lock_file" ] || [ ! -x "$pacman_exe" ]; then
        echo "go.sh: Unable to verify windows-msys2.lock."
        return 1
    fi
    while read -r package version; do
        [ -z "$package" ] && continue
        case "$package" in \#*) continue ;; esac
        installed_version="$($pacman_exe -Q "$package" 2>/dev/null | awk '{print $2}')"
        if [ "$installed_version" != "$version" ]; then
            echo "go.sh: $package requires $version, found ${installed_version:-not-installed}."
            failed=1
        fi
    done < "$lock_file"
    return $failed
}

find_windows_ffmpeg_root() {
    local c
    for c in /c/ProgramData/chocolatey/lib/ffmpeg-shared/tools/* "$HOME/scoop/apps/ffmpeg-shared/current"; do
        [ -d "$c" ] || continue
        if [ -f "$c/include/libavcodec/avcodec.h" ] && [ -f "$c/lib/avcodec.lib" ]; then
            cygpath -m "$c"
            return 0
        fi
    done
    return 1
}

run_windows_batch_file() {
    local runner_bat="$1"
    local runner_win
    runner_win="$(cygpath -m "${runner_bat}")"
    MSYS2_ARG_CONV_EXCL='*' cmd.exe /C "${runner_win}"
    local rc=$?
    rm -f "${runner_bat}"
    return $rc
}

run_windows_dev_pipeline() {
    local vcvars_bat="$1"
    local build_dir_win="$2"
    local runtime_dirs="$3"
    local cmake_args="$4"
    local build_jobs="$5"
    local skip_smoketest="$6"
    local skip_render="$7"
    local video_width="$8"
    local video_height="$9"
    local framerate="${10}"
    local samplerate="${11}"
    local audio_hints="${12}"
    local audio_sfx="${13}"

    local runner_bat=".go_windows_pipeline.bat"
    {
        echo "@echo off"
        echo "setlocal"
        echo "call \"${vcvars_bat}\" >nul"
        echo "if errorlevel 1 exit /b 1"
        if [ -n "${runtime_dirs}" ]; then
            echo "set \"PATH=${runtime_dirs}%PATH%\""
        fi
        echo "cd /d \"${build_dir_win}\""
        echo "if errorlevel 1 exit /b 1"
        echo "if not exist build.ninja cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release ${cmake_args}"
        echo "if errorlevel 1 exit /b 1"
        echo "ninja -j${build_jobs}"
        echo "if errorlevel 1 exit /b 1"
        if [ "${skip_smoketest}" -eq 0 ]; then
            echo "swaptube.exe 160 90 ${framerate} ${samplerate} smoketest ${audio_hints} ${audio_sfx}"
            echo "if errorlevel 1 exit /b 2"
        fi
        if [ "${skip_render}" -eq 0 ]; then
            echo "swaptube.exe ${video_width} ${video_height} ${framerate} ${samplerate} render ${audio_hints} ${audio_sfx}"
            echo "if errorlevel 1 exit /b 2"
        fi
        echo "exit /b 0"
    } > "${runner_bat}"

    run_windows_batch_file "${runner_bat}"
}

# Check for required commands
check_command_available "cmake"
check_command_available "ninja"
# gnuplot is used only for debug plot generation and is treated as Linux-only.
case "$(uname -s)" in
    Linux*)
        check_command_available "gnuplot"
        ;;
esac
MICROTEX_BINARY="$(find_microtex_binary || true)"
# Check if MicroTeX build exists
if [ -z "$MICROTEX_BINARY" ]; then
    echo "Error: A MicroTeX binary was not found. MicroTeX is required for this project."
    echo "Install instructions are available at https://github.com/NanoMichael/MicroTeX"

    # Ask the user for confirmation
    read -p "Would you like to automatically re-install MicroTeX now? Installation process can be viewed in go.sh. [y/N]: " choice
    case "$choice" in
        y|Y )
            (
                set -e # Exit on error
                echo ">>> Cloning and building MicroTeX..."
                cd .. || exit 1
                rm MicroTeX-master -rf
                git clone --depth 1 https://github.com/NanoMichael/MicroTeX.git MicroTeX-master
                cd MicroTeX-master || exit 1
                mkdir -p build
                cd build || exit 1
                cmake ..
                make -j"$(nproc)"
            )
            ;;
        * )
    esac

    # Verify installation
    MICROTEX_BINARY="$(find_microtex_binary || true)"
    if [ -z "$MICROTEX_BINARY" ]; then
        echo "Installation aborted or failed. Please follow the instructions manually: https://github.com/NanoMichael/MicroTeX"
        echo "HINT: If you are unable to install gtksourceviewmm-3.0 using your distro's package manager, try building it yourself using these instructions:"
        echo "https://github.com/end-4/dots-hyprland/issues/955#issuecomment-2486579754"
        exit 1
    fi

    echo "MicroTeX installation verified at ${MICROTEX_BINARY}."
fi

# Check if the number of arguments is less than expected
if [ $# -lt 4 ]; then
    echo "go.sh: Suppose that in the Projects/ directory you have made a project called myproject.cpp."
    echo "go.sh: Usage: $0 <ProjectName> <VideoWidth> <VideoHeight> <Framerate> [optional extra flags]"
    echo "go.sh: Example: $0 myproject 640 360 30 -hx"
    exit 1
fi

PROJECT_NAME=$1
VIDEO_WIDTH=$2
VIDEO_HEIGHT=$3
FRAMERATE=$4
shift; shift; shift; shift;
# Check that the video dimensions are valid integers
if ! [[ "$VIDEO_WIDTH" =~ ^[0-9]+$ ]] || ! [[ "$VIDEO_HEIGHT" =~ ^[0-9]+$ ]] || ! [[ "$FRAMERATE" =~ ^[0-9]+$ ]]; then
    echo "go.sh: Error - Video width, height, and framerate must be valid integers."
    exit 1
fi
SAMPLERATE=48000

SKIP_RENDER=0
SKIP_SMOKETEST=0
AUDIO_HINTS=0
AUDIO_SFX=0
INVALID_FLAG=0
COMPUTE_LANG=""
# Parse flags
while getopts "snhxc:" flag; do
    case "$flag" in
        s) 
            SKIP_RENDER=1
            ;;
        n) 
            SKIP_SMOKETEST=1
            ;;
        h) 
            AUDIO_HINTS=1
            ;;
        x) 
            AUDIO_SFX=1
            ;;
        c)  
            case "$OPTARG" in
                CUDA)
                    COMPUTE_LANG="CUDA"
                    ;;
                HIP)
                    COMPUTE_LANG="HIP"
                    ;;
                *)
                    echo "Invalid compute language specified: use CUDA or HIP"
                    exit 1
                    ;;
            esac
            ;;
        *)
            INVALID_FLAG=1
            ;;
    esac
done

# If the final flag is illegal, print an error message and exit
if [ $INVALID_FLAG -eq 1 ]; then
    echo "go.sh: Error - Invalid flag:"
    echo "-s means to only run the smoketest."
    echo "-n means to only run the render."
    echo "-h means to include audio hints."
    echo "-x means to include sound effects."
    echo "-c means to specify compute language (takes arguments \"CUDA\" or \"HIP\")"
    exit 1
fi

# Find the project file in any subdirectory under src/Projects
PROJECT_PATH=$(find src/Projects -type f -name "${PROJECT_NAME}.cpp" 2>/dev/null | head -n 1)
TEMPFILE="src/Projects/.active_project.cpp"

# Check if the desired project exists
if [ -z "$PROJECT_PATH" ]; then
    echo "go.sh: Project ${PROJECT_NAME} does not exist."
    exit 1
fi
cp "$PROJECT_PATH" "$TEMPFILE"

# Generate a timestamp for this build
OUTPUT_FOLDER_NAME=$(date +"%Y-%m-%d_%H.%M.%S")
OUTPUT_DIR="out/${PROJECT_NAME}/${OUTPUT_FOLDER_NAME}"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/frames"

INPUT_DIR="media/${PROJECT_NAME}"
mkdir -p "$INPUT_DIR/latex"

is_windows_msys=0
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        is_windows_msys=1
        ;;
esac

SWAPTUBE_BIN="./swaptube"
if [ $is_windows_msys -eq 1 ]; then
    SWAPTUBE_BIN="./swaptube.exe"
fi

echo "go.sh: Building project ${PROJECT_NAME} with output folder name ${OUTPUT_FOLDER_NAME}"
(
    mkdir -p build
    cd build

    if [ $? -ne 0 ]; then
        echo "go.sh: Unable to create and enter build directory."
        exit 1
    fi

    clear

    # Print the command as run
    echo "$0 $*"
    echo ""

    echo "==============================================="
    echo "=================== COMPILE ==================="
    echo "==============================================="
    echo "go.sh: Running \`cmake ..\` from build directory"

    BUILD_JOBS="$(nproc 2>/dev/null || echo 8)"
    if [ $is_windows_msys -eq 1 ]; then
        VCVARS64_BAT="$(find_windows_vcvars64 | tr -d '\r')"
        if [ -z "$VCVARS64_BAT" ]; then
            echo "go.sh: Unable to locate vcvars64.bat. Install Visual Studio Build Tools with C++ workload."
            exit 1
        fi
        BUILD_DIR_WIN="$(cygpath -w "$PWD")"
        WINDOWS_RUNTIME_DIRS=""
        # vcvars64.bat puts the selected MSVC compiler first. Resolve its full
        # path inside the batch process so CMake's cached compiler value stays
        # stable across incremental builds.
        WINDOWS_CMAKE_ARGS="-DCMAKE_CXX_COMPILER=\"%VCToolsInstallDir%bin\\Hostx64\\x64\\cl.exe\""
        if [ -n "${COMPUTE_LANG}" ]; then
            WINDOWS_CMAKE_ARGS="${WINDOWS_CMAKE_ARGS} -DCOMPUTE_LANG=${COMPUTE_LANG}"
        fi
        MSYS2_ROOT_HINT="$(find_windows_msys2_root || true)"
        if [ -n "$MSYS2_ROOT_HINT" ]; then
            verify_windows_msys2_lock "$MSYS2_ROOT_HINT" || exit 1
            WINDOWS_CMAKE_ARGS="${WINDOWS_CMAKE_ARGS} -DMSYS2_ROOT=\"${MSYS2_ROOT_HINT}\""
            WINDOWS_RUNTIME_DIRS="${WINDOWS_RUNTIME_DIRS}$(cygpath -w "${MSYS2_ROOT_HINT}/mingw64/bin" | tr -d '\r');"
            echo "go.sh: Using MSYS2_ROOT=${MSYS2_ROOT_HINT}"
        fi
        FFMPEG_ROOT_HINT="$(find_windows_ffmpeg_root || true)"
        if [ -n "$FFMPEG_ROOT_HINT" ]; then
            WINDOWS_CMAKE_ARGS="${WINDOWS_CMAKE_ARGS} -DFFMPEG_ROOT=\"${FFMPEG_ROOT_HINT}\""
            WINDOWS_RUNTIME_DIRS="${WINDOWS_RUNTIME_DIRS}$(cygpath -w "${FFMPEG_ROOT_HINT}/bin" | tr -d '\r');"
            echo "go.sh: Using FFMPEG_ROOT=${FFMPEG_ROOT_HINT}"
        fi
        echo "go.sh: Bootstrapping MSVC toolchain via $VCVARS64_BAT"
    fi

    if [ $is_windows_msys -eq 1 ]; then
        # Avoid Windows symlink/junction edge cases under Git Bash.
        rm -rf io_out io_in
        mkdir -p io_out/frames io_in
        cp -rf "../${INPUT_DIR}/." io_in/
        RESULT=0
        run_windows_dev_pipeline \
            "$VCVARS64_BAT" \
            "$BUILD_DIR_WIN" \
            "$WINDOWS_RUNTIME_DIRS" \
            "$WINDOWS_CMAKE_ARGS" \
            "$BUILD_JOBS" \
            "$SKIP_SMOKETEST" \
            "$SKIP_RENDER" \
            "$VIDEO_WIDTH" \
            "$VIDEO_HEIGHT" \
            "$FRAMERATE" \
            "$SAMPLERATE" \
            "$AUDIO_HINTS" \
            "$AUDIO_SFX"
        RESULT=$?
        if [ $RESULT -eq 1 ]; then
            echo "go.sh: Build failed. Please check the build errors."
            exit 1
        fi
        if [ $RESULT -eq 2 ]; then
            echo "go.sh: Execution failed."
            exit 2
        fi
    else
        # Unix compile and run pipeline (using upstream's architecture)
        cmake -G Ninja .. -DCOMPUTE_LANG="${COMPUTE_LANG}"
        echo "go.sh: Compiling..."
        ninja -j"${BUILD_JOBS}"
        if [ $? -ne 0 ]; then
            echo "go.sh: Build failed. Please check the build errors."
            exit 1
        fi

        echo "==============================================="
        echo "===================== RUN ====================="
        echo "==============================================="

        rm -rf io_out
        ln -s "../${OUTPUT_DIR}" io_out
        rm -rf io_in
        ln -s "../${INPUT_DIR}" io_in

        # Smoketest
        if [ $SKIP_SMOKETEST -eq 0 ]; then
            ./swaptube 320 180 $FRAMERATE $SAMPLERATE smoketest $AUDIO_HINTS $AUDIO_SFX 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "go.sh: Execution failed in smoketest."
                exit 2
            fi
        fi

        # True render
        if [ $SKIP_RENDER -eq 0 ]; then
            # Clear all files from the smoketest
            rm io_out/* -rf
            mkdir -p io_out/frames
            ./swaptube $VIDEO_WIDTH $VIDEO_HEIGHT $FRAMERATE $SAMPLERATE render $AUDIO_HINTS $AUDIO_SFX 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "go.sh: Execution failed in render."
                exit 2
            fi
        fi
    fi

    exit 0
)
RESULT=$?

if [ $is_windows_msys -eq 1 ]; then
    # Windows uses real io_out/io_in directories because MSVC tools do not
    # reliably follow Git Bash symlinks. Preserve the render artifacts in the
    # same timestamped output directory used by the Unix path before cleanup.
    if [ -d "build/io_out" ]; then
        cp -rf "build/io_out/." "$OUTPUT_DIR/"
    fi
    MSYS2_ARG_CONV_EXCL='*' cmd.exe //C "if exist build\\io_in rmdir /S /Q build\\io_in" >/dev/null 2>&1
    MSYS2_ARG_CONV_EXCL='*' cmd.exe //C "if exist build\\io_out rmdir /S /Q build\\io_out" >/dev/null 2>&1
else
    rm -rf "build/io_in"
    rm -rf "build/io_out"
fi
mv "$TEMPFILE" "$OUTPUT_DIR"

# Play video if compilation succeeded, and not in smoketest-only mode
if [ $RESULT -eq 0 ] && [ $SKIP_RENDER -eq 0 ]; then
    ./play.sh ${PROJECT_NAME}
fi

exit $RESULT
