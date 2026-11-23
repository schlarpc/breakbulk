#include <stdio.h>

#ifndef __ANDROID__
#error "not compiled for Android"
#endif

int scale(int x) { return x * 3; }

/* The API level the NDK's clang compiled for (presets.android's apiLevel). */
int api_level(void) { return __ANDROID_API__; }

/* __FILE__ through the unit's -ffile-prefix-map: no store path. */
const char *source_file(void) { return __FILE__; }

/* snprintf from the NDK sysroot's bionic headers. */
int describe(char *buf, unsigned long len, int x) {
    return snprintf(buf, len, "c scales %d to %d", x, scale(x));
}
