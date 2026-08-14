#include "Smoketest.h"

namespace {
ExecutionMode execution_mode = ExecutionMode::RENDER;
}

bool FOR_REAL = true;
bool SMOKETEST = false;

bool is_smoketest() { return is_planning() || SMOKETEST; }
bool is_planning() { return execution_mode == ExecutionMode::PLAN; }
bool is_for_real() { return FOR_REAL; }
void set_smoketest(const bool enabled) {
    execution_mode = enabled ? ExecutionMode::SMOKETEST : ExecutionMode::RENDER;
    SMOKETEST = enabled;
}
void set_execution_mode(const ExecutionMode mode) {
    execution_mode = mode;
    SMOKETEST = mode != ExecutionMode::RENDER;
}
void set_for_real(const bool enabled) { FOR_REAL = enabled; }
bool rendering_on() { return FOR_REAL && !is_smoketest(); }
