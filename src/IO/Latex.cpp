#include "Latex.h"

#include <vector>
#include <stdexcept>
#include <librsvg/rsvg.h>
#include <sys/stat.h>
#include <cmath>
#include <sstream>
#include <unordered_map>
#include <cairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <iostream>
#include <iomanip>
#include <filesystem>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

using namespace std;

#ifdef _WIN32
static string quote_windows_argument(const string& argument) {
    string quoted = "\"";
    size_t backslashes = 0;
    for (char c : argument) {
        if (c == '\\') {
            backslashes++;
        } else if (c == '"') {
            quoted.append(backslashes * 2 + 1, '\\');
            quoted.push_back('"');
            backslashes = 0;
        } else {
            quoted.append(backslashes, '\\');
            backslashes = 0;
            quoted.push_back(c);
        }
    }
    quoted.append(backslashes * 2, '\\');
    quoted.push_back('"');
    return quoted;
}

static int run_microtex(
    const filesystem::path& executable,
    const filesystem::path& working_directory,
    const string& latex,
    const string& output_name
) {
    vector<string> arguments = {
        executable.string(), "-headless", "-foreground=#ffffffff",
        "-input=" + latex, "-output=" + output_name,
    };
    string command_line;
    for (const string& argument : arguments) {
        if (!command_line.empty()) command_line.push_back(' ');
        command_line += quote_windows_argument(argument);
    }
    vector<char> mutable_command_line(command_line.begin(), command_line.end());
    mutable_command_line.push_back('\0');

    STARTUPINFOA startup_info{};
    startup_info.cb = sizeof(startup_info);
    PROCESS_INFORMATION process_info{};
    BOOL created = CreateProcessA(
        executable.string().c_str(), mutable_command_line.data(),
        nullptr, nullptr, FALSE, 0, nullptr,
        working_directory.string().c_str(), &startup_info, &process_info
    );
    if (!created) {
        throw runtime_error("Failed to start MicroTeX LaTeX.exe (Windows error " + to_string(GetLastError()) + ").");
    }
    WaitForSingleObject(process_info.hProcess, INFINITE);
    DWORD exit_code = 1;
    if (!GetExitCodeProcess(process_info.hProcess, &exit_code)) {
        DWORD error = GetLastError();
        CloseHandle(process_info.hThread);
        CloseHandle(process_info.hProcess);
        throw runtime_error("Failed to read MicroTeX exit code (Windows error " + to_string(error) + ").");
    }
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    return static_cast<int>(exit_code);
}
#endif

extern "C" void cuda_overlay (
    uint32_t* background, const ivec2& b_wh,
    const uint32_t* foreground, const ivec2& f_wh,
    const vec2& center, const float opacity, const float angle_rad);

string latex_color(uint32_t color, string text) {
    // Mask out the alpha channel
    uint32_t rgb = color & 0x00FFFFFF;

    // Convert to a hex string
    stringstream ss;
    ss << "\\textcolor{#" << hex << setw(6) << setfill('0') << rgb << "}{" << text << "}";

    return ss.str();
}

// Custom hash and equality for pair<string, pair<int,int>>
struct StringIntPairHash {
    size_t operator()(const pair<string, pair<int, int>>& p) const noexcept {
        size_t h1 = std::hash<string>{}(p.first);
        size_t h2 = (static_cast<size_t>(p.second.first) << 32) ^ static_cast<size_t>(p.second.second);
        // boost-like mix
        return h1 ^ (h2 + 0x9e3779b97f4a7c15ULL + (h1<<6) + (h1>>2));
    }
};
struct StringIntPairEq {
    bool operator()(const pair<string, pair<int, int>>& a, const pair<string, pair<int, int>>& b) const noexcept {
        return a.first == b.first && a.second.first == b.second.first && a.second.second == b.second.second;
    }
};

// Create an unordered_map to store the cached results
unordered_map<string, shared_ptr<DevicePointer>> latex_cache;

static string generate_cache_key(const string& text, const ScalingParams& scaling_params) {
    hash<string> hasher;
    string key = text + "_" + to_string(static_cast<int>(scaling_params.mode)) + "_" + 
                 to_string(scaling_params.bounding_box.x) + "_" + 
                 to_string(scaling_params.bounding_box.y) + "_" +
                 to_string(scaling_params.scale_factor);
    return to_string(hasher(key));
}

/*
 * We use MicroTEX to convert LaTeX equations into svg files.
 */
shared_ptr<DevicePointer> latex_to_gpu_pix(const string& latex, ScalingParams& scaling_params) {
    // Generate a cache key based on the equation and scaling parameters
    string cache_key = generate_cache_key(latex, scaling_params);

    // Check if the result is already in the cache
    auto it = latex_cache.find(cache_key);
    if (it != latex_cache.end()) {
        return it->second; // Return the cached result
    }

    cout << "Generating LaTeX for: " << latex << endl;

    hash<string> hasher;
    string latex_dir = "io_in/latex/";
    filesystem::create_directories(latex_dir);
    string name_without_folder = to_string(hasher(latex)) + ".svg";
    string name = (filesystem::absolute(latex_dir) / name_without_folder).string();

    if (!filesystem::exists(name)) {
#ifdef _WIN32
        string output_name = name;
        for (char& c : output_name) if (c == '\\') c = '/';
        filesystem::path microtex_build_dir = filesystem::absolute("../../MicroTeX-master/build-mingw-headless");
        if (!filesystem::exists(microtex_build_dir)) {
            microtex_build_dir = filesystem::absolute("../../MicroTeX-master/build");
        }
        int result = run_microtex(
            microtex_build_dir / "LaTeX.exe", microtex_build_dir, latex, output_name
        );
#else
        string command = "cd ../../MicroTeX-master/build/ && ./LaTeX -headless -foreground=#ffffffff \"-input=" + latex + "\" -output=" + name + " >/dev/null 2>&1";
        int result = system(command.c_str());
#endif
        if(result != 0) {
#ifndef _WIN32
            cout << command << endl;
#endif
            throw runtime_error("Failed to generate LaTeX (MicroTeX exit code " + to_string(result) + ").");
        }
    }

    // System call successful, return the generated SVG
    shared_ptr<DevicePointer> text = svg_to_gpu_pix("latex/" + name_without_folder, scaling_params);
                cout << "Dimensions = " << text->get_wh().x << " x " << text->get_wh().y << endl;
    latex_cache[cache_key] = text; // Cache the result before returning
    return text;
}

void write_text(uint32_t* gpu_pix, const ivec2& canvas_wh, const std::string& latex, const vec2& center, const vec2& text_envelope, const double opacity, const float angle_rad) {
    ScalingParams scaling_params(text_envelope);

    shared_ptr<DevicePointer> text = latex_to_gpu_pix(latex, scaling_params);
    cuda_overlay(gpu_pix, canvas_wh, text->get_ptr(), text->get_wh(), center, opacity, angle_rad);
}
