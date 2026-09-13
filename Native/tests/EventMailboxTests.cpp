#include "../src/EventMailbox.hpp"
#include <cassert>
#include <iostream>

using Mailbox = ltkit::EventMailbox;
using Kind = Mailbox::Kind;

int main() {
    Mailbox mailbox;
    constexpr int jobs = 128;
    constexpr int burst = 4096;
    for (int i = 0; i < jobs; ++i) {
        auto id = std::to_string(i);
        mailbox.add(id);
        mailbox.critical(id, Kind::metadata, "metadata:" + id);
        for (int j = 0; j < burst; ++j) {
            mailbox.status(id, "status:" + std::to_string(j));
            mailbox.critical(id, Kind::error, "error:" + id);
        }
        mailbox.critical(id, Kind::completed, "completed:" + id);
        mailbox.critical(id, Kind::stopped, "stopped:" + id);
        mailbox.status(id, "stale status after completion");
        mailbox.retire(id);
    }
    // More critical entries than either old 256-element buffer, and more than
    // half a million telemetry/error notifications with no consumer running.
    assert(mailbox.critical_size() == jobs * 4);
    for (int i = 0; i < jobs; ++i) {
        auto id = std::to_string(i);
        auto expect = [&](std::string const& event) {
            assert(mailbox.front() && *mailbox.front() == event);
            mailbox.pop();
        };
        expect("metadata:" + id);
        for (int j = 0; j < burst; ++j) expect("error:" + id);
        expect("completed:" + id);
        expect("stopped:" + id);
    }
    assert(!mailbox.front());
    assert(mailbox.job_count() == 0);

    mailbox.add("a");
    mailbox.add("b");
    mailbox.critical("a", Kind::error, "error a");
    mailbox.critical("b", Kind::metadata, "metadata b");
    mailbox.critical("a", Kind::error, "error a");
    mailbox.critical("a", Kind::metadata, "metadata a");
    mailbox.critical("a", Kind::error, "error a");
    for (auto const* expected : {"error a", "error a", "metadata b", "metadata a", "error a"}) {
        assert(*mailbox.front() == expected);
        mailbox.pop();
    }
    for (int i = 0; i < burst; ++i) mailbox.status("a", std::to_string(i));
    assert(*mailbox.front() == "4095");
    // Looking at an event without acknowledging it cannot consume it.
    assert(*mailbox.front() == "4095");
    mailbox.pop();
    assert(!mailbox.front());
    mailbox.retire("a");
    mailbox.retire("b");

    for (std::size_t i = 0; i < Mailbox::max_jobs; ++i) {
        auto id = std::to_string(i);
        mailbox.add(id);
        mailbox.critical(id, Kind::metadata, id);
        mailbox.retire(id);
    }
    assert(!mailbox.can_add("overflow"));
    assert(!mailbox.can_add("0"));
    mailbox.pop();
    assert(mailbox.can_add("overflow"));
    while (mailbox.front()) mailbox.pop();
    assert(mailbox.job_count() == 0);

    // Exercise the full reservation, including error runs on both sides of
    // every possible one-shot transition and no acknowledgement until full.
    for (std::size_t i = 0; i < Mailbox::max_jobs; ++i) {
        auto id = std::to_string(i);
        mailbox.add(id);
        mailbox.critical(id, Kind::error, "error");
        for (auto kind : {Kind::metadata, Kind::completed, Kind::stopped, Kind::invalid_selection}) {
            mailbox.critical(id, kind, "transition");
            mailbox.critical(id, Kind::error, "error");
        }
        mailbox.retire(id);
    }
    assert(mailbox.critical_size() == Mailbox::max_critical_entries);
    std::size_t delivered = 0;
    while (mailbox.front()) { mailbox.pop(); ++delivered; }
    assert(delivered == Mailbox::max_critical_entries);
    assert(mailbox.job_count() == 0);
    std::cout << "Native event mailbox stress tests passed.\n";
}
