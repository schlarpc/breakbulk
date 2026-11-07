/* Compiled by build.rs the way cc-rs does: an absolute source path, debug
   info with macros (-g3, as ring does). Both the debug info and __FILE__
   would embed the source's store path without -ffile-prefix-map. */
const char *smoke_c_file(void) { return __FILE__; }

int smoke_c_answer(void) { return 6; }
