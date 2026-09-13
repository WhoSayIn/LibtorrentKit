#pragma once

namespace ltkit {
// One native request at a time, including after a caller times out. Late
// replies must drain before a subsequent completion checkpoint can start.
class DiskCheckpoint {
public:
    enum class Phase { idle, flushing, saving, succeeded, failed };

    bool begin(bool flush) {
        if (phase_ != Phase::idle) return false;
        phase_ = flush ? Phase::flushing : Phase::saving;
        return true;
    }
    bool cache_flushed() {
        if (phase_ != Phase::flushing) return false;
        phase_ = Phase::saving;
        return true;
    }
    bool resume_saved() {
        if (phase_ != Phase::saving) return false;
        phase_ = Phase::succeeded;
        return true;
    }
    bool fail() {
        if (!pending()) return false;
        phase_ = Phase::failed;
        return true;
    }
    bool pending() const { return phase_ == Phase::flushing || phase_ == Phase::saving; }
    bool idle() const { return phase_ == Phase::idle; }
    void reset() { phase_ = Phase::idle; }

private:
    Phase phase_ = Phase::idle;
};
}
