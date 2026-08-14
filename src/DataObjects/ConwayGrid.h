#pragma once

#include <cstdint>
#include "../Core/Pixels.h"

typedef uint64_t Bitboard;

class ConwayGrid {
public:
    ivec2 grid_wh_bitboards;
    Bitboard* d_board = nullptr;
    Bitboard* d_board_2 = nullptr;
    Bitboard* d_target = nullptr;
    ConwayGrid(const ivec2& wh_bitboards, const Pixels& env);
    ~ConwayGrid();
    void iterate();
};
