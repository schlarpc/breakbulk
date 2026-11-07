#include <stdio.h>
#include <string.h>

/* Uses libc (snprintf, strlen), so a static link must pull in libc.a. */
int mix(int a, int b) {
    char buf[32];
    snprintf(buf, sizeof buf, "%d-%d", a, b);
    return (int)strlen(buf) + a * b;
}
