#pragma once
#include <string>
#include <cstdio>
#include "../Host_Device_Shared/vec.h"
#include "../Core/Pixels.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

class LivePlayer {
public:
    LivePlayer(const ivec2& dimensions);
    ~LivePlayer();
    void accept_frame(uint32_t* device_pixels, bool print);
private:
    FILE* pipe;
    ivec2 dimensions;
#ifdef _WIN32
    HANDLE process = nullptr;
#endif
};
