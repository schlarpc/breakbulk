/* The C shared library foo-sys links (tests/native-link). */
#ifndef ANSWER
#define ANSWER 42
#endif

int foo_answer(void) { return ANSWER; }
