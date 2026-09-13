#pragma once

#include <bitset>
#include <cassert>
#include <cstdint>
#include <list>
#include <optional>
#include <string>
#include <unordered_map>

namespace ltkit {

// Access is serialized by the session mutex. Admission reserves room for a
// torrent's entire lifecycle, so the alert thread never waits for a consumer
// (it must also process checkpoint replies while the consumer awaits them).
class EventMailbox {
public:
    enum class Kind { metadata, completed, stopped, invalid_selection, error };
    static constexpr std::size_t max_jobs = 256;
    // Four one-shot transitions can separate at most five error runs.
    static constexpr std::size_t max_critical_entries = max_jobs * 9;

    bool can_add(std::string const& id) const {
        return jobs_.size() < max_jobs && jobs_.count(id) == 0;
    }

    void add(std::string const& id) {
        assert(can_add(id));
        jobs_.emplace(id, Job{});
    }

    void retire(std::string const& id) {
        auto found = jobs_.find(id);
        if (found == jobs_.end()) return;
        found->second.retired = true;
        found->second.status.reset();
        if (found->second.pending == 0) jobs_.erase(found);
    }

    void critical(std::string const& id, Kind kind, std::string json) {
        auto& job = jobs_.at(id);
        if (kind == Kind::error) {
            if (job.last_error) {
                // Error payloads are the same sanitized native failure. Keep
                // every occurrence without allocating per repeated alert.
                assert(job.last_error->json == json);
                ++job.last_error->count;
                return;
            }
        } else {
            auto const bit = static_cast<std::size_t>(kind);
            if (job.delivered_or_pending.test(bit)) return;
            job.delivered_or_pending.set(bit);
            job.last_error = nullptr;
        }
        job.status.reset();
        critical_.push_back({id, std::move(json), 1});
        ++job.pending;
        if (kind == Kind::error) job.last_error = &critical_.back();
        assert(critical_.size() <= max_critical_entries);
    }

    void status(std::string const& id, std::string json) {
        auto& job = jobs_.at(id);
        if (job.retired || job.delivered_or_pending.test(static_cast<std::size_t>(Kind::completed))
            || job.delivered_or_pending.test(static_cast<std::size_t>(Kind::invalid_selection))) return;
        job.status = std::move(json);
    }

    std::string const* front() const {
        if (!critical_.empty()) return &critical_.front().json;
        for (auto const& [id, job] : jobs_) if (job.status) return &*job.status;
        return nullptr;
    }

    // Called only after copying the response succeeds. Allocation failure must
    // leave the event available for the next read.
    void pop() {
        if (!critical_.empty()) {
            auto& entry = critical_.front();
            if (--entry.count != 0) return;
            auto found = jobs_.find(entry.id);
            auto& job = found->second;
            if (job.last_error == &entry) job.last_error = nullptr;
            --job.pending;
            critical_.pop_front();
            if (job.retired && job.pending == 0) jobs_.erase(found);
            return;
        }
        for (auto& [id, job] : jobs_) if (job.status) {
            job.status.reset();
            return;
        }
    }

    std::size_t critical_size() const { return critical_.size(); }
    std::size_t job_count() const { return jobs_.size(); }

private:
    struct Entry {
        std::string id;
        std::string json;
        std::uint64_t count;
    };
    struct Job {
        std::bitset<4> delivered_or_pending;
        std::optional<std::string> status;
        Entry* last_error = nullptr;
        std::size_t pending = 0;
        bool retired = false;
    };
    std::list<Entry> critical_;
    std::unordered_map<std::string, Job> jobs_;
};

} // namespace ltkit
