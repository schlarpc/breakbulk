#include <stdio.h>
#include <TargetConditionals.h>

#if !TARGET_OS_OSX
#error "not compiled for macOS"
#endif

/* The SDK's headers: snprintf from stdio.h. */
int greet(char *buf, unsigned long len, int n) {
    return snprintf(buf, len, "c says %d", n * 2);
}
