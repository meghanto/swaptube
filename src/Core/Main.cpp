/* 
 * This file introduces a bit of common boilerplate so the user can jump straight into making
 * a project file.
 */

using namespace std;

#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include "Timer.h"
#include "MicroblockPlan.h"
#include "Smoketest.h"
#include "../IO/Writer.h"
#include "../Scenes/Scene.h"
#include "State/GlobalState.h"
#include <filesystem>

#ifdef _WIN32
namespace {
class ConsoleOutputCodePageGuard {
public:
    ConsoleOutputCodePageGuard() {
        HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD mode = 0;
        if (output == nullptr || output == INVALID_HANDLE_VALUE || !GetConsoleMode(output, &mode)) return;

        original_code_page = GetConsoleOutputCP();
        if (original_code_page != 0 && original_code_page != CP_UTF8) {
            changed = SetConsoleOutputCP(CP_UTF8) != 0;
        }
    }

    ~ConsoleOutputCodePageGuard() {
        if (changed) SetConsoleOutputCP(original_code_page);
    }

    ConsoleOutputCodePageGuard(const ConsoleOutputCodePageGuard&) = delete;
    ConsoleOutputCodePageGuard& operator=(const ConsoleOutputCodePageGuard&) = delete;

private:
    UINT original_code_page = 0;
    bool changed = false;
};
}
#endif

void render_video(); // Forward declaration, provided by the user in their project file

void parse_args(int argc, char* argv[], int& w, int& h, int& framerate, int& samplerate, bool& audio_hints, bool& audio_sfx, string& microblock_plan_path) {
    cout << "Parsing command line arguments... " << endl;

    if (argc != 9) {
        throw runtime_error("Expected 8 arguments: width height framerate samplerate plan/smoketest/render audio_hints audio_sfx microblock_plan_path");
    }

    if (sscanf(argv[1], "%d", &w) != 1 || w < 1 || w > 10000) {
        throw runtime_error("Invalid width argument: " + string(argv[1]) );
    }
    set_global_state("VIDEO_WIDTH", w);
    cout << "Width: " << w << ", " << flush;

    if (sscanf(argv[2], "%d", &h) != 1 || h < 1 || h > 10000) {
        throw runtime_error("Invalid height argument: " + string(argv[2]) );
    }
    set_global_state("VIDEO_HEIGHT", h);
    cout << "Height: " << h << ", " << flush;

    if (sscanf(argv[3], "%d", &framerate) != 1 || framerate < 1 || framerate > 240) {
        throw runtime_error("Invalid framerate argument: " + string(argv[3]) );
    }
    cout << "Framerate: " << framerate << ", " << flush;

    if (sscanf(argv[4], "%d", &samplerate) != 1 || samplerate < 8000 || samplerate > 192000) {
        throw runtime_error("Invalid samplerate argument: " + string(argv[4]) );
    }
    cout << "Samplerate: " << samplerate << ", " << flush;

    string smoketest_arg = argv[5];
    if (smoketest_arg == "plan") {
        set_execution_mode(ExecutionMode::PLAN);
    } else if (smoketest_arg == "smoketest") {
        set_execution_mode(ExecutionMode::SMOKETEST);
    } else if (smoketest_arg == "render") {
        set_execution_mode(ExecutionMode::RENDER);
    } else {
        throw runtime_error("Invalid smoketest flag argument: " + smoketest_arg);
    }
    cout << "Execution Mode: " << smoketest_arg << ", " << flush;

    if(samplerate % framerate != 0) {
        throw runtime_error("Video framerate must be divisible by audio sample rate.");
    }

    int audio_hints_i;
    if (sscanf(argv[6], "%d", &audio_hints_i) != 1 || (audio_hints_i != 0 && audio_hints_i != 1)) {
        throw runtime_error("Invalid audio hints argument: " + string(argv[6]) );
    }
    audio_hints = (audio_hints_i != 0);
    cout << "Audio Hints: " << (audio_hints ? "true" : "false") << ", " << flush;

    int audio_sfx_i;
    if (sscanf(argv[7], "%d", &audio_sfx_i) != 1 || (audio_sfx_i != 0 && audio_sfx_i != 1)) {
        throw runtime_error("Invalid audio sfx argument: " + string(argv[7]) );
    }
    audio_sfx = (audio_sfx_i != 0);
    cout << "Audio SFX: " << (audio_sfx ? "true" : "false") << ", " << flush;

    microblock_plan_path = argv[8];
    if (microblock_plan_path.empty()) {
        throw runtime_error("Microblock plan path cannot be empty");
    }
    cout << "Microblock Plan: " << microblock_plan_path << endl << endl;
}

inline void signal_handler(int signal) {
    throw runtime_error("Interrupt detected. Exiting gracefully.");
}

void setup_output_subfolders() {
    cout << "Setting up output subfolders... " << endl;
    std::filesystem::create_directories("io_out/frames");
    std::filesystem::create_directories("io_out/data");
    std::filesystem::create_directories("io_out/plots");
}

int main(int argc, char* argv[]) {
#ifdef _WIN32
    ConsoleOutputCodePageGuard console_output_code_page;
#endif

    int VIDEO_WIDTH, VIDEO_HEIGHT, FRAMERATE, SAMPLERATE;
    bool AUDIO_HINTS, AUDIO_SFX;
    string microblock_plan_path;
    parse_args(argc, argv, VIDEO_WIDTH, VIDEO_HEIGHT, FRAMERATE, SAMPLERATE, AUDIO_HINTS, AUDIO_SFX, microblock_plan_path);
    Timer timer;

    // Main Render Loop
    signal(SIGINT, signal_handler);
    try {
        if (!is_planning()) setup_output_subfolders();
        init_writer(VIDEO_WIDTH, VIDEO_HEIGHT, FRAMERATE, SAMPLERATE, 0xff000044, AUDIO_HINTS, AUDIO_SFX);
        initialize_microblock_plan(microblock_plan_path);
        cout << "Rendering video... " << endl;
        render_video();
        finalize_macroblock_sequence();
    } catch(std::exception& e) {
        // Change to red text
        cout << "\033[1;31m";

        cout << endl << "====================" << endl;
        cout << "EXCEPTION CAUGHT IN RUNTIME: " << endl;
        cout << e.what() << endl;
        if (get_writer().subtitle != nullptr) {
            cout << "Last written subtitle: " << get_writer().subtitle->get_last_written_subtitle() << endl;
        }
        cout << "====================" << endl;

        // Change back to normal text
        cout << "\033[0m" << endl;
        return 1;
    }

    get_writer().destroy();

    cout << "\033[1;32m" << endl << "====================" << endl;
    cout << "Completed successfully!" << endl;
    cout << "====================" << "\033[0m" << endl << endl;
    return 0;
}
