#include "LibtorrentNative.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/extensions/ut_metadata.hpp>
#include <libtorrent/extensions/ut_pex.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/write_resume_data.hpp>

#if defined(__APPLE__) && (!TORRENT_USE_COMMONCRYPTO || defined(TORRENT_USE_LIBCRYPTO))
#error "Apple builds must use CommonCrypto for hashing while OpenSSL remains the TLS provider"
#endif

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace lt = libtorrent;
using namespace std::chrono_literals;

namespace {
constexpr std::size_t kMaxSourceBytes = 64u * 1024u * 1024u;
constexpr std::size_t kMaxResumeBytes = 64u * 1024u * 1024u;
constexpr std::size_t kMaxEvents = 256;
constexpr int kNormalPriority = 4;
constexpr int kTopPriority = 7;

std::string json_escape(std::string const& input) {
    std::ostringstream out;
    for (unsigned char c : input) {
        switch (c) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\b': out << "\\b"; break;
        case '\f': out << "\\f"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (c < 0x20) out << "?";
            else out << static_cast<char>(c);
        }
    }
    return out.str();
}

bool safe_relative_path(lt::file_storage const& files, lt::file_index_t index, std::string& output) {
    if (files.file_absolute_path(index)) return false;
    std::filesystem::path path(files.file_path(index));
    if (path.empty() || path.is_absolute() || path.has_root_path()) return false;
    std::filesystem::path clean;
    for (auto const& component : path) {
        if (component == "..") return false;
        if (component == "." || component.empty()) continue;
        clean /= component;
    }
    output = clean.generic_string();
    return !output.empty() && output.size() <= 4096;
}

bool copy_buffer(std::vector<char> const& source, ltkit_buffer_t* output) {
    if (output == nullptr) return false;
    output->data = nullptr;
    output->size = 0;
    if (source.empty()) return true;
    auto* bytes = static_cast<std::uint8_t*>(std::malloc(source.size()));
    if (bytes == nullptr) return false;
    std::memcpy(bytes, source.data(), source.size());
    output->data = bytes;
    output->size = source.size();
    return true;
}

bool copy_buffer(std::string const& source, ltkit_buffer_t* output) {
    return copy_buffer(std::vector<char>(source.begin(), source.end()), output);
}

std::string state_name(lt::torrent_status const& status, bool stopped) {
    if (stopped) return "stopped";
    if ((status.flags & lt::torrent_flags::paused) != lt::torrent_flags_t{}) return "paused";
    switch (status.state) {
    case lt::torrent_status::checking_files: return "checkingFiles";
    case lt::torrent_status::downloading_metadata: return "downloadingMetadata";
    case lt::torrent_status::downloading: return "downloading";
    case lt::torrent_status::finished: return "finished";
    case lt::torrent_status::seeding: return "seeding";
    case lt::torrent_status::checking_resume_data: return "checkingResumeData";
    default: return "unknown";
    }
}

std::string status_json(lt::torrent_status const& status, bool stopped = false) {
    auto const paused = stopped || ((status.flags & lt::torrent_flags::paused) != lt::torrent_flags_t{});
    std::ostringstream out;
    out << "{\"state\":\"" << state_name(status, stopped) << "\""
        << ",\"progress\":" << std::clamp(double(status.progress_ppm) / 1000000.0, 0.0, 1.0)
        << ",\"totalBytes\":" << status.total_wanted
        << ",\"completedBytes\":" << status.total_wanted_done
        << ",\"downloadRate\":" << (stopped ? 0 : status.download_payload_rate)
        << ",\"uploadRate\":" << (stopped ? 0 : status.upload_payload_rate)
        << ",\"connectedPeers\":" << (stopped ? 0 : status.num_peers)
        << ",\"isPaused\":" << (paused ? "true" : "false")
        << ",\"hasMetadata\":" << (status.has_metadata ? "true" : "false")
        << ",\"isParticipatingInSwarm\":" << ((!stopped && !paused) ? "true" : "false") << "}";
    return out.str();
}
}

struct ltkit_session {
    struct checkpoint_state {
        bool active = false;
        bool done = false;
        int32_t error = LTKIT_OK;
        std::vector<char> data;
    };

