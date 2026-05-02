#!/usr/bin/env bash
# One-click bootstrap: platform check -> deps -> model download -> mlx_lm.server -> health check.
#
# Idempotent: safe to re-run. Every step checks state before acting.
#
# Env overrides (all optional):
#   MODEL_REPO      default: mlx-community/Qwen3.6-35B-A3B-4bit
#   MODEL_DIR       default: models/<MODEL_REPO with / -> __>
#   HOST            default: 0.0.0.0
#   PORT            default: 5001
#   HF_TOKEN        optional — only needed for gated/private repos
#   SKIP_SERVER     set to 1 to stop after model download

set -euo pipefail

MODEL_REPO="${MODEL_REPO:-mlx-community/Qwen3.6-35B-A3B-4bit}"
MODEL_SLUG="${MODEL_REPO//\//__}"
MODEL_DIR="${MODEL_DIR:-models/${MODEL_SLUG}}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-5001}"
HF_TOKEN="${HF_TOKEN:-}"
SKIP_SERVER="${SKIP_SERVER:-0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- 5. Start mlx_lm.server ---------------------------------------------------
step "Starting mlx_lm.server on ${HOST}:${PORT}"
MODEL_REPO="$MODEL_REPO" MODEL_DIR="$MODEL_DIR" HOST="$HOST" PORT="$PORT" \
    make -s server-start

# --- 6. Health check ----------------------------------------------------------
step "Waiting for /v1/models to respond (up to 120s)"
deadline=$(( SECONDS + 120 ))
while (( SECONDS < deadline )); do
    if curl -sSf "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        ok "mlx_lm.server is live on http://${HOST}:${PORT}/v1"
        echo
        printf '  Model ID in API requests: %s\n' "$MODEL_DIR"
        echo
        echo "  Quick smoke test:"
        printf '    curl http://127.0.0.1:%s/v1/chat/completions \\\n' "$PORT"
        echo   "      -H 'Content-Type: application/json' \\"
        printf '      -d '"'"'{"model":"%s","messages":[{"role":"user","content":"Hi"}],"max_tokens":32}'"'"'\n' "$MODEL_DIR"
        exit 0
    fi
    sleep 2
done
die "server did not respond within 120s after port opened — check: make server-logs"
