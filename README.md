# Fork info:
This is a version of swaptube, where the main branch should work on windows machines. If it doesn't, please post an issue and also join the discord for collaborative troubleshooting! 

If you would like to maintain this beyond a single windows machine and have it be tested and robust, please contribute! 

Swaptube functionality-specific contributions should go in the main swaptube repo, this repo should take contributions that primarily focus on compatibility (Not limited to windows development! If you have a platform you'd love to run swaptube on, and have managed to get it to work there, I think this is the place for it.) 

# Original Readme:
# SwapTube

This is the repository I use to render [my YouTube videos](https://www.youtube.com/@twoswap).

SwapTube is built on FFMPEG, but most of the functionalities above the layer of video and audio encoding are custom-written. The project does not use any fancy graphics libraries, with a few exceptions for particular functionalities.

# Tutorial Video
[![Swaptube Tutorial Video](http://img.youtube.com/vi/paqBduieRks/0.jpg)](https://www.youtube.com/watch?v=paqBduieRks "SwapTube Tutorial Video")

# Learn SwapTube Discord Server
https://discord.gg/a786NZXYQ3

# Compatibility
SwapTube is developed, and is known to compile and run on several Linux distributions. MacOS and Windows are untested.
Furthermore, a CUDA-compatible NVIDIA GPU or a [HIP](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html)-compatible AMD GPU is required.

Note that the HIP folder is generated on HIP-compatible machines by translating the CUDA folder with hipify. Do not modify any of the contents in HIP/, instead treat the CUDA folder as the source of truth and modify that. It will be re-translated via CMake.

There is an experimental Windows/MSVC build available in a fork: [meghanto/swaptube](https://github.com/meghanto/swaptube) (you're here!). It is not officially supported here, may lag behind `master`, and comes with no guarantee of ongoing maintenance.

## Setup
### External Dependencies
The following external dependencies are required for specific functionalities within the project. These dependencies must be installed if you want to use the related features.

| Item | What functionality is it needed for? | Used Where? | Used How? | Sample Ubuntu Installation |
|------------|---------|---------|----------------|--------------|
| CMake and Ninja | Everything | go.sh script | Compiles the project | `sudo apt install cmake ninja-build` |
| FFMPEG 5.0 or higher, and associated development libraries | Everything | audio_video folder | Encoding and processing video and audio streams | `sudo apt install ffmpeg libswscale-dev libavcodec-dev libavformat-dev libavdevice-dev libavutil-dev libavfilter-dev` Note: compiling ffmpeg from source, it will likely be compiled with support for extra features detected on your system, which are not baked into my CMake config. I suggest installing a precompiled binary. |
| CUDA or HIP/ROCm | Computationally intensive graphics | Video render loop | Various | Hardware-dependent |
| gnuplot (Linux only) | Debug plot generation | DebugPlot.h | Data dumped in out/ is rendered to a PNG | `sudo apt install gnuplot` |
| MicroTeX | In-Video LaTeX, LatexScene | visual_media.cpp | Converts LaTeX equations into SVG files for rendering | Instructions are here: https://github.com/NanoMichael/MicroTeX/ You should install MicroTeX in MicroTeX-master alongside the swaptube checkout. Instructions will be printed if not found. |
| RSVG and GLib | In-Video LaTeX | visual_media.cpp | Loads and renders SVG files into pixel data | `sudo apt install librsvg2-dev libglib2.0-dev` |
| Cairo | In-Video LaTeX | visual_media.cpp | Renders SVG files onto Cairo surfaces and converts them to pixel data | `sudo apt install libcairo2-dev` |
| LibPNG | PNG scenes | visual_media.cpp | Reads PNG files and converts them to pixel data | `sudo apt install libpng-dev` |

## Docker Setup
For easy deployment with all dependencies included, see the [docker/README.md](docker/README.md) for containerized setup instructions. This is optional and community-made for Docker users. I (2swap) personally don't use or maintain it.

# How to Run
When you have created a project file `Projects/yourprojectname.cpp`, you can compile and run the whole project by executing:

```bash
./go.sh yourprojectname 640 360 30
```

Some example code and demos can be found in `src/Projects/Demos/`. How to run a demo (code run from project root):

```bash
./go.sh LambdaDemo 640 360 30
```

This indicates a 640x360 landscape resolution at 30FPS. Swaptube defaults to an audio sample rate of 48000 Hz- If you need to change that for whatever reason, they are specified in `go.sh` and `record_audios.py`.

On Windows, use the native PowerShell workflow from a PowerShell terminal. It
loads the MSVC environment and invokes CMake, Ninja, CUDA, and Swaptube without
Git Bash:

For complete fresh-machine prerequisites and installation instructions, see
**[Building and running SwapTube on Windows](WINDOWS.md)**.

```powershell
.\go.ps1 MandelbrotDemo 1920 1080 30 -n -c CUDA
```

Add `-q` to suppress compiler output and disable the periodic GPU-frame terminal
preview. Use `-s` for a
smoketest only, `-n` to skip the smoketest, `-h` for audio hints, and `-x` for
sound effects. If script execution is disabled for the current process, enable
local scripts with `Set-ExecutionPolicy -Scope Process Bypass`.

# Testing
You can validate your local installation with ./test.sh, which will compile and smoketest every "Demo" project (in `src/Projects/Demos/`) without rendering.

# Repository Structure
### Top-Level Files and Folders
- **src/**: Source folder structure is documented in the readme inside of it.

- **out/**: Contains the output files (videos, corresponding subtitle files, data tables, and gnuplots) generated by swaptube.
  - Each subfolder corresponds to a project, and under that project, each render is stored in a separate folder named by timestamp.

- **media/**: Stores input media files used by the project. This includes script recordings, generated LaTeX, source MP4s, and source PNGs.
  - You should not ever need to manually modify anything here, with the exception of placing source PNGs and MP4s. Audio should be recorded using `record_audios.py` after rendering your project.
  - `Some_Project/`: Put media for your project here.
    - `record_list.tsv`: This will be generated by the program after rendering your project, and is read by the `record_audios.py` script so that you can record your script easily in bulk.

- **build/**: Contains, most importantly, the compiled binary. Caches and miscellaneous data products may also be dumped here, for example discovered connect 4 steady states and graphs, as well as CMake caches and the like. You should not need to ever enter this folder. Use the `go.sh` script to start builds.

- **record_audios.py**: Reads the record_list.tsv file and permits you to quickly record all of the audio files for your video script.

- **go.sh**: The program entry point! It compiles, smoketests, and runs your project file at a specified resolution and framerate.

- **go.ps1**: Native Windows entry point using PowerShell and the MSVC toolchain.

- **play.sh**: Plays back the most recently rendered video with the provided project name.

- **play.ps1**: Native Windows playback helper.

- **test.sh**: Compiles and smoketests all demo projects.

# Design Philosophy

### Time Control
Swaptube uses a 2-layer time organization system. At the highest level, the video is divided into Macroblocks, which can be thought of as atomic units of audio. In practice, a Macroblock usually corresponds to a single sentence in the video script. Macroblocks are divided into Microblocks, which represent atomic time units controlling visual transformations. Often a Macroblock only has one Microblock, but more complex Macroblocks may have multiple Microblocks to allow for visual transitions or animations to occur over the duration of the Macroblock.
Such division permits the user to define a video with an in-line script, such that SwapTube will do all time management and the user does not need to manually time each segment of video.
Furthermore, this permits native transitions: since a transition occurs over either a Macroblock or Microblock, Swaptube knows the duration of time over which the transition occurs, and can manage that transition automatically through State.

##### Macroblocks
There are a few types of macroblocks: FileBlocks, SilenceBlocks, GeneratedBlocks, etc. FileBlocks are defined by a filepath to an audio file inside the media folder.
SilenceBlocks are defined by a duration in seconds, and GeneratedBlocks are defined by a buffered array of audio samples generated in the project file.
A macroblock can be created using `stage_macroblock(FileBlock("your subtitle text"));`. SwapTube runs a fast planning pass before smoketesting or rendering and counts the actual `render_microblock()` calls associated with each macroblock. The existing two-argument form remains supported; SwapTube warns if its declared count differs from planning and uses the observed count.

##### Microblocks
After a Macroblock has been staged, the project file renders each microblock by calling `yourscene.render_microblock();`. These calls may appear in ordinary loops and conditionals; no separate predicted count is required. Planning, smoketesting, and rendering must follow the same macroblock and microblock control flow, and SwapTube reports a plan mismatch if they do not. Project control flow must not depend on pixels, encoded output, or other state produced only while rendering; the planning pass deliberately skips that work.

### Smoketesting
Before smoketesting or rendering, SwapTube runs a count-only planning pass. It performs no timed rendering or encoding and stores its result in a temporary file for the current invocation. SwapTube then uses those counts to divide each macroblock's duration among its microblocks.

To ensure that the planned time control is valid and that the project does not crash before potentially kicking off a multi-hour render, SwapTube also has a `smoketest` feature. By default, smoketest is run after planning.

Things that happen during smoketesting:
- One frame per microblock is staged and rendered
- State transitions are performed as normal to test validity of state equation definitions
- The record_list.tsv file is re-populated, so you can record your audio script after smoketesting without performing a full render.
- Subtitles will be generated with incorrect timestamps reflecting one-frame-per-microblock timing.

Things that do NOT happen during smoketesting:
- No video or audio is encoded or rendered
- Since nothing is rendered, occasional frames are not drawn to stdout

You can run `./go.sh MyProjectName 640 360 -s`, using the `-s` flag to indicate "planning and smoketest only". The `-n` flag skips the smoketest but still runs the required planning pass before the full render.

In addition to smoketesting, there is an additional exposed boolean variable `FOR_REAL` which can be toggled to true or false in the project file, effectively enabling smoketest mode for sections of a true render. This allows you to, say, work on the last section of a video without having to re-render the beginning each time.

### State
**State**: The "State Manager" tracks a list of definitions of variables, arranged in a dependency graph of definitions, eventually decided from upstate "global state" sensors, such as the current microblock completion fraction `{microblock_fraction}` or the number of seconds elapsed in the video `{t}`. It is best used for any numerical or boolean information used by the Scene to render a particular frame: opacities, angles, camera positions, real-valued parameters, etc. All scenes have a StateManager, and when the user whishes to modify the scene's state, they can do so by calling functions on the StateManager. Usually these will be `set` and `transition` function calls. Since State uniquely contains numerical information, swaptube will handle all the clean transitions of state.