    struct job {
        lt::torrent_handle handle;
        std::vector<int32_t> desired_files;
        std::vector<lt::download_priority_t> file_priorities;
        std::vector<lt::download_priority_t> piece_priorities;
        int32_t primary_file = -1;
        bool metadata_ready = false;
        bool completion_stops = true;
        bool completion_checkpoint = false;
        bool completion_waiting = false;
        bool stopped = false;
        std::optional<lt::torrent_status> final_status;
        std::set<int> deadline_pieces;
        checkpoint_state checkpoint;
    };

    std::recursive_mutex mutex;
    std::condition_variable_any condition;
    std::unique_ptr<lt::session> engine;
    std::unordered_map<std::string, job> jobs;
    std::deque<std::string> events;
    std::string last_error;
    bool shutting_down = false;
    std::thread alert_thread;

    void set_error(std::string value) {
        std::lock_guard lock(mutex);
        last_error = std::move(value);
    }

    void enqueue(std::string event) {
        if (events.size() == kMaxEvents) events.pop_front();
        events.push_back(std::move(event));
        condition.notify_all();
    }

    std::optional<std::string> id_for(lt::torrent_handle const& handle) {
        for (auto const& [id, value] : jobs) if (value.handle == handle) return id;
        return std::nullopt;
    }

    bool apply_selection(job& value) {
        auto info = value.handle.torrent_file();
        if (!info) return false;
        auto const count = info->layout().num_files();
        if (value.file_priorities.size() != std::size_t(count)) {
            value.file_priorities.assign(std::size_t(count), lt::dont_download);
            for (auto index : value.desired_files) {
                if (index < 0 || index >= count) return false;
                value.file_priorities[std::size_t(index)] = lt::default_priority;
            }
        }
        value.handle.prioritize_files(value.file_priorities);
        if (value.piece_priorities.size() != std::size_t(info->num_pieces())) {
            value.piece_priorities.assign(std::size_t(info->num_pieces()), lt::dont_download);
            auto const& files = info->layout();
            for (lt::file_index_t index{0}; index < files.end_file(); ++index) {
                auto const offset = std::size_t(static_cast<int>(index));
                if (offset >= value.file_priorities.size() || value.file_priorities[offset] == lt::dont_download
                    || files.file_size(index) == 0) continue;
                auto const first = static_cast<int>(files.piece_index_at_file(index));
                auto const last = static_cast<int>(files.last_piece_index_at_file(index));
                for (int piece = first; piece <= last; ++piece) {
                    auto& current = value.piece_priorities[std::size_t(piece)];
                    if (current < value.file_priorities[offset]) current = value.file_priorities[offset];
                }
            }
        }
        value.handle.prioritize_pieces(value.piece_priorities);
        value.deadline_pieces.clear();
        value.handle.clear_piece_deadlines();
        return true;
    }

