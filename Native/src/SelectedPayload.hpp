#pragma once

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdint>
#include <string>
#include <vector>

namespace ltkit {
struct SelectedPayload {
    std::string path;
    std::int64_t size;
};

// Fresh descriptor/stat for every selected payload; no cached URL attributes.
// fsync catches final write failures before completion is made observable.
inline bool sync_selected_payloads(std::vector<SelectedPayload> const& files) {
    if (files.empty()) return false;
    bool ready = true;
    for (auto const& file : files) {
        int const fd = ::open(file.path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (fd < 0) { ready = false; continue; }
        struct stat attributes{};
        bool const valid = ::fstat(fd, &attributes) == 0 && S_ISREG(attributes.st_mode)
            && attributes.st_size >= file.size;
        if (!valid || ::fsync(fd) != 0) ready = false;
        if (::close(fd) != 0) ready = false;
    }
    return ready;
}
}
