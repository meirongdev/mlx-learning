#!/usr/bin/env bash
# omlx.sh — manage the omlx multi-model OpenAI-compatible server, brew-aware.
#
# The live deployment on these Macs is a Homebrew LaunchAgent
# (`brew services`, KeepAlive=true) whose ProgramArguments are just `omlx serve`
# with NO flags — every effective setting is read from ~/.omlx/settings.json
# (host, port, model_dir, memory guard, cache, sampling…). The Makefile's
# OMLX_EXTRA_ARGS therefore do NOT describe what the brew service runs.
#
# So when omlx is Homebrew-managed, start/stop/restart delegate to
# `brew services` (which respects KeepAlive and owns :OMLX_PORT). The nohup+PID
# path is a fallback for source installs (set OMLX_FORCE_NOHUP=1 to force it).
# Every start/restart is verified against /v1/models before returning success.
#
# Usage: scripts/omlx.sh {start|stop|restart|status|logs|wait} [logs-lines]
set -uo pipefail

# ---- config (env overrides; defaults mirror the Makefile) --------------------
OMLX_HOST=${OMLX_HOST:-0.0.0.0}
OMLX_PORT=${OMLX_PORT:-8000}
OMLX_MODEL_DIR=${OMLX_MODEL_DIR:-models}
OMLX_PID=${OMLX_PID:-omlx-server.pid}
OMLX_LOG=${OMLX_LOG:-omlx-server.log}
OMLX_EXTRA_ARGS=${OMLX_EXTRA_ARGS:-}
OMLX_LOAD_TIMEOUT=${OMLX_LOAD_TIMEOUT:-900}
OMLX_STOP_TIMEOUT=${OMLX_STOP_TIMEOUT:-30}
OMLX_STARTUP_POLL_INTERVAL=${OMLX_STARTUP_POLL_INTERVAL:-5}
OMLX_BREW_LABEL=${OMLX_BREW_LABEL:-homebrew.mxcl.omlx}
OMLX_FORCE_NOHUP=${OMLX_FORCE_NOHUP:-0}

HEALTH_URL="http://127.0.0.1:${OMLX_PORT}/v1/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- helpers -----------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }

is_brew_managed() {
  [ "$OMLX_FORCE_NOHUP" = "1" ] && return 1
  command -v brew >/dev/null 2>&1 && brew list omlx >/dev/null 2>&1
}

# HTTP status of /v1/models (000 = unreachable). curl already emits 000 on a
# failed connection via -w; only fall back to 000 if it printed nothing at all.
health_code() {
  local code
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)
  echo "${code:-000}"
}

# Count of models advertised by /v1/models (0 if unreachable).
model_count() {
  curl -s -m 3 "$HEALTH_URL" 2>/dev/null | grep -o '"id"' | wc -l | tr -d ' '
}

# PIDs listening on OMLX_PORT.
port_pids() { lsof -nP -iTCP:"$OMLX_PORT" -sTCP:LISTEN -t 2>/dev/null; }

# PID(s) of the actual omlx worker process.
server_pids() { pgrep -f 'omlx-server' 2>/dev/null; }

# Poll /v1/models until HTTP 200 or timeout. Returns 0 healthy, 1 timed out.
wait_healthy() {
  local timeout=${1:-$OMLX_LOAD_TIMEOUT} waited=0 interval=$OMLX_STARTUP_POLL_INTERVAL code
  while :; do
    code=$(health_code)
    if [ "$code" = "200" ]; then
      log "omlx healthy after ${waited}s — $(model_count) model(s) at ${HEALTH_URL}"
      return 0
    fi
    [ "$waited" -ge "$timeout" ] && { log "omlx did not become healthy within ${timeout}s (last HTTP ${code})"; return 1; }
    log "waiting for omlx… (${waited}s, HTTP ${code})"
    sleep "$interval"; waited=$((waited + interval))
  done
}

