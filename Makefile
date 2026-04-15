SHELL := /bin/bash
.DEFAULT_GOAL := help

UV ?= uv
PYTHON ?= .venv/bin/python
HF_TOKEN ?=
HF_HUB_CACHE ?= $(HOME)/.cache/huggingface/hub
MODEL_REPO ?= mlx-community/gemma-4-26b-a4b-it-4bit
MODEL_SLUG ?= $(subst /,__,$(MODEL_REPO))
MODEL_DIR ?= models/$(MODEL_SLUG)
SERVER_MODULE ?= mlx_vlm.server
HOST ?= 0.0.0.0
PORT ?= 5001
PID_FILE ?= mlx-server.pid
LOG_FILE ?= mlx-server.log
LOAD_TIMEOUT ?= 900
STARTUP_POLL_INTERVAL ?= 5
STOP_TIMEOUT ?= 30
EXTRA_SERVER_ARGS ?=

.PHONY: help install server-install model-download server-bootstrap server-start server-stop \
	server-restart server-status server-logs test lint format clean clean-server bench

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make install                         - Install base project dependencies' \
		'  make server-install                  - Install server dependencies (mlx-vlm + Hugging Face)' \
		'  make model-download HF_TOKEN=...     - Download MODEL_REPO into MODEL_DIR' \
		'  make server-bootstrap HF_TOKEN=...   - Download the model (if needed) and start the server' \
		'  make server-start                    - Start the configured model server on HOST:PORT' \
		'  make server-stop                     - Stop the running model server' \
		'  make server-restart                  - Restart the running model server' \
		'  make server-status                   - Show server PID, port, and model info' \
		'  make server-logs                     - Tail the server log' \
		'' \
		'Configurable variables:' \
		'  MODEL_REPO=$(MODEL_REPO)' \
		'  MODEL_DIR=$(MODEL_DIR)' \
		'  SERVER_MODULE=$(SERVER_MODULE)' \
		'  HOST=$(HOST)' \
		'  PORT=$(PORT)' \
		'' \
		'Examples:' \
		'  make server-install' \
		'  make model-download HF_TOKEN=hf_xxx MODEL_REPO=mlx-community/gemma-4-26b-a4b-it-4bit' \
		'  make server-start PORT=5001' \
		'  make server-start MODEL_REPO=mlx-community/Qwen2.5-7B-Instruct-4bit SERVER_MODULE=mlx_lm.server'

install:
	$(UV) sync

server-install:
	$(UV) sync --extra server

model-download: server-install
	@if [ -z "$(HF_TOKEN)" ]; then \
		echo "HF_TOKEN is required. Example: make model-download HF_TOKEN=hf_xxx"; \
		exit 1; \
	fi
	@mkdir -p "$(dir $(MODEL_DIR))"
	@HF_TOKEN="$(HF_TOKEN)" MODEL_REPO="$(MODEL_REPO)" MODEL_DIR="$(MODEL_DIR)" $(PYTHON) -c '\
from pathlib import Path; \
import os; \
from huggingface_hub import snapshot_download; \
repo = os.environ["MODEL_REPO"]; \
target = Path(os.environ["MODEL_DIR"]); \
target.mkdir(parents=True, exist_ok=True); \
print(f"Downloading {repo} -> {target}"); \
snapshot_download(repo_id=repo, token=os.environ["HF_TOKEN"], local_dir=target); \
print(f"Model is ready at {target}")'

server-bootstrap: model-download server-start

server-start: server-install
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

server-stop:
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

server-restart: server-stop server-start

server-status:
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

server-logs:
	@tail -n 200 "$(LOG_FILE)"

test:
	$(UV) run pytest

lint:
	$(UV) run ruff check .

format:
	$(UV) run ruff format .

clean-server:
	rm -f "$(PID_FILE)" "$(LOG_FILE)"

clean: clean-server
	rm -rf .venv
	rm -rf .pytest_cache
	rm -rf .ruff_cache
	rm -rf __pycache__
	find . -type d -name "__pycache__" -exec rm -rf {} +

bench:
	$(UV) run mlx-bench

# OpenAI-compatible proxy to MLX server
PROXY_PORT ?= 5101
PROXY_HOST ?= 0.0.0.0
PROXY_PID ?= mlx-proxy.pid
PROXY_LOG ?= mlx-proxy.log

proxy-start:
	@echo "Starting OpenAI-compat proxy on $(PROXY_HOST):$(PROXY_PORT)"
	@if [ -f "$(PROXY_PID)" ] && kill -0 "$$(cat "$(PROXY_PID)")" 2>/dev/null; then \
		echo "Proxy already running with PID $$(cat "$(PROXY_PID)")"; exit 0; \
	fi
	@nohup .venv/bin/python scripts/openai_proxy.py --host $(PROXY_HOST) --port $(PROXY_PORT) >"$(PROXY_LOG)" 2>&1 & \
	pid=$$!; echo "$$pid" > "$(PROXY_PID)"; echo "Started proxy PID $$pid"

proxy-stop:
	@if [ -f "$(PROXY_PID)" ]; then \
		pid=$$(cat "$(PROXY_PID)"); \
		if kill -0 "$$pid" 2>/dev/null; then kill "$$pid"; echo "Stopped proxy PID $$pid"; fi; \
		rm -f "$(PROXY_PID)"; \
	else \
		echo "No proxy PID file"; \
	fi

proxy-status:
	@echo "Proxy PID file: $(PROXY_PID)"; if [ -f "$(PROXY_PID)" ]; then echo "PID: $$(cat $(PROXY_PID))"; fi; lsof -nP -iTCP:$(PROXY_PORT) -sTCP:LISTEN || true

proxy-logs:
	@tail -n 200 "$(PROXY_LOG)"

