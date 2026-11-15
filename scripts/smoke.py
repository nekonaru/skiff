#!/usr/bin/env python3
"""Smoke test for Skiff. Starts the server on a free port, probes it, exits 0 on success.

Usage: python3 scripts/smoke.py [path-to-skiff-binary]
"""
import http.client
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

BINARY = sys.argv[1] if len(sys.argv) > 1 else None
IS_WINDOWS = os.name == "nt"

if BINARY is None:
    BINARY = os.path.join("zig-out", "bin", "skiff.exe" if IS_WINDOWS else "skiff")

if not os.path.exists(BINARY):
    print(f"FAIL: binary not found at {BINARY}")
    sys.exit(1)

fixture = tempfile.mkdtemp(prefix="skiff-smoke-")
with open(os.path.join(fixture, "index.html"), "w") as f:
    f.write("<h1>home</h1>")
with open(os.path.join(fixture, "big.bin"), "wb") as f:
    f.write(bytes(range(256)) * 4)

# Pick a free port.
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()

proc = subprocess.Popen(
    [BINARY, "-p", str(port), "-d", fixture, "--quiet"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)


def req(method, path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    out = (r.status, dict(r.getheaders()), data)
    c.close()
    return out


failures = 0

def check(name, cond, detail=""):
    global failures
    if cond:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name}: {detail}")


try:
    deadline = time.time() + 10
    started = False
    while time.time() < deadline:
        try:
            req("GET", "/")
            started = True
            break
        except OSError:
            time.sleep(0.1)
    if not started:
        print("FAIL: server did not start")
        sys.exit(1)

    s, h, b = req("GET", "/")
    check("GET / serves index.html", s == 200 and b == b"<h1>home</h1>", f"{s}")

    s, h, b = req("HEAD", "/index.html")
    check("HEAD has no body", s == 200 and len(b) == 0 and h.get("content-length") == "13", f"{s}")

    s, h, _ = req("GET", "/definitely-missing.txt")
    check("404 for missing", s == 404, s)

    s, h, b = req("GET", "/big.bin", {"Range": "bytes=0-99"})
    check("206 range", s == 206 and len(b) == 100 and h.get("content-range") == "bytes 0-99/1024", f"{s} {h.get('content-range')}")

    s, h, _ = req("GET", "/index.html")
    etag = h.get("etag")
    s, h, _ = req("GET", "/index.html", {"If-None-Match": etag})
    check("304 on If-None-Match", s == 304, s)

    # Traversal must never escape the fixture.
    for path in ["/../index.html", "/%2e%2e/index.html", "/%2E%2E%2Findex.html"]:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", path)
        try:
            r = c.getresponse()
            r.read()
            status = r.status
        except http.client.RemoteDisconnected:
            status = "connection closed"
        c.close()
        check(f"traversal {path} rejected", status in (400, 403, 404), status)

    print(f"--- failures: {failures}")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    shutil.rmtree(fixture, ignore_errors=True)

sys.exit(1 if failures else 0)
