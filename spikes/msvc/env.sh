# Cross env for *-pc-windows-msvc, as the msvc preset would set it for
# target units. Source with:
#   SDK=<xwinSdk out> LLVM=<llvm> CLANG=<clang-unwrapped> LLD=<lld> \
#   LIBCLANG=<libclang lib output> ARCH=x86_64|aarch64 . env.sh
# Used by default.nix inside the sandbox, and by hand for iteration.

triple="${ARCH}-pc-windows-msvc"
T="$(echo "$triple" | tr 'a-z-' 'A-Z_')"   # CARGO_TARGET_<T>_*
t="$(echo "$triple" | tr '-' '_')"         # CC_<t>, CFLAGS_<t>, ...

export PATH="$CLANG/bin:$LLVM/bin:$LLD/bin:$PATH"

# Search paths for the link: CRT, then SDK um and ucrt.
libdirs="$SDK/crt/lib/$ARCH $SDK/sdk/lib/um/$ARCH $SDK/sdk/lib/ucrt/$ARCH"
# Headers: CRT, then the SDK's ucrt, um, shared, winrt, cppwinrt.
incdirs="$SDK/crt/include $SDK/sdk/include/ucrt $SDK/sdk/include/um $SDK/sdk/include/shared $SDK/sdk/include/winrt $SDK/sdk/include/cppwinrt"

# Linker: lld-link, with the library dirs as -Lnative (rustc passes them as
# /LIBPATH:).
export "CARGO_TARGET_${T}_LINKER=lld-link"
rf=""
for d in $libdirs; do rf="$rf -Lnative=$d"; done
export "CARGO_TARGET_${T}_RUSTFLAGS=${rf# }${EXTRA_RUSTFLAGS:+ $EXTRA_RUSTFLAGS}"

# C: clang-cl and llvm-lib; include dirs as -imsvc (system dirs for
# clang-cl, so warnings in SDK headers are silenced). cc adds --target.
export "CC_${t}=clang-cl"
export "CXX_${t}=clang-cl"
export "AR_${t}=llvm-lib"
cf="--target=$triple"
for d in $incdirs; do cf="$cf -imsvc $d"; done
export "CFLAGS_${t}=$cf"
export "CXXFLAGS_${t}=$cf"

# bindgen: libclang in GNU-driver syntax, so -isystem.
bf="--target=$triple"
for d in $incdirs; do bf="$bf -isystem $d"; done
export "BINDGEN_EXTRA_CLANG_ARGS_${t}=$bf"
export LIBCLANG_PATH="$LIBCLANG/lib"

# Resource compiler and anything that reads MSVC's LIB/INCLUDE (lld-link
# itself, clang-cl run by hand, cmake's MSVC mode). Note RC/RCFLAGS/LIB are
# not target-suffixed: they are scoped by setting them on target units only.
export RC=llvm-rc
rcf=""
for d in $incdirs; do rcf="$rcf /I $d"; done
export RCFLAGS="${rcf# }"
LIB=""
for d in $libdirs; do LIB="${LIB:+$LIB;}$d"; done
export LIB
INCLUDE=""
for d in $incdirs; do INCLUDE="${INCLUDE:+$INCLUDE;}$d"; done
export INCLUDE
