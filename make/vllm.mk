# vllm-mlx — alternative OpenAI-compatible MLX server.
#
# Shares port 8000 with omlx: stop one before starting the other.
# Since omlx 0.5.4rc1 the two are at throughput parity on the M2 Pro, so this
# is kept as an alternative engine, not a recommended upgrade. See
# docs/performance.md.
#
# Install: uv tool install vllm-mlx   (~2.5 GB; pulls in PyTorch)

.PHONY: vllm-install vllm-start vllm-stop vllm-restart vllm-status vllm-logs vllm-bench

# Follows the per-machine MODEL_REPO default; override independently if needed.
VLLM_MODEL_REPO ?= $(MODEL_REPO)
VLLM_MODEL_SLUG ?= $(subst /,__,$(VLLM_MODEL_REPO))
VLLM_MODEL_DIR  ?= models/$(VLLM_MODEL_SLUG)
VLLM_HOST       ?= 0.0.0.0
VLLM_PORT       ?= 8000
VLLM_PID        ?= vllm-server.pid
VLLM_LOG        ?= vllm-server.log

# Mirrors OMLX_EXTRA_ARGS: --gpu-memory-utilization ↔ --memory-guard,
# --cache-memory-mb ↔ --hot-cache-max-size, --max-num-seqs ↔
# --max-concurrent-requests, --max-cache-blocks ↔ --initial-cache-blocks.
VLLM_EXTRA_ARGS ?= --gpu-memory-utilization 0.90 --cache-memory-mb 4096 \
                   --max-num-seqs 2 --use-paged-cache --max-cache-blocks 1024

##@ vllm-mlx server (alternative, port 8000)

vllm-install: ## Check that vllm-mlx is on PATH
	@if ! command -v vllm-mlx >/dev/null 2>&1; then \
		echo "vllm-mlx not found. Install with:"; \
		echo "  uv tool install vllm-mlx"; \
		exit 1; \
	fi
	@vllm-mlx --version 2>/dev/null || echo "vllm-mlx installed"

vllm-start: ## Start vllm-mlx on VLLM_PORT (stop omlx first — same port)
	@bash scripts/detect_machine.sh
	@if [ -f "$(VLLM_PID)" ] && kill -0 "$$(cat "$(VLLM_PID)")" 2>/dev/null; then \
		echo "vllm-mlx already running with PID $$(cat "$(VLLM_PID)")"; exit 0; \
	fi
	@if lsof -nP -iTCP:$(VLLM_PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Port $(VLLM_PORT) is already in use (omlx running?):"; \
		lsof -nP -iTCP:$(VLLM_PORT) -sTCP:LISTEN; \
		exit 1; \
	fi
	@if [ ! -d "$(VLLM_MODEL_DIR)" ]; then \
		echo "Model directory not found: $(VLLM_MODEL_DIR)"; \
		echo "Run: make model-download MODEL_REPO=$(VLLM_MODEL_REPO)"; \
		exit 1; \
	fi
	@nohup vllm-mlx serve "$(VLLM_MODEL_DIR)" \
		--served-model-name "$(VLLM_MODEL_SLUG)" \
		--host "$(VLLM_HOST)" --port "$(VLLM_PORT)" \
		$(VLLM_EXTRA_ARGS) >"$(VLLM_LOG)" 2>&1 & \
	pid=$$!; echo "$$pid" > "$(VLLM_PID)"; \
	echo "Started vllm-mlx PID $$pid on $(VLLM_HOST):$(VLLM_PORT) ($(VLLM_MODEL_SLUG))"

vllm-stop: ## Stop vllm-mlx
	@if [ ! -f "$(VLLM_PID)" ]; then echo "No vllm-mlx PID file"; exit 0; fi
	@pid=$$(cat "$(VLLM_PID)"); \
	if kill -0 "$$pid" 2>/dev/null; then kill "$$pid"; echo "Stopped vllm-mlx PID $$pid"; \
	else echo "PID $$pid not running"; fi; \
	rm -f "$(VLLM_PID)"

vllm-restart: vllm-stop vllm-start ## Restart vllm-mlx

vllm-status: ## Show vllm-mlx PID, model, and endpoint
	@if [ -f "$(VLLM_PID)" ]; then echo "PID: $$(cat "$(VLLM_PID)")"; else echo "PID: not running"; fi
	@echo "Model:    $(VLLM_MODEL_SLUG)"
	@echo "Endpoint: http://127.0.0.1:$(VLLM_PORT)/v1"
	@lsof -nP -iTCP:$(VLLM_PORT) -sTCP:LISTEN || true

vllm-logs: ## Tail the vllm-mlx log
	@tail -n 200 "$(VLLM_LOG)"

# --no-unload because vllm-mlx has no per-model unload endpoint.
vllm-bench: ## Benchmark VLLM_MODEL_SLUG against vllm-mlx
	@bash scripts/detect_machine.sh
	$(UV) run mlx-bench "$(VLLM_MODEL_SLUG)" \
		--omlx-url http://127.0.0.1:$(VLLM_PORT) \
		--no-unload
