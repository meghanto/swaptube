#pragma once

enum class ExecutionMode {
    PLAN,
    SMOKETEST,
    RENDER
};

// Kept as public project controls for source compatibility.
extern bool FOR_REAL;
extern bool SMOKETEST;

bool is_smoketest();
bool is_planning();
bool is_for_real();
void set_smoketest(bool smoketest);
void set_execution_mode(ExecutionMode mode);
void set_for_real(bool for_real);
bool rendering_on();