# Poll until nothing listens on OMLX_PORT or timeout. Returns 0 free, 1 busy.
wait_port_free() {
  local timeout=${1:-$OMLX_STOP_TIMEOUT} waited=0
  while [ -n "$(port_pids)" ]; do
    [ "$waited" -ge "$timeout" ] && { log "port ${OMLX_PORT} still held after ${timeout}s by: $(port_pids | tr '\n' ' ')"; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  return 0
}

detect_machine() {
  [ -x "$SCRIPT_DIR/detect_machine.sh" ] && bash "$SCRIPT_DIR/detect_machine.sh" || true
}

# ---- subcommands -------------------------------------------------------------
start_brew() {
  log "omlx is Homebrew-managed → brew services start omlx"
  brew services start omlx >/dev/null 2>&1 || true
  wait_healthy
}

start_nohup() {
  if [ -n "$(port_pids)" ]; then
    log "Port ${OMLX_PORT} already in use by PID(s): $(port_pids | tr '\n' ' ')"
    return 1
  fi
  log "Starting omlx via nohup (source-install fallback)…"
  # shellcheck disable=SC2086
  nohup omlx serve \
    --model-dir "$OMLX_MODEL_DIR" \
    --host "$OMLX_HOST" \
    --port "$OMLX_PORT" \
    $OMLX_EXTRA_ARGS >"$OMLX_LOG" 2>&1 &
  echo "$!" >"$OMLX_PID"
  log "Started omlx PID $(cat "$OMLX_PID") on ${OMLX_HOST}:${OMLX_PORT} (models: ${OMLX_MODEL_DIR})"
  wait_healthy
}

cmd_start() {
  detect_machine
  if [ "$(health_code)" = "200" ]; then
    log "omlx already running and healthy — $(model_count) model(s) at ${HEALTH_URL}"
    return 0
  fi
  if is_brew_managed; then start_brew; else start_nohup; fi
}

stop_brew() {
  log "brew services stop omlx"
  brew services stop omlx >/dev/null 2>&1 || true
  wait_port_free
}

stop_nohup() {
  if [ ! -f "$OMLX_PID" ]; then log "No omlx PID file ($OMLX_PID)"; return 0; fi
  local pid; pid=$(cat "$OMLX_PID")
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; log "Stopped omlx PID $pid"; else log "PID $pid not running"; fi
  rm -f "$OMLX_PID"
  wait_port_free
}

cmd_stop() {
  if is_brew_managed; then stop_brew; else stop_nohup; fi
}

# `brew services restart` can silently no-op: an orphaned omlx-server (ppid=1)
# can keep :OMLX_PORT while the relaunched instance dies on the port conflict.
# So verify the restart took (fresh PID + healthy); if not, force-recover.
recover_orphan() {
  log "Restart did not take — recovering from orphaned omlx-server…"
  local p
  for p in $(port_pids) $(server_pids); do kill "$p" 2>/dev/null || true; done
  launchctl bootout "gui/$(id -u)/${OMLX_BREW_LABEL}" 2>/dev/null || true
  wait_port_free 15 || true
  brew services start omlx >/dev/null 2>&1 || true
  wait_healthy
}

cmd_restart() {
  detect_machine
  if is_brew_managed; then
    local old_pids; old_pids=$(server_pids | tr '\n' ' ')
    log "brew services restart omlx (was PID: ${old_pids:-none})"
    brew services restart omlx >/dev/null 2>&1 || true
    if wait_healthy; then
      local new_pids; new_pids=$(server_pids | tr '\n' ' ')
      if [ -n "$new_pids" ] && [ "$new_pids" = "$old_pids" ]; then
        log "WARNING: omlx-server PID unchanged (${new_pids}) — restart may not have replaced the process; verifying via recovery."
        recover_orphan
      fi
    else
      recover_orphan
    fi
  else
    stop_nohup; start_nohup
  fi
}

cmd_status() {
  if is_brew_managed; then
    echo "Mode:      Homebrew service (${OMLX_BREW_LABEL})"
    brew services info omlx 2>/dev/null | grep -iE '^(Running|PID|Loaded|Schedulable):' | sed 's/^/  /'
  else
    echo "Mode:      nohup"
    if [ -f "$OMLX_PID" ]; then echo "  PID file: $(cat "$OMLX_PID")"; else echo "  PID file: (none)"; fi
  fi
  echo "Endpoint:  http://127.0.0.1:${OMLX_PORT}/v1"
  echo "Model dir: ${OMLX_MODEL_DIR}"
  local code; code=$(health_code)
  if [ "$code" = "200" ]; then
    echo "Health:    HTTP 200 — $(model_count) model(s)"
  else
    echo "Health:    HTTP ${code} (not responding)"
  fi
  ps -axo pid,etime,comm 2>/dev/null | grep 'omlx-server' | grep -v grep | sed 's/^/  proc: /' || true
  lsof -nP -iTCP:"$OMLX_PORT" -sTCP:LISTEN 2>/dev/null | sed 's/^/  port: /' || true
}

cmd_logs() {
  local n=${1:-200}
  if is_brew_managed; then
    local blog; blog="$(brew --prefix)/var/log/omlx.log"
    if [ -f "$blog" ]; then tail -n "$n" "$blog"; else log "No brew log at $blog"; fi
  else
    if [ -f "$OMLX_LOG" ]; then tail -n "$n" "$OMLX_LOG"; else log "No log file at $OMLX_LOG"; fi
  fi
}

# ---- dispatch ----------------------------------------------------------------
case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    cmd_logs "${2:-200}" ;;
  wait)    wait_healthy "${2:-$OMLX_LOAD_TIMEOUT}" ;;
  *) log "Usage: $0 {start|stop|restart|status|logs|wait} [logs-lines]"; exit 2 ;;
esac
