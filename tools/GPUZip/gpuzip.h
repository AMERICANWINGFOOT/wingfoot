/* gpuzip.h - C interface for libgpuzip.so (QB64-PE Declare Library "gpuzip")
 *
 * Chunked LZ compressor. Each chunk (max 64 KB) is compressed on its own into a
 * standard LZ4 *block*, so chunks can be spread across any number of GPUs and
 * CPU threads. Decompression runs on the CPU (multithreaded).
 *
 * Compress modes:
 *   -2 = hybrid: all GPUs + CPU threads pull from the same work queue
 *   -1 = CPU threads only
 *    0 = all GPUs (falls back to CPU if no GPU found)
 *    k = GPU number k only (1-based)
 */
#ifndef GPUZIP_H
#define GPUZIP_H
#include <stdint.h>

/* Pointer arguments are intptr_t because QB64 passes _Offset values that way.
 * sizes points to int32_t[], src/dst/p to raw bytes. */

#ifdef __cplusplus
extern "C" {
#endif

/* setup / info */
int      gz_Init(void);                               /* returns GPU count (0 = CPU only) */
void     gz_Shutdown(void);
int      gz_DeviceCount(void);
int      gz_DeviceName(int idx, char *buf, int cap);  /* idx 0-based, returns length */
int      gz_CpuThreads(void);
int      gz_LastError(char *buf, int cap);            /* returns length, 0 = no error */

/* compression: src -> packed dst (chunks back to back), sizes[] per chunk.
 * sizes[i] > 0 : LZ4 block of that many bytes
 * sizes[i] < 0 : stored raw, -sizes[i] bytes
 * dst must hold at least srcLen bytes. Returns packed byte count, or -1 on error. */
int64_t  gz_CompressBatch(intptr_t src, int64_t srcLen, int chunkSize,
                          intptr_t dst, intptr_t sizes, int mode);
int64_t  gz_WorkerChunks(int idx);  /* chunks done in last batch: 0..n-1 = GPUs, n = CPU */
int64_t  gz_ChunkCount(int64_t len, int chunkSize);

/* decompression (CPU, multithreaded). Returns 0 ok, -(chunk+1) on a bad chunk. */
int      gz_DecompressBatch(intptr_t src, int64_t srcLen, intptr_t sizes,
                            int nChunks, int chunkSize, int64_t rawLen, intptr_t dst);

/* helpers for the QB64 side */
uint32_t gz_Crc32(intptr_t p, int64_t len, uint32_t crc);  /* start with crc = 0 */
int      gz_ScanFolder(const char *root);          /* recursive walk, returns entry count or -1 */
int      gz_ScanPath(int idx, char *buf, int cap); /* relative path, returns length */
int64_t  gz_ScanSize(int idx);
int      gz_ScanType(int idx);                     /* 0 = file, 1 = directory */
int      gz_MkdirP(const char *path);              /* mkdir -p, 0 = ok */

/* file I/O: handles are POSIX fds. Error codes are errno values (0 = ok);
 * gz_ErrText turns one into text such as "No space left on device". */
int      gz_FCreate(const char *path);             /* fd, or -errno */
int      gz_FOpenR(const char *path);              /* fd, or -errno */
int      gz_FWrite(int fd, intptr_t p, int64_t len);
int      gz_FWriteAt(int fd, intptr_t p, int64_t len, int64_t offset);
int64_t  gz_FRead(int fd, intptr_t p, int64_t len); /* bytes, 0 = EOF, or -errno */
int      gz_FClose(int fd);
int      gz_FSync(int fd);                         /* flush to drive, reports late write errors */
int      gz_FDelete(const char *path);
int      gz_ErrText(int code, char *buf, int cap);
int64_t  gz_FreeSpace(const char *path);           /* bytes free on that drive, -1 = error */

#ifdef __cplusplus
}
#endif
#endif
