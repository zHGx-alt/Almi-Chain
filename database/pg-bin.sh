# shellcheck shell=bash
# Sourced by the test scripts: puts PostgreSQL's server binaries (initdb, pg_ctl) on PATH.
# Looks on PATH first, then in the usual Debian/Ubuntu and Windows install folders,
# and uses the newest version found.
_pg_initdb=$(command -v initdb 2>/dev/null || true)
if [[ -z $_pg_initdb ]]; then
  for _c in /usr/lib/postgresql/*/bin/initdb /c/Program\ Files/PostgreSQL/*/bin/initdb.exe; do
    [[ -x $_c ]] && _pg_initdb=$_c   # globs expand in version order: the last one wins
  done
fi
[[ -n $_pg_initdb ]] || { echo "PostgreSQL (initdb) not found" >&2; exit 1; }
PATH="$(dirname "$_pg_initdb"):$PATH"
export PATH
unset _pg_initdb _c

# Server options for a throwaway cluster: pg_start_opts <port> <temp dir>.
# On Linux the Unix socket goes to the temp dir (the default /var/run/postgresql is not
# writable by a normal user, e.g. on a CI runner); on Windows the default is fine.
pg_start_opts() {
  case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) echo "-p $1" ;;
    *) echo "-p $1 -k $2" ;;
  esac
}
