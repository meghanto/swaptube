#include "MicroblockPlan.h"

#include "Smoketest.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace std;

namespace {
ifstream plan_input;
ofstream plan_output;
string plan_path;
size_t next_entry = 0;
optional<int> open_count;
optional<int> declared_count;
string open_blurb;
bool initialized = false;

string entry_description(const size_t index) {
    return "macroblock " + to_string(index + 1);
}

void finish_recording_entry() {
    if (!open_count) return;
    if (*open_count <= 0) {
        throw runtime_error("Microblock planning found no render_microblock() calls for "
            + entry_description(next_entry) + ": " + open_blurb);
    }
    if (declared_count && *declared_count != *open_count) {
        cerr << "WARNING: Legacy code declared " << *declared_count
             << " microblocks, but planning observed " << *open_count
             << " for " << entry_description(next_entry) << ": " << open_blurb
             << ". Using the observed count." << endl;
    }
    plan_output << *open_count << '\n';
    if (!plan_output) {
        throw runtime_error("Could not write microblock plan: " + plan_path);
    }
    next_entry++;
    open_count.reset();
    declared_count.reset();
    open_blurb.clear();
}
}

void initialize_microblock_plan(const string& path) {
    if (path.empty()) throw invalid_argument("Microblock plan path cannot be empty");

    plan_path = path;
    next_entry = 0;
    open_count.reset();
    declared_count.reset();
    open_blurb.clear();
    initialized = true;

    if (is_planning()) {
        plan_output.open(plan_path, ios::trunc);
        if (!plan_output) throw runtime_error("Could not create microblock plan: " + plan_path);
    } else {
        plan_input.open(plan_path);
        if (!plan_input) throw runtime_error("Could not open microblock plan: " + plan_path);
    }
}

int begin_macroblock_plan_entry(const string& blurb, const optional<int> declared) {
    if (!initialized) {
        if (declared) return *declared;
        throw runtime_error("No microblock plan was supplied for " + blurb);
    }

    if (is_planning()) {
        finish_recording_entry();
        open_count = 0;
        declared_count = declared;
        open_blurb = blurb;
        return declared.value_or(-1);
    }

    int expected_count;
    if (!(plan_input >> expected_count)) {
        if (plan_input.eof()) {
            throw runtime_error("Microblock plan ended before "
                + entry_description(next_entry) + ": " + blurb);
        }
        throw runtime_error("Invalid microblock plan: " + plan_path);
    }
    if (expected_count <= 0) {
        throw runtime_error("Invalid non-positive microblock count in " + plan_path);
    }
    next_entry++;
    return expected_count;
}

void record_planned_microblock() {
    if (!is_planning()) return;
    if (!initialized || !open_count) {
        throw runtime_error("render_microblock() was called without an active macroblock while planning");
    }
    (*open_count)++;
}

void finalize_microblock_plan() {
    if (!initialized) return;
    if (is_planning()) {
        finish_recording_entry();
        plan_output.close();
        if (!plan_output) throw runtime_error("Could not finish microblock plan: " + plan_path);
        return;
    }

    int unused_count;
    if (plan_input >> unused_count) {
        throw runtime_error("Microblock plan contains unused macroblock entries");
    }
    if (!plan_input.eof()) throw runtime_error("Invalid microblock plan: " + plan_path);
}
