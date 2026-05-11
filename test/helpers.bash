# test/helpers.bash — shared setup for bats tests
# Source this from each test file: `load 'helpers.bash'`

# Resolve repo root regardless of where bats is invoked from
CCM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CCM_REPO_ROOT

# Each test gets a private temp $HOME so we never touch real state
ccm_setup_tmphome() {
  CCM_TMPHOME="$(mktemp -d -t ccm-test-XXXXXX)"
  export CCM_TMPHOME
  export HOME="$CCM_TMPHOME"
  mkdir -p "$HOME/.claude"
  mkdir -p "$HOME/.local/bin"
}

ccm_teardown_tmphome() {
  if [[ -n "${CCM_TMPHOME:-}" && -d "$CCM_TMPHOME" ]]; then
    rm -rf "$CCM_TMPHOME"
  fi
}

# Create a fake `claude` on PATH that echoes a deterministic response.
# Use this in tests to avoid real LLM calls.
ccm_stub_claude() {
  local response="${1:-STUBBED}"
  local stub_dir="$CCM_TMPHOME/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<EOF
#!/usr/bin/env bash
# Stub for testing — ignores all args, prints fixed response
cat <<RESPONSE
$response
RESPONSE
EOF
  chmod +x "$stub_dir/claude"
  export PATH="$stub_dir:$PATH"
}

# Source a lib file from the repo
ccm_source_lib() {
  local lib_name="$1"
  source "$CCM_REPO_ROOT/lib/$lib_name"
}

# Stub the remote version checker by overriding _ccm_remote_version
ccm_stub_remote_version() {
  local v="$1"
  eval "_ccm_remote_version() { echo '$v'; }"
}
