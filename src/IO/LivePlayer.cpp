#include "LivePlayer.h"
#include <iostream>
#include <string>
#include <cstdio>
#include <stdexcept>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include "IoHelpers.h"
#endif

extern "C" void cuda_copy_pixels_to_host(uint32_t* h_pixels, int size, uint32_t* d_pixels);

LivePlayer::LivePlayer(const ivec2& dim) : dimensions(dim) {
    string ffplay_cmd_str = "ffplay -f rawvideo -pixel_format bgra -video_size " + to_string(dimensions.x) + "x" + to_string(dimensions.y) + " -";
    cout << "Running command: " << ffplay_cmd_str << endl;
#ifdef _WIN32
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE child_stdin = nullptr;
    HANDLE parent_write = nullptr;
    if (!CreatePipe(&child_stdin, &parent_write, &security, 0) ||
        !SetHandleInformation(parent_write, HANDLE_FLAG_INHERIT, 0)) {
        throw runtime_error("Failed to create ffplay input pipe.");
    }

    STARTUPINFOA startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = child_stdin;
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process_info{};
    vector<char> command(ffplay_cmd_str.begin(), ffplay_cmd_str.end());
    command.push_back('\0');
    BOOL created = CreateProcessA(
        nullptr, command.data(), nullptr, nullptr, TRUE, 0,
        nullptr, nullptr, &startup, &process_info
    );
    CloseHandle(child_stdin);
    if (!created) {
        CloseHandle(parent_write);
        throw runtime_error("Failed to start ffplay for live preview.");
    }
    CloseHandle(process_info.hThread);
    process = process_info.hProcess;

    int fd = _open_osfhandle(reinterpret_cast<intptr_t>(parent_write), _O_BINARY);
    pipe = fd < 0 ? nullptr : _fdopen(fd, "wb");
    if (!pipe) {
        if (fd >= 0) _close(fd); else CloseHandle(parent_write);
        CloseHandle(process);
        process = nullptr;
        throw runtime_error("Failed to open ffplay input stream.");
    }
#else
    pipe = portable_popen(ffplay_cmd_str.c_str(), "w");
#endif
    if (!pipe) throw runtime_error("Failed to start ffplay for live preview.");
}

LivePlayer::~LivePlayer() {
    if (!pipe) return;
#ifdef _WIN32
    fclose(pipe);
    WaitForSingleObject(process, INFINITE);
    CloseHandle(process);
#else
    portable_pclose(pipe);
#endif
}

void LivePlayer::accept_frame(uint32_t* device_pixels, bool print) {
    Pixels pix(dimensions);
    cuda_copy_pixels_to_host(pix.pixels.data(), pix.pixels.size(), device_pixels);
    if(print) pix.print_to_terminal();
    fwrite(pix.pixels.data(),
        sizeof(int32_t),
        pix.pixels.size(),
        pipe);
    fflush(pipe);
}
