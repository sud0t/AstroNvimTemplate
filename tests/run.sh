#!/usr/bin/env bash
# Runs the tests of the configuration tree this file is in, and prints the result of each.
#   tests/run.sh [name ...]    the tests named (ai_sandbox, git_keys, ...), or all of them
# Exits with 1 when a test failed, and with 2 when it could not run them.
# A test inside the whole configuration gets state, cache and data directories of its own. Its data directory
# has links to the plugins, tools and parsers of yours, so what a plugin installs or a language server logs
# beside its own program still lands in yours.
set -u

# Tests of single modules, in a Neovim that loads no configuration.
clean_tests=(ai_sandbox ai_sandbox_parts ai_provider claude_code)
# Tests inside the whole configuration. They call `whole_config()` of tests/harness.lua.
config_tests=(ai_sandbox_chat comment_keys dap_view git_commit git_keys git jupyter tree_keys)
seconds_per_test=300

# What the configuration loads from the user's data directory: lazy.nvim's plugins, Mason's tools, the
# Treesitter parsers and the list of remote plugins. The rest of it (sessions, picker histories, logs) is
# written, and a test writes its own.
user_data="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
loaded_from_user_data=(lazy mason site rplugin.vim)
# Mason's note of when it last fetched its registry.
user_registry_state="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/mason-registry-update"

die() {
  echo "tests/run.sh: $1" >&2
  exit 2
}

is_in() {
  local wanted="$1" item
  shift
  for item in "$@"; do [ "$item" = "$wanted" ] && return 0; done
  return 1
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || die "cannot find the tree this file is in"
cd "$repo" || die "cannot enter $repo"

for file in tests/*.lua; do
  name="$(basename "$file" .lua)"
  [ "$name" = harness ] || is_in "$name" "${clean_tests[@]}" "${config_tests[@]}" ||
    die "$file is in neither list of tests in tests/run.sh, so nothing would run it"
done

if [ "$#" -gt 0 ]; then names=("$@"); else names=("${clean_tests[@]}" "${config_tests[@]}"); fi
for name in "${names[@]}"; do
  if is_in "$name" "${config_tests[@]}"; then
    # Neovim finds its configuration as $XDG_CONFIG_HOME/nvim, so only a tree of that name can be the one it runs.
    [ "$(basename "$repo")" = nvim ] ||
      die "$name runs the whole configuration, so the tree's directory must be named nvim: $repo"
    # (without them Neovim would start by cloning lazy.nvim into the test's data directory)
    [ -d "$user_data/lazy" ] ||
      die "$name runs the whole configuration, whose plugins are not in $user_data/lazy: start Neovim once"
  elif ! is_in "$name" "${clean_tests[@]}"; then
    die "no test named $name (there are: ${clean_tests[*]} ${config_tests[*]})"
  fi
done

scratch="$(mktemp -d)" || die "cannot make a temporary directory"
trap 'rm -rf "$scratch"' EXIT
export NVIM_LOG_FILE="$scratch/nvim.log"

# Makes the directories of the config test `name` below $scratch/$name.
make_directories() {
  local name="$1" part note="$scratch/$1/cache/nvim/mason-registry-update"
  mkdir -p "$scratch/$name/state" "$scratch/$name/cache/nvim" "$scratch/$name/data/nvim" || return
  for part in "${loaded_from_user_data[@]}"; do
    [ ! -e "$user_data/$part" ] || ln -s "$user_data/$part" "$scratch/$name/data/nvim/$part" || return
  done
  # Mason fetches its registry from GitHub, into its directory, when its note is missing or a day old: a new
  # cache directory would make every test do that. The note says the registry was fetched just now.
  [ ! -f "$user_registry_state" ] || printf '%s\n%s' "$(head -n 1 "$user_registry_state")" "$(date +%s)" >"$note"
}

failed=0
run() {
  local name="$1" output status
  shift
  output="$(timeout "$seconds_per_test" "$@" 2>&1 </dev/null)"
  status=$?
  printf '== %s: %s\n' "$name" "$([ "$status" -eq 0 ] && echo passed || echo "FAILED (exit code $status)")"
  [ -z "$output" ] || printf '%s\n' "$output"
  [ "$status" -eq 0 ] || failed=1
}

for name in "${names[@]}"; do
  if is_in "$name" "${clean_tests[@]}"; then
    run "$name" nvim --clean -i NONE -l "tests/$name.lua"
  else
    make_directories "$name" || die "cannot make the directories of $name in $scratch"
    # The first command is for a test that cannot be loaded and so never calls it itself. The last one makes
    # such a test fail: a test that reports ends Neovim itself, and the error that ends a `luafile` early is
    # only printed.
    run "$name" env XDG_CONFIG_HOME="$(dirname "$repo")" XDG_DATA_HOME="$scratch/$name/data" \
      XDG_STATE_HOME="$scratch/$name/state" XDG_CACHE_HOME="$scratch/$name/cache" \
      nvim --headless -i NONE \
      -c 'lua dofile("tests/harness.lua").whole_config()' \
      -c "luafile tests/$name.lua" \
      -c cq
  fi
done
exit "$failed"
