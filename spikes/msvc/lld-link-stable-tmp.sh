#!/usr/bin/env bash
# lld-link wrapper that keeps rustc's random temp dir out of the PDB.
#
# rustc links from a temp dir it creates next to the output,
# <out-dir>/rustcXXXXXX (rustc_codegen_ssa back/link.rs, TempDirBuilder
# prefix "rustc"), and passes files in it (symbols.o, extracted bundled
# libs) to the linker by absolute path. lld-link records every input's path
# in the PDB's module list, and when it writes a PDB the PE's PDB GUID is a
# hash of the PDB (lld COFF Driver.cpp: buildIDHash = PDB; Writer.cpp
# writeBuildId). The random name therefore changes the .exe on every build.
#
# This copies such inputs to <output>.rustc-tmp/ (a name derived from /OUT:,
# so concurrent links in one deps/ directory do not collide) and passes the
# copies instead. Spike quality: arguments inside a response file (@file,
# which rustc uses only when the command line is too long) are not
# rewritten.
set -euo pipefail

args=("$@")

out=""
for a in "${args[@]}"; do
  case "$a" in
  [/-][Oo][Uu][Tt]:*) out=${a#*:} ;;
  esac
done

if [[ -n $out ]]; then
  stable="$out.rustc-tmp"
  for i in "${!args[@]}"; do
    a=${args[$i]}
    if [[ $a =~ ^(.*/)?rustc[A-Za-z0-9]{6}/([^/]+)$ && -f $a ]]; then
      mkdir -p "$stable"
      cp -f "$a" "$stable/${BASH_REMATCH[2]}"
      args[$i]="$stable/${BASH_REMATCH[2]}"
    fi
  done
fi

exec "${LLD_LINK:-lld-link}" "${args[@]}"