    void alerts() {
        while (true) {
            engine->wait_for_alert(500ms);
            std::vector<lt::alert*> alerts;
            engine->pop_alerts(&alerts);
            std::lock_guard lock(mutex);
            if (shutting_down) break;
            for (auto* alert : alerts) {
                auto const* torrent_alert = dynamic_cast<lt::torrent_alert const*>(alert);
                if (torrent_alert == nullptr) continue;
                auto id = id_for(torrent_alert->handle);
                if (!id) continue;
                auto found = jobs.find(*id);
                if (found == jobs.end()) continue;
                auto& value = found->second;

                if (lt::alert_cast<lt::metadata_received_alert>(alert)) {
                    value.metadata_ready = true;
                    if (!apply_selection(value)) {
                        value.handle.pause();
                        engine->remove_torrent(value.handle);
                        value.stopped = true;
                        enqueue("{\"type\":\"event\",\"kind\":\"error\",\"id\":\"" + *id
                            + "\",\"code\":7,\"description\":\"A requested file index is invalid.\"}");
                    } else {
                        enqueue("{\"kind\":\"metadataReady\",\"id\":\"" + *id + "\"}");
                    }
                    condition.notify_all();
                } else if (auto const* piece = lt::alert_cast<lt::piece_finished_alert>(alert)) {
                    enqueue("{\"kind\":\"pieceCompleted\",\"id\":\"" + *id
                        + "\",\"pieceIndex\":" + std::to_string(static_cast<int>(piece->piece_index)) + "}");
                } else if (lt::alert_cast<lt::torrent_finished_alert>(alert) && value.completion_stops
                    && value.handle.status().total_wanted > 0) {
                    auto status = value.handle.status();
                    value.final_status = status;
                    enqueue("{\"kind\":\"completed\",\"id\":\"" + *id + "\",\"status\":" + status_json(status) + "}");
                    value.handle.pause();
                    if (!value.checkpoint.active) {
                        value.completion_checkpoint = true;
                        value.handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
                    } else value.completion_waiting = true;
                } else if (auto const* resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                    auto data = lt::write_resume_data_buf(resume->params);
                    if (value.checkpoint.active) {
                        value.checkpoint.data = std::move(data);
                        value.checkpoint.done = true;
                        value.checkpoint.error = LTKIT_OK;
                    } else if (value.completion_checkpoint) {
                        engine->remove_torrent(value.handle);
                        value.completion_checkpoint = false;
                        value.stopped = true;
                        enqueue("{\"kind\":\"stoppedAfterCompletion\",\"id\":\"" + *id + "\"}");
                    }
                    condition.notify_all();
                } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                    if (value.checkpoint.active) {
                        value.checkpoint.done = true;
                        value.checkpoint.error = LTKIT_ERROR_NATIVE_FAILURE;
                    } else if (value.completion_checkpoint) {
                        engine->remove_torrent(value.handle);
                        value.completion_checkpoint = false;
                        value.stopped = true;
                        enqueue("{\"kind\":\"stoppedAfterCompletion\",\"id\":\"" + *id + "\"}");
                    }
                    condition.notify_all();
                } else if (lt::alert_cast<lt::torrent_error_alert>(alert)) {
                    enqueue("{\"kind\":\"error\",\"id\":\"" + *id
                        + "\",\"code\":12,\"description\":\"The torrent engine reported a recoverable error.\"}");
                } else if (lt::alert_cast<lt::state_changed_alert>(alert)) {
                    enqueue("{\"kind\":\"statusChanged\",\"id\":\"" + *id
                        + "\",\"status\":" + status_json(value.handle.status(), value.stopped) + "}");
                }
            }
        }
    }
};

namespace {
int32_t fail(ltkit_session_t* session, int32_t code, char const* safe_message) {
    if (session) session->set_error(safe_message);
    return code;
}

ltkit_session::job* find_job(ltkit_session_t* session, char const* identifier) {
    if (!session || !identifier) return nullptr;
    auto found = session->jobs.find(identifier);
    return found == session->jobs.end() ? nullptr : &found->second;
}

template <typename F>
int32_t guarded(ltkit_session_t* session, F&& function) noexcept {
    try { return function(); }
    catch (std::bad_alloc const&) { return fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "A native allocation limit was reached."); }
    catch (std::exception const&) { return fail(session, LTKIT_ERROR_NATIVE_FAILURE, "The native torrent operation failed."); }
    catch (...) { return fail(session, LTKIT_ERROR_UNKNOWN, "An unknown native torrent error occurred."); }
}

