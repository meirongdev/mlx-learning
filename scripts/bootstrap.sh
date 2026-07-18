#!/usr/bin/env bash
# One-click bootstrap: platform check -> deps -> model download -> omlx serve -> health check.
#
# Idempotent: safe to re-run. Every step checks state before acting.
#
# Env overrides (all optional):
#   MODEL_REPO      (machine-aware default — see Makefile / scripts/detect_machine.sh)
#   MODEL_DIR       default: models/<MODEL_REPO with / -> __>
#   HOST            default: 0.0.0.0
#   PORT            default: 8000
#   HF_TOKEN        optional — only needed for gated/private repos
#   SKIP_SERVER     set to 1 to stop after model download

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Machine-aware MODEL_REPO defaults (mirrors Makefile logic)
MACHINE_CHIP_SHORT="$(
  bash "$REPO_ROOT/scripts/detect_machine.sh" --quiet 2>/dev/null \
    | sed -n "s/^MACHINE_CHIP_SHORT='\(.*\)'/\1/p"
)"
if [ "$MACHINE_CHIP_SHORT" = "M5" ]; then
  DEFAULT_REPO="mlx-community/gemma-4-26B-A4B-it-qat-nvfp4"
else
  DEFAULT_REPO="mlx-community/Qwen3.6-35B-A3B-nvfp4"
fi

MODEL_REPO="${MODEL_REPO:-$DEFAULT_REPO}"
MODEL_SLUG="${MODEL_REPO//\//__}"
MODEL_DIR="${MODEL_DIR:-models/${MODEL_SLUG}}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
HF_TOKEN="${HF_TOKEN:-}"
SKIP_SERVER="${SKIP_SERVER:-0}"

cd "$REPO_ROOT"

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'; c_reset=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()   { printf '%s  ✓ %s%s\n' "$c_green" "$*" "$c_reset"; }
warn() { printf '%s  ! %s%s\n' "$c_yellow" "$*" "$c_reset"; }
die()  { printf '%s  ✗ %s%s\n' "$c_red" "$*" "$c_reset" >&2; exit 1; }

# --- 1. Platform ---------------------------------------------------------------
step "Checking platform"
# This repo is shared between an M2 Pro and an M5 (both 32 GB). Print chip/RAM/
# bandwidth before doing anything that depends on the machine.
"$REPO_ROOT/scripts/detect_machine.sh" || die "platform check failed"

eval "$("$REPO_ROOT/scripts/detect_machine.sh" --quiet)"

if (( MACHINE_RAM_GB < 24 )); then
    warn "${MACHINE_RAM_GB} GB is tight for the default 35B MoE (~19 GB on disk, 3B active). Consider a smaller model or lower context."
fi

if (( MACHINE_WIRED_MB < 16000 )); then
    warn "GPU wired memory limit is low (${MACHINE_WIRED_MB}MB). Performance may suffer."
    warn "Run 'make optimize-system' to set it to 30000MB (recommended for 32GB RAM Macs)."
fi

# --- 2. uv --------------------------------------------------------------------
step "Checking uv"
if ! command -v uv >/dev/null 2>&1; then
    warn "uv not found — installing via official installer"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [[ -f "$HOME/.local/bin/env" ]] && source "$HOME/.local/bin/env"
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || die "uv install succeeded but 'uv' is still not on PATH. Open a new shell and re-run."
fi
ok "uv $(uv --version | awk '{print $2}')"

# --- 3. Python deps -----------------------------------------------------------
step "Installing server dependencies (uv sync --extra server)"
uv sync --extra server
ok "dependencies installed"

# --- 4. Model download --------------------------------------------------------
step "Downloading model: ${MODEL_REPO}"

is_model_complete() {
    [[ -f "$MODEL_DIR/config.json" ]] || return 1
    [[ -f "$MODEL_DIR/model.safetensors" || -f "$MODEL_DIR/model.safetensors.index.json" ]] || return 1
    ! find "$MODEL_DIR" -name '*.incomplete' -print -quit | grep -q .
}

if is_model_complete; then
    ok "already present at $MODEL_DIR — skipping download"
else
    mkdir -p "$(dirname "$MODEL_DIR")"
    HF_TOKEN="$HF_TOKEN" MODEL_REPO="$MODEL_REPO" MODEL_DIR="$MODEL_DIR" \
        uv run python -c '
import os
from pathlib import Path
from huggingface_hub import snapshot_download

repo   = os.environ["MODEL_REPO"]
target = Path(os.environ["MODEL_DIR"])
token  = os.environ.get("HF_TOKEN") or None
target.mkdir(parents=True, exist_ok=True)
print(f"Downloading {repo} -> {target}" + (" (with HF_TOKEN)" if token else " (anonymous)"))
snapshot_download(repo_id=repo, token=token, local_dir=str(target))
print(f"Model ready at {target}")
'
    is_model_complete || die "snapshot at $MODEL_DIR looks incomplete after download"
    ok "model ready at $MODEL_DIR"
fi

[[ "$SKIP_SERVER" == "1" ]] && { step "SKIP_SERVER=1 — not starting server"; exit 0; }

# --- 5. Install omlx (if missing) --------------------------------------------
step "Checking omlx installation"
if command -v omlx >/dev/null 2>&1; then
    ok "omlx $(omlx --version 2>/dev/null || echo 'installed')"
else
    warn "omlx not found — installing via Homebrew tap"
    brew tap jundot/omlx https://github.com/jundot/omlx 2>/dev/null || true
    brew install omlx
    ok "omlx installed"
fi

# --- 6. Start omlx serve ------------------------------------------------------
step "Starting omlx server on ${HOST}:${PORT}"
# omlx auto-discovers models under the parent directory; use models/ as root
OMLX_MODEL_DIR="$(dirname "$MODEL_DIR")"
nohup omlx serve \
    --model-dir "$OMLX_MODEL_DIR" \
    --host "$HOST" \
    --port "$PORT" \
    --memory-guard aggressive \
    --hot-cache-max-size 4GB \
    --max-concurrent-requests 2 \
    --initial-cache-blocks 1024 >"$REPO_ROOT/omlx-server.log" 2>&1 &
pid=$!
echo "$pid" > "$REPO_ROOT/omlx-server.pid"
ok "omlx started (PID $pid)"

# --- 7. Health check ----------------------------------------------------------
step "Waiting for /v1/models to respond (up to 120s)"
deadline=$(( SECONDS + 120 ))
while (( SECONDS < deadline )); do
    if curl -sSf "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        ok "omlx is live on http://${HOST}:${PORT}/v1"
        echo
        printf '  Model slug for API requests: %s\n' "$MODEL_SLUG"
        echo
        echo "  Quick smoke test:"
        printf '    curl http://127.0.0.1:%s/v1/chat/completions \\\n' "$PORT"
        echo   "      -H 'Content-Type: application/json' \\"
        printf '      -d '"'"'{"model":"%s","messages":[{"role":"user","content":"Hi"}],"max_tokens":32}'"'"'\n' "$MODEL_SLUG"
        exit 0
    fi
    sleep 2
done
die "omlx did not respond within 120s on port ${PORT} — check: make omlx-logs"
