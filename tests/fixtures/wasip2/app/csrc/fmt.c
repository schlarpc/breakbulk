#include <stdio.h>
#include <string.h>

int bb_fmt(char *buf, size_t n, int v, const char *who) {
    return snprintf(buf, n, "c says %d to %s (%zu)", v, who, strlen(who));
}
