#include "smoke.h"
#include <stdio.h>
#include <stdlib.h>

unsigned int smoke_add(unsigned int a, unsigned int b) {
  return a + b;
}

DWORD smoke_pid(void) {
  char buf[32];
  /* CRT calls, so the link needs the CRT libraries. */
  snprintf(buf, sizeof buf, "%lu", (unsigned long)GetCurrentProcessId());
  return (DWORD)strtoul(buf, NULL, 10);
}
