#include <stdint.h>
#include <string.h>

/* Pure libc calls only: nothing here may become a WASI import. */
uint32_t c_checksum(const char *s) {
  char buf[64];
  size_t n = strlen(s);
  if (n >= sizeof buf) n = sizeof buf - 1;
  memcpy(buf, s, n);
  buf[n] = 0;
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) {
    h = (h ^ (uint8_t)buf[i]) * 16777619u;
  }
  return h;
}
