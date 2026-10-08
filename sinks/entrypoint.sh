#!/bin/sh
# Container entrypoint: starts sinks/supervisor.sh with only the variables of its env contract.
#
# bash acts on some variables before a script's first line runs: SHELLOPTS and PS4 turn on tracing
# with command substitution, BASH_ENV is sourced, BASH_FUNC_<name>%% defines functions. A value
# set on the pool could therefore print the DSN or run code inside the sink. This file runs under
# /bin/sh (dash), which honours none of them non-interactively. It rebuilds the environment from
# the allow-list below and execs bash with nothing else (docs/contract.md, "Supervisor env
# contract"). Every command is called by absolute path, so PATH from the pool is never used.
set -eu

# Names only: a value containing a newline can add a fake `NAME=` line, which at worst passes an
# empty variable that the supervisor treats as unset.
names=$(/usr/bin/env | /usr/bin/sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | /usr/bin/sort -u)

set --
while IFS= read -r name; do
  case $name in
    CHAINS | SUBSTREAMS_SINK_DSN | DSN | SUBSTREAMS_API_TOKEN | SUBSTREAMS_API_TOKEN_ALT | \
      SUBSTREAMS_ENDPOINTS_CONFIG_TRON | ON_MODULE_HASH_MISMATCH | SINK_*) ;;
    *) continue ;;
  esac
  # $name matched the identifier pattern above, so this eval only reads that variable.
  value=''
  eval "value=\${$name-}"
  set -- "$@" "$name=$value"
done <<EOF
$names
EOF

exec /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/sink TMPDIR=/tmp "$@" \
  /bin/bash --noprofile --norc /app/sinks/supervisor.sh
