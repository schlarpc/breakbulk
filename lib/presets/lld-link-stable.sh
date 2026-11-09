# lld-link wrapper that keeps rustc's random temp dir out of the PDB
# (docs/spikes/msvc.md at the spikes-archive tag, "Determinism"). $LLD_LINK
# is set above this line.
#
# rustc links from a temp dir it creates next to the output,
# <out-dir>/rustcXXXXXX (rustc_codegen_ssa back/link.rs, TempDirBuilder
# prefix "rustc"), and passes files in it (symbols.o, extracted bundled
# libs) to the linker by absolute path. lld-link records every input's path
# in the PDB's module list, and when it writes a PDB the PE's PDB GUID is a
# hash of the PDB (lld COFF Driver.cpp: buildIDHash = PDB; Writer.cpp
# writeBuildId). The random name therefore changes the .exe on every build.
#
# This copies such inputs to $TMPDIR/breakbulk-lld-link/<output name>/ and
# passes the copies instead; the path depends only on the output's name.
# Arguments inside a response file (@file, which rustc uses only when the
# command line is too long) are rewritten the same way.
set -euo pipefail

out=""
for a in "$@"; do
  case "$a" in
  [/-][Oo][Uu][Tt]:*) out=${a#*:} ;;
  esac
done

stable="${TMPDIR:-/tmp}/breakbulk-lld-link/$(basename "${out:-out}")"

rewrite() {
  if [[ $1 =~ ^(.*/)?rustc[A-Za-z0-9]{6}/([^/]+)$ && -f $1 ]]; then
    mkdir -p "$stable"
    cp -f "$1" "$stable/${BASH_REMATCH[2]}"
    printf '%s' "$stable/${BASH_REMATCH[2]}"
  else
    printf '%s' "$1"
  fi
}

args=()
for a in "$@"; do
  if [[ $a == @* && -f ${a#@} ]]; then
    # rustc writes one argument per line, quoted when needed.
    rsp="$stable.rsp"
    mkdir -p "$(dirname "$rsp")"
    : > "$rsp"
    while IFS= read -r line || [[ -n $line ]]; do
      q=""
      if [[ $line == \"*\" ]]; then
        q='"'
        line=${line:1:${#line}-2}
      fi
      printf '%s%s%s\n' "$q" "$(rewrite "$line")" "$q" >> "$rsp"
    done < "${a#@}"
    args+=("@$rsp")
  else
    args+=("$(rewrite "$a")")
  fi
done

exec "$LLD_LINK" "${args[@]}"