std::string metadata_json(ltkit_session::job& value, bool& safe) {
    auto info = value.handle.torrent_file();
    if (!info) return {};
    auto const& files = info->layout();
    auto progress = value.handle.file_progress(lt::torrent_handle::piece_granularity);
    auto file_priorities = value.handle.get_file_priorities();
    auto const hashes = info->info_hashes();
    std::ostringstream out;
    out << "{\"name\":\"" << json_escape(info->name()) << "\"";
    if (hashes.has_v1()) out << ",\"infoHashV1\":\"" << lt::aux::to_hex(hashes.v1) << "\"";
    else out << ",\"infoHashV1\":null";
    if (hashes.has_v2()) out << ",\"infoHashV2\":\"" << lt::aux::to_hex(hashes.v2) << "\"";
    else out << ",\"infoHashV2\":null";
    out << ",\"pieceLength\":" << info->piece_length()
        << ",\"pieceCount\":" << info->num_pieces()
        << ",\"totalBytes\":" << info->total_size();
    if (info->creation_date() > 0) out << ",\"creationDate\":" << info->creation_date();
    else out << ",\"creationDate\":null";
    if (!info->creator().empty()) out << ",\"creator\":\"" << json_escape(info->creator()) << "\"";
    else out << ",\"creator\":null";
    out << ",\"files\":[";
    for (lt::file_index_t index{0}; index < files.end_file(); ++index) {
        if (index != lt::file_index_t{0}) out << ',';
        std::string path;
        if (!safe_relative_path(files, index, path)) { safe = false; return {}; }
        auto const size = files.file_size(index);
        out << "{\"index\":" << static_cast<int>(index)
            << ",\"path\":\"" << json_escape(path) << "\""
            << ",\"size\":" << size
            << ",\"torrentOffset\":" << files.file_offset(index);
        if (size > 0) {
            out << ",\"firstPieceIndex\":" << static_cast<int>(files.piece_index_at_file(index))
                << ",\"lastPieceIndex\":" << static_cast<int>(files.last_piece_index_at_file(index));
        } else {
            out << ",\"firstPieceIndex\":null,\"lastPieceIndex\":null";
        }
        auto const offset = std::size_t(static_cast<int>(index));
        auto const selected = offset < file_priorities.size() && file_priorities[offset] != lt::dont_download;
        auto const complete = offset < progress.size() ? progress[offset] : 0;
        out << ",\"isSelected\":" << (selected ? "true" : "false")
            << ",\"completedBytes\":" << complete << "}";
    }
    out << "]}";
    safe = true;
    return out.str();
}
}

extern "C" {
int32_t ltkit_session_create(ltkit_session_configuration_t const* configuration, ltkit_session_t** output) {
    if (!configuration || !output || !configuration->user_agent || !configuration->ca_bundle_path
        || configuration->listen_port_start > configuration->listen_port_end) return LTKIT_ERROR_INVALID_ARGUMENT;
    try {
        if (!std::filesystem::is_regular_file(configuration->ca_bundle_path)) return LTKIT_ERROR_INVALID_ARGUMENT;
        setenv("SSL_CERT_FILE", configuration->ca_bundle_path, 1);
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::user_agent, configuration->user_agent);
        settings.set_str(lt::settings_pack::listen_interfaces,
            "0.0.0.0:" + std::to_string(configuration->listen_port_start) + ",[::]:" + std::to_string(configuration->listen_port_start));
        settings.set_bool(lt::settings_pack::enable_dht, configuration->enable_dht);
        settings.set_bool(lt::settings_pack::enable_lsd, configuration->enable_lsd);
        settings.set_bool(lt::settings_pack::enable_upnp, configuration->enable_upnp);
        settings.set_bool(lt::settings_pack::enable_natpmp, configuration->enable_natpmp);
        settings.set_bool(lt::settings_pack::validate_https_trackers, true);
        settings.set_int(lt::settings_pack::alert_mask,
            lt::alert_category::error | lt::alert_category::storage | lt::alert_category::status);
        auto session = std::make_unique<ltkit_session>();
        session->engine = std::make_unique<lt::session>(settings);
        session->alert_thread = std::thread([raw = session.get()] { raw->alerts(); });
        *output = session.release();
        return LTKIT_OK;
    } catch (...) { return LTKIT_ERROR_NATIVE_FAILURE; }
}

void ltkit_session_wake(ltkit_session_t* session) {
    if (!session) return;
    std::lock_guard lock(session->mutex);
    session->condition.notify_all();
}

void ltkit_session_destroy(ltkit_session_t* session) {
    if (!session) return;
    {
        std::lock_guard lock(session->mutex);
        if (session->shutting_down) return;
        session->shutting_down = true;
        session->condition.notify_all();
    }
    session->engine->abort();
    if (session->alert_thread.joinable()) session->alert_thread.join();
    delete session;
}

