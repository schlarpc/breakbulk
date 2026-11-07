#pragma once
#include <windows.h>

/* Implemented in smoke.c, compiled by clang-cl. */
unsigned int smoke_add(unsigned int a, unsigned int b);
/* Calls into kernel32 and the CRT from C, so the C side needs the SDK too. */
DWORD smoke_pid(void);
