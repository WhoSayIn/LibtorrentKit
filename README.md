# LibtorrentKit

LibtorrentKit is a reusable Swift 6 package that wraps upstream libtorrent for
iOS 17 and newer. It provides torrent metadata, selective downloading,
piece-aware forward buffering, pause/resume, fast-resume checkpoints, and a
privacy-bounded event stream. It does not implement BitTorrent, playback,
search, persistence, or application-specific job management.

## Architecture

The package has three layers:

1. libtorrent 2.1.1 is compiled as a static library.
2. `LibtorrentNative` owns libtorrent sessions and alert processing behind
   opaque pointers and `ltkit_` C functions.
3. The Swift `TorrentSession` actor serializes control and exposes value types
   and `AsyncStream<TorrentEvent>`.

The C ABI catches every C++ exception and owns all returned buffers. C++ types
never enter Swift, avoiding Swift C++ interoperability and upstream C++ ABI
coupling. The native alert thread collects metadata, state, piece, completion,
and resume-data alerts; Swift never polls C++ torrent objects from the main
actor. See [ADR 0001](docs/adr/0001-direct-upstream-wrapper.md).

Release binaries disable libtorrent logging and hide every native symbol except
the `ltkit_` API. libtorrent selects CommonCrypto for SHA-1/SHA-256 hashing on
Apple platforms while OpenSSL remains linked for TLS trackers, TLS web seeds,
and encrypted torrents.

## Pinned inputs

| Input | Version / identity | SHA-256 |
| --- | --- | --- |
| libtorrent | `v2.1.1`, commit `56ae8caba38bf154ffc210403cb23f91d0ecaa49` | Git commit verified after fetch |
| Boost | 1.92.0 CMake source archive | `9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d` |
| OpenSSL XCFramework | 3.6.3000 packaging OpenSSL 3.6.3 | `6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c` |
| Mozilla CA extract | 2026-08-13 | `f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9` |

The build excludes upstream tests, examples, tools, Python bindings,
WebTorrent/WebRTC, and verbose logging. DHT, PEX, metadata exchange, streaming
deadlines, protocol encryption, HTTPS trackers, and web seeds remain enabled.
Third-party terms are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Bootstrap and build

Requirements are Xcode 26.6, CMake, Git, curl, and either Ninja or Make.

```sh
Scripts/build-xcframework.sh
Scripts/smoke-test.sh
```

The build fetches only pinned inputs into ignored `.artifacts`, checks the tag,
commit, and archive checksums, and creates:

- `Vendor/LibtorrentNative.xcframework`: iOS arm64, Simulator arm64/x86_64,
  and macOS arm64/x86_64;
- `Vendor/OpenSSL.xcframework`: checksum-verified binary dependency;
- `Vendor/cacert-2026-08-13.pem`: checksum-verified CA bundle.

These generated binaries are intentionally ignored. A fresh checkout must run
the build script before SwiftPM can resolve the local binary targets. Client
apps must copy the CA bundle into their protected application bundle and pass
its file URL to `TorrentSessionConfiguration`.

## SwiftPM integration

During local development, add `/path/to/LibtorrentKit` as a local package and
link the `LibtorrentKit` product. Because the pinned OpenSSL XCFramework is a
dynamic framework, also add `Vendor/OpenSSL.xcframework` to the application
target's **Embed Frameworks** phase with **Embed & Sign**. The harness is the
reference configuration. Normal client builds consume the prebuilt
XCFrameworks and do not compile libtorrent's C++ sources.