int32_t ltkit_session_add(
    ltkit_session_t* session, char const* identifier, int32_t source_kind,
    uint8_t const* source, size_t source_size, uint8_t const* resume_data, size_t resume_size,
    char const* download_directory, int32_t const* selected_files, size_t selected_count,
    bool has_file_selection, int32_t primary_file, bool begins_paused,
    int32_t download_limit, int32_t upload_limit, int32_t completion_policy) {
    if (!session || !identifier || !*identifier || !source || source_size == 0 || !download_directory
        || source_size > kMaxSourceBytes || resume_size > kMaxResumeBytes || (selected_count > 0 && !selected_files)
        || selected_count > 100000 || primary_file < -1 || completion_policy < 0 || completion_policy > 1)
        return fail(session, LTKIT_ERROR_INVALID_ARGUMENT, "The add request is invalid.");
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        if (session->shutting_down) return fail(session, LTKIT_ERROR_SESSION_SHUT_DOWN, "The torrent session has shut down.");
        if (session->jobs.find(identifier) != session->jobs.end()) return fail(session, LTKIT_ERROR_DUPLICATE_IDENTIFIER, "The torrent identifier already exists.");
        if (!std::filesystem::path(download_directory).is_absolute())
            return fail(session, LTKIT_ERROR_INVALID_ARGUMENT, "The download directory must be absolute.");

        lt::error_code error;
        lt::add_torrent_params source_params;
        auto chars = lt::span<char const>(reinterpret_cast<char const*>(source), source_size);
        if (source_kind == 0) source_params = lt::parse_magnet_uri(std::string_view(chars.data(), chars.size()), error);
        else if (source_kind == 1) source_params = lt::load_torrent_buffer(chars, error, lt::load_torrent_limits{});
        else return fail(session, LTKIT_ERROR_INVALID_SOURCE, "The torrent source kind is invalid.");
        if (error) return fail(session, LTKIT_ERROR_INVALID_SOURCE, "The torrent source could not be parsed.");

        lt::add_torrent_params params = std::move(source_params);
        if (resume_size > 0) {
            auto resume_chars = lt::span<char const>(reinterpret_cast<char const*>(resume_data), resume_size);
            auto restored = lt::read_resume_data(resume_chars, error);
            if (error) return fail(session, LTKIT_ERROR_CORRUPT_RESUME_DATA, "The resume data is corrupt or incompatible.");
            if (params.ti) restored.ti = params.ti;
            if (!restored.info_hashes.has_v1() && !restored.info_hashes.has_v2()) restored.info_hashes = params.info_hashes;
            params = std::move(restored);
        }
        params.save_path = download_directory;
        params.flags |= lt::torrent_flags::default_dont_download;
        if (begins_paused) params.flags |= lt::torrent_flags::paused;
        else params.flags &= ~lt::torrent_flags::paused;
        params.download_limit = std::max(0, download_limit);
        params.upload_limit = std::max(0, upload_limit);

        std::vector<int32_t> desired;
        if (has_file_selection && selected_count > 0) desired.assign(selected_files, selected_files + selected_count);
        else {
            for (std::size_t index = 0; index < params.file_priorities.size(); ++index) {
                if (params.file_priorities[index] != lt::dont_download) desired.push_back(static_cast<int32_t>(index));
            }
        }
        if (params.ti && has_file_selection) {
            auto const count = params.ti->layout().num_files();
            params.file_priorities.assign(std::size_t(count), lt::dont_download);
            for (auto index : desired) {
                if (index < 0 || index >= count) return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "A requested file index is invalid.");
                params.file_priorities[std::size_t(index)] = lt::default_priority;
            }
        }
        auto initial_file_priorities = params.file_priorities;
        auto initial_piece_priorities = params.piece_priorities;
        auto handle = session->engine->add_torrent(std::move(params), error);
        if (error) return fail(session, LTKIT_ERROR_NATIVE_FAILURE, "The torrent could not be added.");
        ltkit_session::job value;
        value.handle = handle;
        value.desired_files = std::move(desired);
        value.file_priorities = std::move(initial_file_priorities);
        value.piece_priorities = std::move(initial_piece_priorities);
        value.primary_file = primary_file;
        value.metadata_ready = bool(handle.torrent_file());
        value.completion_stops = completion_policy == 0;
        session->jobs.emplace(identifier, std::move(value));
        if (handle.torrent_file()) session->enqueue("{\"kind\":\"metadataReady\",\"id\":\"" + std::string(identifier) + "\"}");
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_metadata(ltkit_session_t* session, char const* identifier, int32_t timeout_ms, ltkit_buffer_t* output) {
    if (!session || !identifier || !output || timeout_ms < 0) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::unique_lock lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        if (!value->metadata_ready) {
            if (!session->condition.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
                auto* current = find_job(session, identifier);
                return session->shutting_down || !current || current->metadata_ready || current->stopped;
            })) return fail(session, LTKIT_ERROR_TIMED_OUT, "Metadata acquisition timed out.");
            value = find_job(session, identifier);
        }
        if (!value || value->stopped || !value->handle.torrent_file())
            return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        bool safe = false;
        auto json = metadata_json(*value, safe);
        if (!safe) {
            value->handle.pause();
            session->engine->remove_torrent(value->handle);
            value->stopped = true;
            return fail(session, LTKIT_ERROR_PATH_VIOLATION, "Torrent metadata contains an unsafe file path.");
        }
        return copy_buffer(json, output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The metadata response could not be allocated.");
    });
}

