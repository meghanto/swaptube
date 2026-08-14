#!/bin/bash

clear
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Git Bash uses the same native MSVC pipeline as PowerShell so both entry
# points share tool discovery, dependency validation, and CMake state.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        powershell_args=("$PROJECT_NAME" "$VIDEO_WIDTH" "$VIDEO_HEIGHT" "$FRAMERATE")
        [ $SKIP_RENDER -eq 1 ] && powershell_args+=("-SmoketestOnly")
        [ $SKIP_SMOKETEST -eq 1 ] && powershell_args+=("-SkipSmoketest")
        [ $AUDIO_HINTS -eq 1 ] && powershell_args+=("-AudioHints")
        [ $AUDIO_SFX -eq 1 ] && powershell_args+=("-AudioSfx")
        [ -n "$COMPUTE_LANG" ] && powershell_args+=("-ComputeLang" "$COMPUTE_LANG")
        [ -n "${SWAPTUBE_QUIET:-}" ] && powershell_args+=("-Quiet")
        script_path="$(cygpath -w "$SCRIPT_DIR/go.ps1")"
        MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File "$script_path" "${powershell_args[@]}"
        exit $?
        ;;
esac

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

SWAPTUBE_BIN="./swaptube"

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

    exit 0
)
RESULT=$?

rm -rf "build/io_in"
rm -rf "build/io_out"
mv "$TEMPFILE" "$OUTPUT_DIR"

# Play video if compilation succeeded, and not in smoketest-only mode
if [ $RESULT -eq 0 ] && [ $SKIP_RENDER -eq 0 ]; then
    ./play.sh ${PROJECT_NAME}
fi

exit $RESULT