```swift
let configuration = TorrentSessionConfiguration(caBundleURL: bundledCAURL)
let session = try TorrentSession(configuration: configuration)
let id = UUID()

try await session.add(.init(
    id: id,
    source: .magnet(magnetURL),
    downloadDirectory: payloadDirectory,
    beginsPaused: false
))

// Magnet metadata can arrive while every file remains at dont_download.
let metadata = try await session.metadata(for: id)
let primary = metadata.files.max(by: { $0.size < $1.size })!
try await session.selectFiles(
    for: id,
    selectedFileIndexes: [primary.index],
    primaryFileIndex: primary.index
)

// Optional fine-grained baseline priorities survive window replacement and
// are serialized by libtorrent in fast-resume data.
try await session.setFilePriority(.high, forFileAt: primary.index, in: id)
try await session.setPiecePriority(.aboveNormal, forPieceAt: primary.firstPieceIndex!, in: id)

let window = try await session.updateStreamingWindow(
    for: id,
    fileIndex: primary.index,
    byteOffset: 0,
    forwardBufferBytes: 8 * 1_048_576,
    prioritizeFirstAndLastPieces: true
)
let pieces = try await session.pieces(for: id)

try await session.pause(id)
let resumeData = try await session.checkpoint(id, flushDiskCache: true)
try await session.remove(id, deleteFiles: false)
```

After a seek, call `updateStreamingWindow` with the new file-relative offset.
The native layer clears old deadlines, reapplies file-priority baselines, raises
the requested first/last pieces, builds a clamped new forward range, and assigns
increasing deadlines. `clearStreamingWindow` removes all deadlines and restores
file-selection priorities.

To restore after relaunch, construct the same request with its original source,
caller-owned UUID, download directory, selection, and the opaque `resumeData`.
Corrupt or incompatible resume data fails recoverably and payload files are not
deleted. libtorrent reconciles files already present in the save directory.

Default completion policy is `.stopWithoutDeletingFiles`. On selected-payload
completion, the bridge emits a completed status, pauses, requests resume data
with a disk-cache flush, removes the torrent without delete flags, then emits
`stoppedAfterCompletion`. Its cached status reports zero upload rate, zero
peers, and no swarm participation. Explicit `.seed` is opt-in.

## iOS backgrounding and sensitive data

When the scene enters the background:

1. Request `checkpoint(id, flushDiskCache: true)` for every caller-owned job
   that must survive.
2. Store each returned blob atomically with `NSFileProtectionComplete` (or a
   protection class deliberately chosen by the app).
3. End any available background task and allow iOS to suspend the process.
4. On relaunch, recreate the session and add each source with its resume blob.

iOS does not permit indefinite peer activity after process suspension. The
guarantee is checkpoint, suspension, relaunch, reconciliation, and continued
transfer while the process runs again—not background downloading forever.

Magnet URLs, `.torrent` bytes, and fast-resume blobs can contain private tracker
paths, passkeys, or other sensitive values. LibtorrentKit never logs them and
does not persist them. Keep them in protected local storage. Events omit tracker
URLs, peers, DHT nodes, external addresses, and libtorrent's broad alert text.

## Updating dependencies and publishing binaries

Change a pin only after reviewing upstream release notes and licenses. Replace
the exact version, URL, full commit, and SHA-256 in
`Scripts/build-xcframework.sh`; rebuild all slices; run verification and tests;
and re-run the signed harness acceptance checks. Never replace the commit with a
branch.

For a remote SwiftPM binary release:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  Vendor/LibtorrentNative.xcframework LibtorrentNative.xcframework.zip
swift package compute-checksum LibtorrentNative.xcframework.zip
```

Attach the immutable zip to a GitHub release, then change the local binary
target to `.binaryTarget(name:url:checksum:)` using that release URL and printed
checksum. Publish OpenSSL as its own pinned binary target or retain the exact
verified upstream artifact. The included workflow performs the archive and
attachment step only when manually dispatched.

## Harness

`Harness/LibtorrentHarness.xcodeproj` is a signed-device diagnostic app with no
playback code. It downloads WebTorrent's freely redistributable Sintel torrent
fixture, selects the largest payload, exposes priorities and deadlines, and has
controls for start, pause, checkpoint, session destruction/restoration, seek
reprioritization, and non-destructive removal. It never displays or logs the
fixture URL. Sintel is Copyright Blender Foundation and available under CC BY
3.0; the harness downloads rather than redistributes the media.