int32_t ltkit_session_select_files(ltkit_session_t* session, char const* identifier, int32_t const* indexes, size_t count, int32_t primary) {
    if (!session || !identifier || (count > 0 && !indexes) || count > 100000 || primary < -1) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        if (!value->handle.torrent_file()) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        value->desired_files.assign(indexes, indexes + count);
        value->file_priorities.clear();
        value->piece_priorities.clear();
        value->primary_file = primary;
        if (primary >= 0 && std::find(value->desired_files.begin(), value->desired_files.end(), primary) == value->desired_files.end())
            return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "The primary file must be selected.");
        if (!session->apply_selection(*value)) return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "A requested file index is invalid.");
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_set_file_priority(
    ltkit_session_t* session, char const* identifier, int32_t file_index, uint8_t priority) {
    if (!session || !identifier || file_index < 0 || priority > 7) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        auto info = value->handle.torrent_file();
        if (!info) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        auto const count = info->layout().num_files();
        if (file_index >= count) return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "The file index is invalid.");
        if (value->file_priorities.size() != std::size_t(count)) {
            value->file_priorities = value->handle.get_file_priorities();
            value->file_priorities.resize(std::size_t(count), lt::dont_download);
        }
        value->file_priorities[std::size_t(file_index)] = lt::download_priority_t{priority};
        value->desired_files.clear();
        for (int32_t index = 0; index < count; ++index) {
            if (value->file_priorities[std::size_t(index)] != lt::dont_download) value->desired_files.push_back(index);
        }
        value->piece_priorities.clear();
        if (!session->apply_selection(*value)) return fail(session, LTKIT_ERROR_NATIVE_FAILURE, "The file priority could not be applied.");
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_set_piece_priority(
    ltkit_session_t* session, char const* identifier, int32_t piece_index, uint8_t priority) {
    if (!session || !identifier || piece_index < 0 || priority > 7) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        auto info = value->handle.torrent_file();
        if (!info) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        if (piece_index >= info->num_pieces()) return fail(session, LTKIT_ERROR_INVALID_PIECE_INDEX, "The piece index is invalid.");
        if (value->piece_priorities.size() != std::size_t(info->num_pieces())) {
            value->piece_priorities = value->handle.get_piece_priorities();
            value->piece_priorities.resize(std::size_t(info->num_pieces()), lt::dont_download);
        }
        value->piece_priorities[std::size_t(piece_index)] = lt::download_priority_t{priority};
        value->handle.piece_priority(lt::piece_index_t{piece_index}, lt::download_priority_t{priority});
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_start(ltkit_session_t* session, char const* identifier) {
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        value->handle.resume();
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_pause(ltkit_session_t* session, char const* identifier) {
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        value->handle.pause();
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_status(ltkit_session_t* session, char const* identifier, ltkit_buffer_t* output) {
    if (!session || !identifier || !output) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier does not exist.");
        auto const status = value->stopped && value->final_status ? *value->final_status : value->handle.status();
        return copy_buffer(status_json(status, value->stopped), output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The status response could not be allocated.");
    });
}

int32_t ltkit_session_pieces(ltkit_session_t* session, char const* identifier, ltkit_buffer_t* output) {
    if (!session || !identifier || !output) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        auto info = value->handle.torrent_file();
        if (!info) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        auto priorities = value->handle.get_piece_priorities();
        std::vector<int> availability;
        value->handle.piece_availability(availability);
        std::ostringstream out;
        out << "{\"completed\":[";
        for (int i = 0; i < info->num_pieces(); ++i) { if (i) out << ','; out << (value->handle.have_piece(lt::piece_index_t{i}) ? "true" : "false"); }
        out << "],\"availability\":[";
        for (std::size_t i = 0; i < priorities.size(); ++i) { if (i) out << ','; out << (i < availability.size() ? availability[i] : 0); }
        out << "],\"priorities\":[";
        for (std::size_t i = 0; i < priorities.size(); ++i) { if (i) out << ','; out << lt::aux::to_string(priorities[i]); }
        out << "],\"deadlinePieceIndexes\":[";
        bool first = true;
        for (auto piece : value->deadline_pieces) { if (!first) out << ','; first = false; out << piece; }
        out << "]}";
        return copy_buffer(out.str(), output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The piece response could not be allocated.");
    });
}

int32_t ltkit_session_update_streaming_window(
    ltkit_session_t* session, char const* identifier, int32_t file_index, int64_t byte_offset,
    int64_t forward_bytes, bool prioritize_edges, ltkit_buffer_t* output) {
    if (!session || !identifier || !output || file_index < 0 || byte_offset < 0 || forward_bytes < 0) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        auto info = value->handle.torrent_file();
        if (!info) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        auto const& files = info->layout();
        if (file_index >= files.num_files()) return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "The streaming file index is invalid.");
        if (std::find(value->desired_files.begin(), value->desired_files.end(), file_index) == value->desired_files.end())
            return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "The streaming file must be selected.");
        auto const size = files.file_size(lt::file_index_t{file_index});
        if (size <= 0 || byte_offset >= size) return fail(session, LTKIT_ERROR_INVALID_OFFSET, "The streaming byte offset is outside the file.");

        value->handle.clear_piece_deadlines();
        if (!session->apply_selection(*value)) return fail(session, LTKIT_ERROR_INVALID_FILE_INDEX, "A requested file index is invalid.");
        auto const piece_length = info->piece_length();
        auto const file_offset = files.file_offset(lt::file_index_t{file_index});
        auto const file_first = static_cast<int>(files.piece_index_at_file(lt::file_index_t{file_index}));
        auto const file_last = static_cast<int>(files.last_piece_index_at_file(lt::file_index_t{file_index}));
        auto const playback = std::clamp(int((file_offset + byte_offset) / piece_length), file_first, file_last);
        auto const bounded_end = forward_bytes == 0 ? byte_offset
            : byte_offset + std::min<std::int64_t>(size - 1 - byte_offset, forward_bytes - 1);
        auto const last = std::clamp(int((file_offset + bounded_end) / piece_length), playback, file_last);

        std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> raised;
        if (prioritize_edges) {
            raised.emplace_back(lt::piece_index_t{file_first}, lt::top_priority);
            if (file_last != file_first) raised.emplace_back(lt::piece_index_t{file_last}, lt::top_priority);
        }
        value->deadline_pieces.clear();
        for (int piece = playback; piece <= last; ++piece) {
            raised.emplace_back(lt::piece_index_t{piece}, lt::top_priority);
            value->handle.set_piece_deadline(lt::piece_index_t{piece}, 100 + (piece - playback) * 250);
            value->deadline_pieces.insert(piece);
        }
        value->handle.prioritize_pieces(raised);
        value->handle.set_sequential_range(lt::piece_index_t{playback}, lt::piece_index_t{last});
        value->primary_file = file_index;

        std::ostringstream out;
        out << "{\"fileIndex\":" << file_index << ",\"requestedByteOffset\":" << byte_offset
            << ",\"firstPieceIndex\":" << playback << ",\"lastPieceIndex\":" << last
            << ",\"playbackPieceIndex\":" << playback << ",\"prioritizedPieceIndexes\":[";
        for (int piece = playback; piece <= last; ++piece) { if (piece != playback) out << ','; out << piece; }
        out << "],\"deadlinePieceIndexes\":[";
        for (int piece = playback; piece <= last; ++piece) { if (piece != playback) out << ','; out << piece; }
        out << "]}";
        return copy_buffer(out.str(), output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The streaming response could not be allocated.");
    });
}

