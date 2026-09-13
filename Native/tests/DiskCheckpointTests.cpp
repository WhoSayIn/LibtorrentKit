#include "../src/DiskCheckpoint.hpp"
#include "../src/SelectedPayload.hpp"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>

int main() {
    using ltkit::DiskCheckpoint;
    DiskCheckpoint checkpoint;
    assert(checkpoint.begin(true));
    assert(!checkpoint.resume_saved()); // 100% / early resume data is not a disk fence.
    assert(!checkpoint.begin(true)); // Includes abandoned callers awaiting a late reply.
    assert(checkpoint.cache_flushed());
    assert(!checkpoint.cache_flushed());
    assert(checkpoint.resume_saved());
    assert(!checkpoint.resume_saved());
    checkpoint.reset();
    assert(checkpoint.begin(true));
    assert(checkpoint.fail());
    assert(!checkpoint.cache_flushed());
    assert(!checkpoint.resume_saved()); // A failed checkpoint cannot publish completion.
    checkpoint.reset();
    assert(checkpoint.begin(false));
    assert(checkpoint.resume_saved());

    auto root = std::filesystem::temp_directory_path() / "ltkit-selected-payload-XXXXXX";
    auto pattern = root.string();
    assert(::mkdtemp(pattern.data()));
    root = pattern;
    auto first = (root / "chapter-1").string();
    auto second = (root / "chapter-2").string();
    std::ofstream(first) << "first";
    std::vector<ltkit::SelectedPayload> files{{first, 5}, {second, 6}};
    assert(!ltkit::sync_selected_payloads(files)); // A non-empty subset is insufficient.
    std::ofstream(second) << "second";
    assert(ltkit::sync_selected_payloads(files));
    std::ofstream(second, std::ios::trunc) << "short";
    assert(!ltkit::sync_selected_payloads(files));
    std::filesystem::remove_all(root);
    std::cout << "Disk checkpoint ordering and selected payload tests passed\n";
}
