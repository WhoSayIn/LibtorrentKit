#ifndef LIBTORRENT_NATIVE_H
#define LIBTORRENT_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define LTKIT_EXPORT __declspec(dllexport)
#else
#define LTKIT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ltkit_session ltkit_session_t;

typedef struct {
    uint8_t *data;
    size_t size;
} ltkit_buffer_t;

typedef struct {
    const char *user_agent;
    const char *ca_bundle_path;
    uint16_t listen_port_start;
    uint16_t listen_port_end;
    bool enable_dht;
    bool enable_lsd;
    bool enable_upnp;
    bool enable_natpmp;
} ltkit_session_configuration_t;

enum {
    LTKIT_OK = 0,
    LTKIT_ERROR_UNKNOWN = 1,
    LTKIT_ERROR_INVALID_ARGUMENT = 2,
    LTKIT_ERROR_INVALID_SOURCE = 3,
    LTKIT_ERROR_INVALID_IDENTIFIER = 4,
    LTKIT_ERROR_DUPLICATE_IDENTIFIER = 5,
    LTKIT_ERROR_METADATA_UNAVAILABLE = 6,
    LTKIT_ERROR_INVALID_FILE_INDEX = 7,
    LTKIT_ERROR_INVALID_PIECE_INDEX = 8,
    LTKIT_ERROR_INVALID_OFFSET = 9,
    LTKIT_ERROR_CORRUPT_RESUME_DATA = 10,
    LTKIT_ERROR_TIMED_OUT = 11,
    LTKIT_ERROR_NATIVE_FAILURE = 12,
    LTKIT_ERROR_SESSION_SHUT_DOWN = 13,
    LTKIT_ERROR_ALLOCATION_LIMIT = 14,
    LTKIT_ERROR_PATH_VIOLATION = 15,
};

LTKIT_EXPORT int32_t ltkit_session_create(
    const ltkit_session_configuration_t *configuration,
    ltkit_session_t **out_session);
LTKIT_EXPORT void ltkit_session_wake(ltkit_session_t *session);
LTKIT_EXPORT void ltkit_session_destroy(ltkit_session_t *session);

LTKIT_EXPORT int32_t ltkit_session_add(
    ltkit_session_t *session,
    const char *identifier,
    int32_t source_kind,
    const uint8_t *source,
    size_t source_size,
    const uint8_t *resume_data,
    size_t resume_size,
    const char *download_directory,
    const int32_t *selected_files,
    size_t selected_file_count,
    bool has_file_selection,
    int32_t primary_file_index,
    bool begins_paused,
    int32_t download_limit,
    int32_t upload_limit,
    int32_t completion_policy);

LTKIT_EXPORT int32_t ltkit_session_metadata(
    ltkit_session_t *session, const char *identifier, int32_t timeout_ms, ltkit_buffer_t *out_json);
LTKIT_EXPORT int32_t ltkit_session_select_files(
    ltkit_session_t *session, const char *identifier, const int32_t *indexes, size_t count, int32_t primary_index);
LTKIT_EXPORT int32_t ltkit_session_set_file_priority(
    ltkit_session_t *session, const char *identifier, int32_t file_index, uint8_t priority);
LTKIT_EXPORT int32_t ltkit_session_set_piece_priority(
    ltkit_session_t *session, const char *identifier, int32_t piece_index, uint8_t priority);
LTKIT_EXPORT int32_t ltkit_session_start(ltkit_session_t *session, const char *identifier);
LTKIT_EXPORT int32_t ltkit_session_pause(ltkit_session_t *session, const char *identifier);
LTKIT_EXPORT int32_t ltkit_session_status(ltkit_session_t *session, const char *identifier, ltkit_buffer_t *out_json);
LTKIT_EXPORT int32_t ltkit_session_pieces(ltkit_session_t *session, const char *identifier, ltkit_buffer_t *out_json);
LTKIT_EXPORT int32_t ltkit_session_update_streaming_window(
    ltkit_session_t *session,
    const char *identifier,
    int32_t file_index,
    int64_t byte_offset,
    int64_t forward_buffer_bytes,
    bool prioritize_edges,
    ltkit_buffer_t *out_json);
LTKIT_EXPORT int32_t ltkit_session_clear_streaming_window(ltkit_session_t *session, const char *identifier);
LTKIT_EXPORT int32_t ltkit_session_checkpoint(
    ltkit_session_t *session, const char *identifier, bool flush_disk_cache, int32_t timeout_ms, ltkit_buffer_t *out_data);
LTKIT_EXPORT int32_t ltkit_session_remove(ltkit_session_t *session, const char *identifier, bool delete_files);
LTKIT_EXPORT int32_t ltkit_session_next_event(ltkit_session_t *session, int32_t timeout_ms, ltkit_buffer_t *out_json);
LTKIT_EXPORT int32_t ltkit_session_take_last_error(ltkit_session_t *session, ltkit_buffer_t *out_utf8);
LTKIT_EXPORT void ltkit_buffer_free(ltkit_buffer_t buffer);

#ifdef __cplusplus
}
#endif

#endif
