#include <gnu/libc-version.h>
#include <stdio.h>
#include <string.h>

/* The glibc headers zig ships for the requested version. */
int bb_header_glibc_minor(void) {
    return __GLIBC_MINOR__;
}

/* The glibc the program runs on. */
int bb_runtime_glibc(char *buf, size_t n) {
    return snprintf(buf, n, "%s", gnu_get_libc_version());
}
