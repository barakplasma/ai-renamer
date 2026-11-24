#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#ifdef __linux__
#include <fcntl.h>
#endif

int renamer_move_exclusive(int dir, const char *from, const char *to) {
#ifdef __linux__
    if (renameat2(dir, from, dir, to, RENAME_NOREPLACE) == 0)
        return 0;
#elif defined(__APPLE__)
    if (renameatx_np(dir, from, dir, to, RENAME_EXCL) == 0)
        return 0;
#else
    return ENOTSUP;
#endif
    return errno;
}
