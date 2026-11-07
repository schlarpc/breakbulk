#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

unsigned int smoke_add(unsigned int a, unsigned int b) {
  return a + b;
}

/* kernel32 and CRT calls, so the link needs mingw's import libraries. */
unsigned long smoke_pid(void) {
  char buf[32];
  snprintf(buf, sizeof buf, "%lu", (unsigned long)GetCurrentProcessId());
  return strtoul(buf, NULL, 10);
}
