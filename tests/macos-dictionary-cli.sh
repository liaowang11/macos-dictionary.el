#!/bin/sh

set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/macos-dictionary.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

clang -O2 -Wall -Wextra -Werror \
  -framework CoreServices -framework Foundation \
  "$repository/macos-dictionary.m" \
  -o "$temporary/macos-dictionary-cli"

"$temporary/macos-dictionary-cli" --list >"$temporary/dictionaries.json"
jq -e '
  length > 0 and
  all(.[]; (.name | length > 0) and (.shortName | length > 0))
' "$temporary/dictionaries.json" >/dev/null

"$temporary/macos-dictionary-cli" run >"$temporary/run.json"
jq -e '
  .word == "run" and
  (.dictionaries | length > 1) and
  all(.dictionaries[];
      (.name | length > 0) and
      (.shortName | length > 0) and
      (.entries | length > 0) and
      all(.entries[];
          (.headword | ascii_downcase) == "run" and
          (.html | contains("<html"))))
' "$temporary/run.json" >/dev/null
