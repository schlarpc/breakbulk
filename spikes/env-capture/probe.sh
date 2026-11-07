# Wrapper probe. Runs as a child process (bash probe.sh), exactly like a
# build script started by cargo: it sees only the exported environment.
#
# Prints what nixpkgs' cc-wrapper, bintools-wrapper and pkg-config wrapper
# actually do with the environment, so a live stdenv and a replayed capture
# can be diffed.
#
#   probePkg   pkg-config module to query (optional)
#   probeLib   -l flag to link (optional)
set -eu
cd "$NIX_BUILD_TOP"
mkdir -p probe && cd probe

section() { echo; echo "### $*"; }
# Normalise per-derivation values: the random seed comes from each
# derivation's own $out.
norm() { sed -E 's/-frandom-seed=[a-z0-9]{10}/-frandom-seed=SEED/g'; }

section "tools"
for v in CC CXX AR LD PKG_CONFIG CC_FOR_BUILD CXX_FOR_BUILD PKG_CONFIG_FOR_BUILD; do
  if [ -n "${!v:-}" ]; then echo "$v=${!v} -> $(command -v "${!v}" || echo MISSING)"; fi
done
echo "cc on PATH: $(command -v cc || echo none)"

section "wrapper role variables (exported)"
env | grep -E '^NIX_(CC|BINTOOLS|PKG_CONFIG)_WRAPPER_TARGET_|^NIX_(CFLAGS|LDFLAGS|HARDENING|ENFORCE)|^PKG_CONFIG_PATH' | sort | norm

if [ -n "${probePkg:-}" ]; then
  section "pkg-config $probePkg"
  $PKG_CONFIG --cflags --libs "$probePkg"
fi

cat > t.c <<'EOF'
#include <stdio.h>
#ifdef PROBE_OPENSSL
#include <openssl/opensslv.h>
#endif
#ifdef PROBE_ZSTD
#include <zstd.h>
#endif
int main(void) {
#ifdef PROBE_OPENSSL
  printf("%s\n", OPENSSL_VERSION_TEXT);
#endif
#ifdef PROBE_ZSTD
  printf("zstd %s\n", ZSTD_versionString());
#endif
  printf("hello\n");
  return 0;
}
EOF

defs=""
[ "${probePkg:-}" = openssl ] && defs="-DPROBE_OPENSSL"
[ "${probePkg:-}" = libzstd ] && defs="-DPROBE_ZSTD"

section "cc compile (NIX_DEBUG=1)"
NIX_DEBUG=1 $CC -O2 $defs -c t.c -o t.o 2>&1 | norm

section "cc link (NIX_DEBUG=1)"
NIX_DEBUG=1 $CC t.o -o t ${probeLib:-} 2>&1 | norm

section "binary"
"$readelf" -d t | grep -E 'NEEDED|RPATH|RUNPATH' | sed -E 's/^ *0x[0-9a-f]+ //'
"$readelf" -lW t | grep -E 'GNU_RELRO|INTERP' | awk '{print $1}'
"$readelf" -lW t | grep -o 'interpreter: [^]]*'
"$readelf" -hW t | grep -E 'Machine|Type'
"$readelf" -dW t | grep -E 'FLAGS' | sed -E 's/^ *0x[0-9a-f]+ //'
if [ -z "${probeNoRun:-}" ]; then ./t; fi
