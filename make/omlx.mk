# omlx — multi-model OpenAI-compatible server. The default engine on both boxes.
#
# ⚠️ The live deployment on these Macs is a Homebrew LaunchAgent (KeepAlive=true)
# that runs bare `omlx serve` and reads ALL config from ~/.omlx/settings.json.
# OMLX_EXTRA_ARGS below therefore applies ONLY to the nohup source-install
# fallback in scripts/omlx.sh — the brew service ignores it. To change live
# behaviour edit ~/.omlx/settings.json and `make omlx-restart`.
#
# All lifecycle logic lives in scripts/omlx.sh (brew-vs-nohup detection, health
# polling, orphan recovery); these targets only pass configuration through.

.PHONY: omlx-install omlx-start omlx-stop omlx-restart omlx-status omlx-logs \
	omlx-metrics omlx-metrics-preview bench

OMLX_HOST      ?= 0.0.0.0
OMLX_PORT      ?= 8000
OMLX_MODEL_DIR ?= models
OMLX_PID       ?= omlx-server.pid
OMLX_LOG       ?= omlx-server.log

# omlx 0.4.x removed --max-process-memory; use --memory-guard {safe,balanced,
# aggressive} (or --memory-guard-gb N for a hard ceiling). "aggressive"
# preserves the old 90% intent.
OMLX_EXTRA_ARGS ?= --memory-guard aggressive --memory-guard-gb 27 --hot-cache-max-size 4GB --max-concurrent-requests 2 --initial-cache-blocks 1024

# Restart/stop robustness knobs. omlx unloads a large model on shutdown, so the
# socket can take several seconds to free — stop waits before start rebinds;
# start/restart poll /v1/models until healthy.
OMLX_LOAD_TIMEOUT          ?= 900
OMLX_STOP_TIMEOUT          ?= 30
OMLX_STARTUP_POLL_INTERVAL ?= 5

# Homebrew LaunchAgent label. When this service is loaded it (not the nohup
# path) owns :OMLX_PORT, so scripts/omlx.sh delegates to `brew services`
# instead of fighting KeepAlive.
OMLX_BREW_LABEL ?= homebrew.mxcl.omlx

OMLX_ENV = OMLX_HOST="$(OMLX_HOST)" OMLX_PORT="$(OMLX_PORT)" OMLX_MODEL_DIR="$(OMLX_MODEL_DIR)" \
	OMLX_PID="$(OMLX_PID)" OMLX_LOG="$(OMLX_LOG)" OMLX_EXTRA_ARGS="$(OMLX_EXTRA_ARGS)" \
	OMLX_LOAD_TIMEOUT="$(OMLX_LOAD_TIMEOUT)" OMLX_STOP_TIMEOUT="$(OMLX_STOP_TIMEOUT)" \
	OMLX_STARTUP_POLL_INTERVAL="$(OMLX_STARTUP_POLL_INTERVAL)" OMLX_BREW_LABEL="$(OMLX_BREW_LABEL)"

##@ omlx server (default, port 8000)

omlx-install: ## Check that omlx is on PATH, print install instructions if not
	@echo "Checking omlx installation..."
	@if ! command -v omlx >/dev/null 2>&1; then \
		echo "omlx not found on PATH."; \
		echo "Install via Homebrew:"; \
		echo "  brew tap jundot/omlx https://github.com/jundot/omlx"; \
		echo "  brew install omlx"; \
		echo "  brew services start omlx"; \
		echo ""; \
		echo "Or from source (requires Python 3.10+, macOS 15+):"; \
		echo "  git clone https://github.com/jundot/omlx.git && cd omlx"; \
		echo "  pip install -e ."; \
		exit 1; \
	fi
	@echo "omlx $(shell omlx --version 2>/dev/null || echo 'installed') found on PATH"

omlx-start: ## Start omlx (brew service or nohup fallback), wait until healthy
	@$(OMLX_ENV) bash scripts/omlx.sh start

omlx-stop: ## Stop omlx and wait for the port to free
	@$(OMLX_ENV) bash scripts/omlx.sh stop

omlx-restart: ## Restart omlx — REQUIRED after `brew upgrade omlx`
	@$(OMLX_ENV) bash scripts/omlx.sh restart

omlx-status: ## Show mode, endpoint, health, and loaded model count
	@$(OMLX_ENV) bash scripts/omlx.sh status

omlx-logs: ## Tail the omlx log (brew log if brew-managed)
	@$(OMLX_ENV) bash scripts/omlx.sh logs

##@ omlx observability

# omlx 0.6.x has no /metrics endpoint. These render ~/.omlx/stats.json into a
# Prometheus textfile-collector snapshot. node_exporter must be started with
# --collector.textfile.directory=$(OMLX_TEXTFILE_DIR) or the file is ignored.
OMLX_STATS_PATH   ?= $(HOME)/.omlx/stats.json
OMLX_TEXTFILE_DIR ?= $(HOME)/.local/var/lib/node_exporter/textfile_collector

omlx-metrics: ## Write ~/.omlx/stats.json to the node_exporter textfile dir once
	$(UV) run omlx-textfile-collector \
		--stats-path "$(OMLX_STATS_PATH)" --output-dir "$(OMLX_TEXTFILE_DIR)"

omlx-metrics-preview: ## Print the .prom rendering to stdout without writing it
	@$(UV) run omlx-textfile-collector --stats-path "$(OMLX_STATS_PATH)" --stdout

##@ Benchmark

# mlx-bench requires at least one model slug; default to this machine's model.
# Override the set with BENCH_MODELS="slug1 slug2", or pass flags via BENCH_ARGS.
BENCH_MODELS ?= $(MODEL_SLUG)
BENCH_ARGS   ?=

bench: ## Benchmark BENCH_MODELS on omlx (default: this machine's MODEL_SLUG)
	@bash scripts/detect_machine.sh
	$(UV) run mlx-bench $(BENCH_MODELS) --omlx-url http://127.0.0.1:$(OMLX_PORT) $(BENCH_ARGS)
