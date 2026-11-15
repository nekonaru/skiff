# Changelog

## v0.1.0 - 2026-11-16

Rilis publik pertama. Skiff menyajikan folder mana pun sebagai situs statis lewat HTTP dengan satu binary bebas dependensi di bawah 1 MB.

### Fitur baru

- **Static serving.** Sajikan file dari folder mana pun dengan auto-deteksi `index.html`, di-stream dari disk.
- **MIME table.** 27 type bawaan dengan fallback `application/octet-stream`.
- **Daftar direktori.** Halaman HTML rapi (folder lebih dulu) saat tidak ada `index.html`; sembunyikan dengan `--no-listing`.
- **Range request.** Seek video dan audio langsung jalan (`206`, `416`, suffix range, `If-Range`).
- **Caching.** `ETag` lemah (ukuran + mtime), `If-None-Match` dan `If-Modified-Since` dengan response 304.
- **CLI.** `--port`/`-p`, `--dir`/`-d`, `--host`, `--no-listing`, `--spa`, `--cors`, `--quiet`, `--help`/`-h`, `--version`/`-v`.
- **Aman secara default.** Hanya menyajikan file, bind ke `127.0.0.1`, path hasil persen-decode dengan pengecekan containment dan proteksi symlink.
- **Access log.** Method, path, status, ukuran dan durasi per request, bisa disenyapkan dengan `--quiet`.
- **Mode SPA.** `--spa` fallback ke `index.html` untuk path tidak dikenal.
- **CORS.** `--cors` menambah `Access-Control-Allow-Origin: *` ke setiap response.
- **Keep-alive.** Koneksi persisten HTTP/1.1; pool koneksi terbatas (64) dan idle timeout di Linux dan macOS.

### Peningkatan

- **Ukuran.** Binary ReleaseSmall jauh di bawah 1 MB untuk kelima target.
- **Redirect direktori.** Request ke direktori tanpa trailing slash di-redirect dengan 301.

### Perbaikan bug

- **Path traversal.** Nama device Windows (`CON`, `LPT1`, ...) dan separator ter-encode ditolak; persen-decode dilakukan sebelum pengecekan segmen.
