# Design decisions

Running log of decisions that were not obvious from the PRD. Newest last.

## Zig version is pinned to 0.17.1 (2026-11-16)

`build.zig.zon` sets `minimum_zig_version = "0.17.1"`. The `std.Io` network API
(`std.Io.net`, `Io.Threaded`) was reworked between 0.14 and 0.17, and the PRD
requires locking one version instead of guessing the API. README and CI pin
the same version.

## HTTP layer: `std.http.Server` (2026-11-16, supersedes the raw-socket plan)

The server speaks HTTP/1.1 through `std.http.Server` (receiveHead +
respond/respondStreaming) instead of a hand-written parser. The PRD asks for
it implicitly (keep-alive, Range, 304) and it is the better bet on a
fast-moving std API: correctness over a few KB of binary. File responses use
`respondStreaming` with `content_length`; HEAD is handled by the eliding
writer transparently. Directory and file paths are canonicalized with
`realPathFile` and checked to stay under the root realpath, which is what
closes symlink escapes (verified with a junction to `C:\Windows`).

## One thread per connection, bounded (2026-11-16)

A semaphore caps concurrent connections at 64. Extra connections wait in the
listen backlog instead of spawning unbounded threads. This is simpler than a
thread pool and matches the "thread per connection with a maximum" option in
the PRD.

## Keep-alive with idle timeout (2026-11-16)

HTTP/1.1 connections stay open by default, `Connection: close` is honored, and
an idle read times out after 30 seconds (via `SO_RCVTIMEO`) so a silent client
cannot hold a slot forever. Headers are capped at 16 KB.

## Weak ETag from size and mtime (2026-11-16)

`ETag: W/"<size>-<mtime_ns>"`. Content hashing per request would punish large
files on a static server, and inode is not portable. Weak comparison
(`If-None-Match`) is used for the 304 path. `If-Modified-Since` is honored
too, with second granularity per HTTP convention.

## Single-range `Range` only (2026-11-16)

`bytes=start-end`, `bytes=start-` and `bytes=-suffix` are supported. A
comma-separated list of ranges is answered with the full body (200) instead
of `multipart/byteranges`; RFC 7233 explicitly allows ignoring the header.
Unsatisfiable ranges get 416. Invalid syntax gets 200, not 400.

## Path traversal defense in layers (2026-11-16)

1. Percent-decode and reject invalid sequences and NUL.
2. Reject backslashes and drive-letter/UNC prefixes everywhere.
3. Reject Windows device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9).
4. Collapse and reject `.` and `..` segments before touching the filesystem.
5. Resolve the target with `realPathFile` and require it to stay under the
   realpath of the root directory, which also closes symlink escapes.

## No LAN IP auto-detection (2026-11-16)

FR-9 is a "Should". `std.Io.net` exposes no `getsockname` and interface
enumeration is not portable in this Zig version. When `--host 0.0.0.0` is
used, Skiff prints `0.0.0.0:<port>` and the docs tell the user to open
`http://<lan-ip>:<port>` from another device. The PRD allows this fallback.

## Release binaries on GitHub Releases (2026-11-16)

Skiff is distributed as prebuilt binaries on the GitHub Release (the flash
drive use case). There is no package registry publication for v1. Release
notes for general projects use New features / Improvements / Bug fixes /
Usage instead of Install / Update.
