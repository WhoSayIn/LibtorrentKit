# ADR 0001: Wrap upstream libtorrent directly

Status: accepted

LibtorrentKit owns a narrow C ABI over an exactly pinned upstream libtorrent
build. Swift calls that ABI from an actor and never imports C++ declarations.

Existing Swift wrappers were not adopted because this package needs control of
the iOS binary inputs, resume-alert correlation, selective priorities,
streaming deadlines, privacy filtering, and the maintained public API. A C ABI
also avoids coupling clients to Swift C++ interoperability rules or libtorrent's
C++ ABI. Opaque session pointers and caller-owned buffers make lifetime and
error boundaries explicit. All C++ exceptions terminate inside the bridge.

The cost is maintaining a small native bridge and reproducible XCFramework
pipeline. That cost is accepted because it keeps upstream protocol behavior in
libtorrent while keeping this repository responsible for its own API.

