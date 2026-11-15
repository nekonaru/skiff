# Changelog

## v0.1.0 - 2026-11-16

First public release. Skiff serves any folder as a static website over HTTP with a single, dependency-free binary under 1 MB.

### New features

- **Static serving.** Serve files from any folder with `index.html` auto-detection, streamed from disk.
- **MIME table.** 27 built-in types with `application/octet-stream` fallback.
- **Directory listing.** Clean HTML listing (folders first) when no `index.html` exists; hide it with `--no-listing`.
- **Range requests.** Video and audio seeking works out of the box (`206`, `416`, suffix ranges, `If-Range`).
- **Caching.** Weak `ETag` (size + mtime), `If-None-Match` and `If-Modified-Since` with 304 responses.
- **CLI.** `--port`/`-p`, `--dir`/`-d`, `--host`, `--no-listing`, `--spa`, `--cors`, `--quiet`, `--help`/`-h`, `--version`/`-v`.
- **Safe by default.** Serves files only, binds to `127.0.0.1`, percent-decoded and containment-checked paths with symlink protection.
- **Access log.** Method, path, status, size and duration per request, suppressible with `--quiet`.
- **SPA mode.** `--spa` falls back to `index.html` for unknown paths.
- **CORS.** `--cors` adds `Access-Control-Allow-Origin: *` to every response.
- **Keep-alive.** HTTP/1.1 persistent connections; scoped connection pool (64 max) and idle timeout on Linux and macOS.

### Improvements

- **Size.** ReleaseSmall binaries stay well under 1 MB for all five targets.
- **Directory redirects.** Requests to directories without a trailing slash redirect with 301.

### Bug fixes

- **Path traversal.** Windows device names (`CON`, `LPT1`, ...) and encoded separators are rejected; percent-decoding happens before segment checks.
