SHELL := /bin/bash
.DEFAULT_GOAL := help

# ─────────────────────────────────────────────────────────────────────────────
# Shared configuration. Per-stack config lives in make/*.mk (included below).
#
# Help text is generated from `## comments` on targets and `##@ Section`
# markers — annotate a new target and it shows up in `make help` automatically.
# ─────────────────────────────────────────────────────────────────────────────

UV           ?= uv
PYTHON       ?= .venv/bin/python
HF_TOKEN     ?=
HF_HUB_CACHE ?= $(HOME)/.cache/huggingface/hub

# Per-machine default model: both M2 Pro and M5 run omlx, but serve different
# models. Override with `MODEL_REPO=... make <target>`. Falls back to Qwen if
# chip detection fails. See scripts/detect_machine.sh.
MACHINE_CHIP_SHORT ?= $(shell bash scripts/detect_machine.sh --quiet 2>/dev/null | sed -n "s/^MACHINE_CHIP_SHORT='\(.*\)'/\1/p")
ifeq ($(MACHINE_CHIP_SHORT),M5)
MODEL_REPO ?= mlx-community/gemma-4-26B-A4B-it-qat-nvfp4
else
MODEL_REPO ?= mlx-community/Qwen3.6-35B-A3B-nvfp4
endif
MODEL_SLUG ?= $(subst /,__,$(MODEL_REPO))
MODEL_DIR  ?= models/$(MODEL_SLUG)

include make/model.mk    # model download, machine detection, system tuning
include make/omlx.mk     # omlx multi-model server (default) + benchmarking
include make/vllm.mk     # vllm-mlx server (alternative engine)
include make/sd.mk       # stable-diffusion.cpp server (text-to-image)
include make/legacy.mk   # mlx_lm.server (legacy, testing only)

.PHONY: help quickstart install server-install test lint format typecheck clean

##@ Setup

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@printf '\n\033[1mCurrent configuration\033[0m\n'
	@printf '  %-20s %s\n' \
		'MODEL_REPO'    '$(MODEL_REPO)' \
		'MODEL_DIR'     '$(MODEL_DIR)' \
		'OMLX_PORT'     '$(OMLX_PORT)' \
		'VLLM_PORT'     '$(VLLM_PORT)' \
		'SD_PORT'       '$(SD_PORT)' \
		'PORT (legacy)' '$(PORT)'
	@printf '\n\033[1mExamples\033[0m\n'
	@printf '  %s\n' \
		'make quickstart                                        # fresh Mac -> running omlx' \
		'make bench BENCH_ARGS="--max-tokens 1024 --no-unload"  # pass flags to mlx-bench' \
		'make model-download MODEL_REPO=mlx-community/Qwen3-Embedding-4B-4bit-DWQ' \
		''

quickstart: ## One-click: deps -> download model -> start omlx -> health-check
	@MODEL_REPO="$(MODEL_REPO)" MODEL_DIR="$(MODEL_DIR)" \
		HOST="$(HOST)" PORT="$(PORT)" \
		HF_TOKEN="$(HF_TOKEN)" \
		bash scripts/bootstrap.sh

install: ## Install base project dependencies
	$(UV) sync

server-install: ## Install serving/download dependencies (--extra server)
	$(UV) sync --extra server

##@ Development

test: ## Run the test suite
	$(UV) run pytest

lint: ## Lint with ruff
	$(UV) run ruff check .

format: ## Format with ruff
	$(UV) run ruff format .

typecheck: ## Type-check with mypy (strict)
	$(UV) run mypy .

clean: clean-server ## Remove venv, caches, and server PID/log files
	rm -rf .venv .pytest_cache .ruff_cache .mypy_cache
	find . -type d -name "__pycache__" -exec rm -rf {} +
