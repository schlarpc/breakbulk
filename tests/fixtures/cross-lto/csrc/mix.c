#include <stdint.h>

/* Small enough that LTO inlines it into its Rust caller. */
uint32_t cross_lto_mix(uint32_t x) {
  return (x * 2654435761u) ^ 0x5bd1e995u;
}
