/* z64fs.c -- directory enumeration DLL for QB64-PE
 *
 * Solves the "QB64-PE can only test if a directory exists, it can't
 * find them" gap. Wraps FindFirstFileA / FindNextFileA / FindClose
 * and exposes a small C ABI that BASIC can call through
 * DECLARE DYNAMIC LIBRARY "z64fs".
 *
 * Build (MinGW, standalone gcc, or QB64-PE's bundled compiler):
 *   gcc -shared -o z64fs.dll z64fs.c -lkernel32
 *
 * Place z64fs.dll next to the compiled QB64-PE .exe at runtime.
 *
 * API (see z64fs.bi for the BASIC binding):
 *
 *   int z64fs_open(const char *path, int flags)
 *       Start enumerating path.  path may be a directory (e.g.
 *       "C:\\Users\\") -- we append "\\*" ourselves if needed --
 *       or an explicit wildcard.  flags is reserved for future
 *       use; pass 0.  Returns a handle >= 0 on success,
 *       -1 on error.
 *
 *   int z64fs_next(int handle, char *name_out, int name_max, int *attrs_out)
 *       Fetch next entry.  Skips "." and ".." internally.
 *       Writes entry name into name_out (null-terminated, truncated
 *       to name_max-1 chars if needed).  Writes attribute bitmask
 *       to *attrs_out:
 *           bit 0 = is directory
 *           bit 1 = is hidden
 *           bit 2 = is system
 *           bit 3 = is reparse point (junction / symlink)
 *       Returns 1 if an entry was returned, 0 if enumeration
 *       ended, -1 on error.
 *
 *   void z64fs_close(int handle)
 *       Release the handle.  Safe on -1 (no-op).
 *
 *   int z64fs_stat(const char *path, int *attrs_out)
 *       Fill *attrs_out with the attribute bits (same layout as
 *       z64fs_next) for path.  Returns 1 on success, 0 if path
 *       doesn't exist.
 *
 * Handle slot table: fixed at 32 concurrent enumerations, which is
 * absurdly generous for a picker.  If we ever want more we can grow.
 */

#include <windows.h>
#include <string.h>

#define Z64FS_MAX_HANDLES 32

#define Z64FS_ATTR_DIR      (1 << 0)
#define Z64FS_ATTR_HIDDEN   (1 << 1)
#define Z64FS_ATTR_SYSTEM   (1 << 2)
#define Z64FS_ATTR_REPARSE  (1 << 3)

typedef struct {
    HANDLE hFind;              /* INVALID_HANDLE_VALUE when slot is free */
    WIN32_FIND_DATAA nextData; /* pre-fetched entry, valid when hasNext is set */
    int hasNext;               /* 1 if nextData holds an unconsumed entry */
} Z64FS_Slot;

static Z64FS_Slot g_slots[Z64FS_MAX_HANDLES];
static int g_slotsInit = 0;

static void z64fs_init_slots(void)
{
    int i;
    if (g_slotsInit) return;
    for (i = 0; i < Z64FS_MAX_HANDLES; ++i) {
        g_slots[i].hFind = INVALID_HANDLE_VALUE;
        g_slots[i].hasNext = 0;
    }
    g_slotsInit = 1;
}

static int z64fs_alloc_slot(void)
{
    int i;
    for (i = 0; i < Z64FS_MAX_HANDLES; ++i) {
        if (g_slots[i].hFind == INVALID_HANDLE_VALUE) {
            return i;
        }
    }
    return -1;
}

static int z64fs_pack_attrs(DWORD winAttrs)
{
    int attrs = 0;
    if (winAttrs & FILE_ATTRIBUTE_DIRECTORY)     attrs |= Z64FS_ATTR_DIR;
    if (winAttrs & FILE_ATTRIBUTE_HIDDEN)        attrs |= Z64FS_ATTR_HIDDEN;
    if (winAttrs & FILE_ATTRIBUTE_SYSTEM)        attrs |= Z64FS_ATTR_SYSTEM;
    if (winAttrs & FILE_ATTRIBUTE_REPARSE_POINT) attrs |= Z64FS_ATTR_REPARSE;
    return attrs;
}

static int z64fs_is_dot_entry(const char *name)
{
    if (name[0] == '.' && name[1] == '\0') return 1;
    if (name[0] == '.' && name[1] == '.' && name[2] == '\0') return 1;
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Public API                                                        */
/* ------------------------------------------------------------------ */

__declspec(dllexport) int z64fs_open(const char *path, int flags)
{
    char pattern[MAX_PATH];
    int len;
    int slot;
    HANDLE h;
    WIN32_FIND_DATAA fd;

    (void)flags; /* reserved */

    z64fs_init_slots();

    if (!path) return -1;

    /* If path ends with a slash, append "*"; otherwise, if it doesn't
     * already contain a wildcard, treat it as a directory and append
     * "\\*".  If it does contain a wildcard, use as-is. */
    len = (int)strlen(path);
    if (len == 0 || len >= MAX_PATH - 3) return -1;

    if (strchr(path, '*') || strchr(path, '?')) {
        strcpy(pattern, path);
    } else if (path[len - 1] == '\\' || path[len - 1] == '/') {
        strcpy(pattern, path);
        strcat(pattern, "*");
    } else {
        strcpy(pattern, path);
        strcat(pattern, "\\*");
    }

    h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return -1;

    slot = z64fs_alloc_slot();
    if (slot < 0) {
        FindClose(h);
        return -1;
    }

    g_slots[slot].hFind = h;
    g_slots[slot].nextData = fd;
    g_slots[slot].hasNext = 1;
    return slot;
}


__declspec(dllexport) int z64fs_next(int handle, char *name_out,
                                     int name_max, int *attrs_out)
{
    Z64FS_Slot *s;
    WIN32_FIND_DATAA fd;
    int nameLen;

    if (handle < 0 || handle >= Z64FS_MAX_HANDLES) return -1;
    s = &g_slots[handle];
    if (s->hFind == INVALID_HANDLE_VALUE) return -1;
    if (!name_out || name_max <= 0 || !attrs_out) return -1;

    for (;;) {
        if (s->hasNext) {
            fd = s->nextData;
            s->hasNext = 0;
        } else {
            if (!FindNextFileA(s->hFind, &fd)) {
                return 0; /* end of enumeration */
            }
        }

        if (z64fs_is_dot_entry(fd.cFileName)) {
            continue; /* skip . and .. transparently */
        }

        nameLen = (int)strlen(fd.cFileName);
        if (nameLen >= name_max) nameLen = name_max - 1;
        memcpy(name_out, fd.cFileName, nameLen);
        name_out[nameLen] = '\0';

        *attrs_out = z64fs_pack_attrs(fd.dwFileAttributes);
        return 1;
    }
}


__declspec(dllexport) void z64fs_close(int handle)
{
    if (handle < 0 || handle >= Z64FS_MAX_HANDLES) return;
    if (g_slots[handle].hFind != INVALID_HANDLE_VALUE) {
        FindClose(g_slots[handle].hFind);
        g_slots[handle].hFind = INVALID_HANDLE_VALUE;
        g_slots[handle].hasNext = 0;
    }
}


__declspec(dllexport) int z64fs_stat(const char *path, int *attrs_out)
{
    DWORD winAttrs;

    if (!path || !attrs_out) return 0;

    winAttrs = GetFileAttributesA(path);
    if (winAttrs == INVALID_FILE_ATTRIBUTES) return 0;

    *attrs_out = z64fs_pack_attrs(winAttrs);
    return 1;
}