int32_t ltkit_session_clear_streaming_window(ltkit_session_t* session, char const* identifier) {
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        value->handle.clear_piece_deadlines();
        value->deadline_pieces.clear();
        if (!session->apply_selection(*value)) return fail(session, LTKIT_ERROR_METADATA_UNAVAILABLE, "Torrent metadata is unavailable.");
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_checkpoint(
    ltkit_session_t* session, char const* identifier, bool flush, int32_t timeout_ms, ltkit_buffer_t* output) {
    if (!session || !identifier || !output || timeout_ms <= 0) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::unique_lock lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value || value->stopped) return fail(session, LTKIT_ERROR_INVALID_IDENTIFIER, "The torrent identifier is not active.");
        if (value->checkpoint.active || value->completion_checkpoint)
            return fail(session, LTKIT_ERROR_NATIVE_FAILURE, "A checkpoint is already pending for this torrent.");
        value->checkpoint = {.active = true};
        auto flags = lt::torrent_handle::save_info_dict;
        if (flush) flags |= lt::torrent_handle::flush_disk_cache;
        value->handle.save_resume_data(flags);
        auto const completed = session->condition.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
            auto* current = find_job(session, identifier);
            return session->shutting_down || !current || current->checkpoint.done;
        });
        value = find_job(session, identifier);
        if (!completed || !value) {
            if (value) {
                value->checkpoint.active = false;
                if (value->completion_waiting) {
                    value->completion_waiting = false;
                    value->completion_checkpoint = true;
                    value->handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
                }
            }
            return fail(session, LTKIT_ERROR_TIMED_OUT, "The checkpoint request timed out.");
        }
        auto checkpoint = std::move(value->checkpoint);
        value->checkpoint = {};
        if (value->completion_waiting) {
            value->completion_waiting = false;
            value->completion_checkpoint = true;
            value->handle.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
        }
        if (checkpoint.error != LTKIT_OK) return fail(session, checkpoint.error, "The checkpoint request failed.");
        return copy_buffer(checkpoint.data, output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The checkpoint response could not be allocated.");
    });
}

