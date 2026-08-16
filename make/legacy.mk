# mlx_lm.server / mlx_vlm.server — the original single-model server.
#
# Superseded by omlx for all real use; kept on port 5001 for testing a model
# straight out of mlx-lm without omlx in the way. Unlike omlx this serves one
# model, has no LRU memory management, and no /v1/embeddings|rerank|audio.

.PHONY: server-bootstrap server-start server-stop server-restart server-status \
	server-logs clean-server verify

# mlx_lm.server for text-only LLMs (Qwen, Llama, ...);
# mlx_vlm.server for VLMs (Gemma 4, ...).
SERVER_MODULE ?= mlx_lm.server
HOST          ?= 0.0.0.0
PORT          ?= 5001
PID_FILE      ?= mlx-server.pid
LOG_FILE      ?= mlx-server.log

LOAD_TIMEOUT          ?= 900
STARTUP_POLL_INTERVAL ?= 5
STOP_TIMEOUT          ?= 30
EXTRA_SERVER_ARGS     ?=

##@ mlx_lm.server (legacy, port 5001)

server-bootstrap: model-download server-start ## Download the model then start the legacy server

server-start: server-install ## Start SERVER_MODULE on HOST:PORT, wait until listening
	@if [ ! -d "$(MODEL_DIR)" ]; then \
		echo "Model directory not found: $(MODEL_DIR)"; \
		echo "Run: make model-download HF_TOKEN=... MODEL_REPO=$(MODEL_REPO)"; \
		exit 1; \
	fi
	@if [ -f "$(PID_FILE)" ] && kill -0 "$$(cat "$(PID_FILE)")" 2>/dev/null; then \
		echo "Server already running with PID $$(cat "$(PID_FILE)")"; \
		exit 0; \
	fi
	@if lsof -nP -iTCP:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Port $(PORT) is already in use:"; \
		lsof -nP -iTCP:$(PORT) -sTCP:LISTEN; \
		exit 1; \
	fi
	@{ \
			mkdir -p "$(HF_HUB_CACHE)"; \
			nohup env HF_HUB_CACHE="$(HF_HUB_CACHE)" $(PYTHON) -m $(SERVER_MODULE) \
				--model "$(MODEL_DIR)" \
				--host "$(HOST)" \
				--port "$(PORT)" \
				$(EXTRA_SERVER_ARGS) >"$(LOG_FILE)" 2>&1 & \
		pid=$$!; \
		echo "$$pid" > "$(PID_FILE)"; \
		echo "Started $(SERVER_MODULE) with PID $$pid"; \
		deadline=$$((SECONDS + $(LOAD_TIMEOUT))); \
		while [ $$SECONDS -lt $$deadline ]; do \
			if ! kill -0 "$$pid" 2>/dev/null; then \
				echo "Server exited during startup."; \
				tail -n 200 "$(LOG_FILE)" 2>/dev/null || true; \
				exit 1; \
			fi; \
			if lsof -nP -iTCP:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
				echo "Server is listening on $(HOST):$(PORT)"; \
				exit 0; \
			fi; \
			sleep "$(STARTUP_POLL_INTERVAL)"; \
		done; \
		echo "Timed out waiting for the server to listen on port $(PORT)."; \
		tail -n 200 "$(LOG_FILE)" 2>/dev/null || true; \
		exit 1; \
	}

server-stop: ## Stop the legacy server (SIGTERM, then SIGKILL after STOP_TIMEOUT)
	@if [ ! -f "$(PID_FILE)" ]; then \
		echo "No PID file found at $(PID_FILE)"; \
		exit 0; \
	fi
	@pid=$$(cat "$(PID_FILE)"); \
	if kill -0 "$$pid" 2>/dev/null; then \
		kill "$$pid"; \
		echo "Stopping server PID $$pid"; \
		deadline=$$((SECONDS + $(STOP_TIMEOUT))); \
		while kill -0 "$$pid" 2>/dev/null; do \
			if [ $$SECONDS -ge $$deadline ]; then \
				echo "PID $$pid did not exit after SIGTERM, sending SIGKILL"; \
				kill -9 "$$pid"; \
				break; \
			fi; \
			sleep 1; \
		done; \
		while lsof -nP -iTCP:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; do \
			if [ $$SECONDS -ge $$deadline ]; then \
				echo "Port $(PORT) is still busy after stop timeout"; \
				lsof -nP -iTCP:$(PORT) -sTCP:LISTEN; \
				exit 1; \
			fi; \
			sleep 1; \
		done; \
		echo "Stopped server PID $$pid"; \
	else \
		echo "PID $$pid is not running"; \
	fi
	@rm -f "$(PID_FILE)"

server-restart: server-stop server-start ## Restart the legacy server

server-status: ## Show legacy server PID, model, and endpoint
	@if [ -f "$(PID_FILE)" ]; then \
		echo "PID: $$(cat "$(PID_FILE)")"; \
	else \
		echo "PID: not running"; \
	fi
	@echo "Model repo: $(MODEL_REPO)"
	@echo "Model dir:  $(MODEL_DIR)"
	@echo "Server:     $(SERVER_MODULE)"
	@echo "Endpoint:   http://127.0.0.1:$(PORT)"
	@lsof -nP -iTCP:$(PORT) -sTCP:LISTEN || true

server-logs: ## Tail the legacy server log
	@tail -n 200 "$(LOG_FILE)"

verify: ## Smoke-test the legacy server and inspect the local config.json
	@$(PYTHON) scripts/verify_model.py --base http://127.0.0.1:$(PORT) --model "$(MODEL_DIR)"

clean-server: ## Remove the legacy server PID/log files
	rm -f "$(PID_FILE)" "$(LOG_FILE)"
