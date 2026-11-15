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
an idle read times out after 30 seconds so a silent client cannot hold a slot
forever.

- Linux: `SO_RCVTIMEO`/`SO_SNDTIMEO` via `std.os.linux.SO` constants (the
  correct per-architecture values, not the MIPS 0x1006).
- macOS: `setsockopt` via libSystem (always linked on Darwin).
- Windows: not available. Zig's sockets are AFD file handles, and the AFD
  driver rejects `SO_RCVTIMEO`/`SO_SNDTIMEO` with `STATUS_NOT_SUPPORTED`
  (confirmed by running it). The timeout lives in ws2_32.dll, which does not
  apply to AFD handles. No stdlib path exists for an idle read timeout on
  Windows without undocumented ioctls. Accepted residual: idle connections
  hold one of 64 slots, same as before, bounded in total.

## fnmatch-ish case sensitivity (2026-11-16)

Containment compares paths byte-wise, ASCII case-insensitive on Windows and
case-sensitive elsewhere. Non-ASCII root names with unusual case folding fail
toward 403, which is the safe direction.

## Alternate Data Streams (2026-11-16)

Colons in path segments are rejected on Windows because they are ADS
syntax (`file.txt:Zone.Identifier`). On Linux and macOS, ':' is allowed in
file names and requests for such files work normally.

## fd-verified containment (2026-11-16)

The check that a served file stays under the root realpath is enforced on the
open file handle itself, not on a re-resolved path. On Linux the check uses
`/proc/self/fd/N`; on Windows it uses `GetFinalPathNameByHandle` (via
`std.Io.Threaded`). There is no check-then-open window on either platform.
macOS falls back to realpath-then-open (documented residual).

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