int32_t ltkit_session_remove(ltkit_session_t* session, char const* identifier, bool delete_files) {
    if (!session || !identifier) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::lock_guard lock(session->mutex);
        auto* value = find_job(session, identifier);
        if (!value) return int32_t(LTKIT_OK);
        if (value->stopped) return int32_t(LTKIT_OK);
        if (value->checkpoint.active) return fail(session, LTKIT_ERROR_NATIVE_FAILURE, "The torrent cannot be removed while a checkpoint is pending.");
        auto flags = delete_files ? lt::session::delete_files : lt::remove_flags_t{};
        session->engine->remove_torrent(value->handle, flags);
        value->stopped = true;
        value->deadline_pieces.clear();
        return int32_t(LTKIT_OK);
    });
}

int32_t ltkit_session_next_event(ltkit_session_t* session, int32_t timeout_ms, ltkit_buffer_t* output) {
    if (!session || !output || timeout_ms < 0) return LTKIT_ERROR_INVALID_ARGUMENT;
    return guarded(session, [&] {
        std::unique_lock lock(session->mutex);
        if (session->events.empty()) session->condition.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
            return !session->events.empty() || session->shutting_down;
        });
        if (session->shutting_down) return int32_t(LTKIT_ERROR_SESSION_SHUT_DOWN);
        if (session->events.empty()) return int32_t(LTKIT_ERROR_TIMED_OUT);
        auto event = std::move(session->events.front());
        session->events.pop_front();
        return copy_buffer(event, output) ? int32_t(LTKIT_OK)
            : fail(session, LTKIT_ERROR_ALLOCATION_LIMIT, "The event response could not be allocated.");
    });
}

int32_t ltkit_session_take_last_error(ltkit_session_t* session, ltkit_buffer_t* output) {
    if (!session || !output) return LTKIT_ERROR_INVALID_ARGUMENT;
    std::lock_guard lock(session->mutex);
    auto error = std::move(session->last_error);
    session->last_error.clear();
    return copy_buffer(error, output) ? LTKIT_OK : LTKIT_ERROR_ALLOCATION_LIMIT;
}

void ltkit_buffer_free(ltkit_buffer_t buffer) { std::free(buffer.data); }
}
