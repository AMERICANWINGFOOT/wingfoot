/*
 * z64io.c -- streaming file I/O helpers for the Z64Pack QB64-PE toolchain.
 *
 * This DLL provides byte-pump primitives that operate on files by name
 * with fixed 1 MB internal buffering.  Peak memory is flat regardless of
 * file size or requested range, so it scales to arbitrary source sizes
 * without the whole-file-in-RAM problem that killed PNG-container mode.
 *
 * Build (from QB64-PE's internal\c\c_compiler\bin on PATH):
 *   gcc -O2 -shared z64io.c -o z64io.dll -static-libgcc
 *
 * Place z64io.dll in the same folder as the .exe that DECLAREs it, or
 * in a folder on the Windows PATH.
 *
 * Exported functions
 * ------------------
 *   int64_t z64_copy_range(const char *src, int64_t offset,
 *                          int64_t length, const char *dst, int append)
 *
 *     Copy `length` bytes from `src` starting at byte `offset` into `dst`.
 *     If `append` is non-zero, `dst` is opened for append (writes go to
 *     the end, existing content preserved).  Otherwise `dst` is truncated
 *     on open.  Returns bytes written on success, -1 on error.
 *
 *   int64_t z64_file_size(const char *path)
 *
 *     Return the size of `path` in bytes, or -1 on error.
 *
 * All string arguments must be null-terminated -- QB64-PE strings are
 * pointer+length internally, so the caller must append Chr$(0) to any
 * path passed in.
 */

#include <stdio.h>
#include <stdint.h>

#ifdef _WIN32
    #include <windows.h>
    #define Z64_EXPORT __declspec(dllexport)
#else
    #define Z64_EXPORT
    #define _fseeki64 fseeko
    #define _ftelli64 ftello
#endif

#define Z64_BUFSIZE (1 << 20)          /* 1 MB internal block buffer */

/* BSS-resident buffer -- allocated once at load time, reused across calls. */
static char g_buf[Z64_BUFSIZE];


Z64_EXPORT
int64_t z64_copy_range(const char *src, int64_t offset, int64_t length,
                       const char *dst, int append)
{
    FILE *fsrc = NULL;
    FILE *fdst = NULL;
    int64_t remaining = length;
    int64_t written = 0;

    if (src == NULL || dst == NULL || length < 0 || offset < 0)
        return -1;

    fsrc = fopen(src, "rb");
    if (fsrc == NULL) return -1;

    fdst = fopen(dst, append ? "ab" : "wb");
    if (fdst == NULL) {
        fclose(fsrc);
        return -1;
    }

    if (_fseeki64(fsrc, offset, SEEK_SET) != 0) {
        fclose(fsrc);
        fclose(fdst);
        return -1;
    }

    while (remaining > 0) {
        size_t want = (remaining > Z64_BUFSIZE) ? Z64_BUFSIZE : (size_t)remaining;
        size_t got  = fread(g_buf, 1, want, fsrc);

        if (got == 0) break;           /* EOF or read error -- return partial */

        if (fwrite(g_buf, 1, got, fdst) != got) {
            fclose(fsrc);
            fclose(fdst);
            return -1;                 /* write failed (disk full, etc.) */
        }

        remaining -= (int64_t)got;
        written   += (int64_t)got;
    }

    fclose(fsrc);
    fclose(fdst);
    return written;
}


Z64_EXPORT
int64_t z64_file_size(const char *path)
{
    FILE *fp = NULL;
    int64_t sz;

    if (path == NULL) return -1;

    fp = fopen(path, "rb");
    if (fp == NULL) return -1;

    if (_fseeki64(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }

    sz = _ftelli64(fp);
    fclose(fp);
    return sz;
}
