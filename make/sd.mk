# stable-diffusion.cpp — FLUX.2 Klein 4B distilled, text-to-image.
#
# Exposes the OpenAI /v1/images/generations shape on port 7860 so it coexists
# with omlx on 8000. Needs three files: diffusion model + VAE + Qwen3-4B LLM
# text encoder (FLUX.2 uses an LLM, not CLIP/T5, as its text encoder).

.PHONY: sd-install sd-model-download sd-start sd-stop sd-status sd-logs

SD_BIN_DIR    ?= bin
SD_SERVER     ?= $(SD_BIN_DIR)/sd-server
SD_MODEL_DIR  ?= models-sd
SD_DIFF_MODEL ?= $(SD_MODEL_DIR)/flux-2-klein-4b-Q4_0.gguf
SD_VAE        ?= $(SD_MODEL_DIR)/flux2-vae.safetensors
SD_LLM        ?= $(SD_MODEL_DIR)/Qwen3-4B-Q4_K_M.gguf
SD_HOST       ?= 0.0.0.0
SD_PORT       ?= 7860
SD_PID        ?= sd-server.pid
SD_LOG        ?= sd-server.log

# --diffusion-fa: flash attention for diffusion.
# --cfg-scale 1.0 + --steps 4: required settings for the distilled Klein model.
SD_EXTRA_ARGS ?= --diffusion-fa --cfg-scale 1.0 --steps 4

##@ stable-diffusion.cpp (text-to-image, port 7860)

sd-install: ## Download the sd.cpp macOS ARM64 binary into ./bin/
	@echo "Downloading stable-diffusion.cpp binary (macOS ARM64)..."
	@mkdir -p "$(SD_BIN_DIR)"
	@ASSET_URL=$$(curl -s https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest \
		| python3 -c "import sys,json; assets=json.load(sys.stdin)['assets']; \
		  url=[a['browser_download_url'] for a in assets if 'Darwin' in a['name'] and 'arm64' in a['name']]; \
		  print(url[0] if url else '')"); \
	if [ -z "$$ASSET_URL" ]; then echo "Could not find macOS ARM64 binary in latest release"; exit 1; fi; \
	echo "Downloading $$ASSET_URL ..."; \
	curl -L -o /tmp/sd-cpp-macos.zip "$$ASSET_URL"; \
	unzip -o /tmp/sd-cpp-macos.zip -d "$(SD_BIN_DIR)"; \
	chmod +x "$(SD_BIN_DIR)/sd-server" "$(SD_BIN_DIR)/sd-cli" 2>/dev/null || true; \
	rm -f /tmp/sd-cpp-macos.zip; \
	echo "Installed: $$(ls $(SD_BIN_DIR)/)"

sd-model-download: server-install ## Download FLUX.2 Klein 4B + VAE + Qwen3-4B encoder
	@echo "Downloading FLUX.2 Klein 4B model files into $(SD_MODEL_DIR)/ ..."
	@mkdir -p "$(SD_MODEL_DIR)"
	@HF_TOKEN="$(HF_TOKEN)" $(PYTHON) -c '\
import os; from huggingface_hub import hf_hub_download; token = os.environ.get("HF_TOKEN") or None; \
target = "$(SD_MODEL_DIR)"; \
print("1/3 diffusion model: leejet/FLUX.2-klein-4B-GGUF / flux-2-klein-4b-Q4_0.gguf"); \
hf_hub_download(repo_id="leejet/FLUX.2-klein-4B-GGUF", filename="flux-2-klein-4b-Q4_0.gguf", local_dir=target, token=token); \
print("2/3 VAE: Comfy-Org/flux2-klein-4B / split_files/vae/flux2-vae.safetensors"); \
hf_hub_download(repo_id="Comfy-Org/flux2-klein-4B", filename="split_files/vae/flux2-vae.safetensors", local_dir=target, local_dir_use_symlinks=False, token=token); \
import shutil; shutil.move(target+"/split_files/vae/flux2-vae.safetensors", target+"/flux2-vae.safetensors") if not __import__("os").path.exists(target+"/flux2-vae.safetensors") else None; \
print("3/3 LLM text encoder: unsloth/Qwen3-4B-GGUF / Qwen3-4B-Q4_K_M.gguf"); \
hf_hub_download(repo_id="unsloth/Qwen3-4B-GGUF", filename="Qwen3-4B-Q4_K_M.gguf", local_dir=target, token=token); \
print("All model files ready in $(SD_MODEL_DIR)/")'

sd-start: ## Start sd-server on SD_PORT
	@if [ ! -f "$(SD_SERVER)" ]; then \
		echo "sd-server not found. Run: make sd-install"; exit 1; \
	fi
	@if [ ! -f "$(SD_DIFF_MODEL)" ] || [ ! -f "$(SD_VAE)" ] || [ ! -f "$(SD_LLM)" ]; then \
		echo "Model files missing. Run: make sd-model-download"; exit 1; \
	fi
	@if [ -f "$(SD_PID)" ] && kill -0 "$$(cat "$(SD_PID)")" 2>/dev/null; then \
		echo "sd-server already running with PID $$(cat "$(SD_PID)")"; exit 0; \
	fi
	@if lsof -nP -iTCP:$(SD_PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Port $(SD_PORT) already in use:"; lsof -nP -iTCP:$(SD_PORT) -sTCP:LISTEN; exit 1; \
	fi
	@nohup "$(SD_SERVER)" \
		--diffusion-model "$(SD_DIFF_MODEL)" \
		--vae "$(SD_VAE)" \
		--llm "$(SD_LLM)" \
		--listen-ip "$(SD_HOST)" --listen-port "$(SD_PORT)" \
		$(SD_EXTRA_ARGS) >"$(SD_LOG)" 2>&1 & \
	pid=$$!; echo "$$pid" > "$(SD_PID)"; \
	echo "Started sd-server PID $$pid on $(SD_HOST):$(SD_PORT) (FLUX.2 Klein 4B)"

sd-stop: ## Stop sd-server
	@if [ ! -f "$(SD_PID)" ]; then echo "No sd-server PID file"; exit 0; fi
	@pid=$$(cat "$(SD_PID)"); \
	if kill -0 "$$pid" 2>/dev/null; then kill "$$pid"; echo "Stopped sd-server PID $$pid"; \
	else echo "PID $$pid not running"; fi; \
	rm -f "$(SD_PID)"

sd-status: ## Show sd-server PID, endpoint, and model paths
	@if [ -f "$(SD_PID)" ]; then echo "PID: $$(cat "$(SD_PID)")"; else echo "PID: not running"; fi
	@echo "Endpoint: http://127.0.0.1:$(SD_PORT)/v1/images/generations"
	@echo "Models:"
	@echo "  diffusion: $(SD_DIFF_MODEL)"
	@echo "  vae:       $(SD_VAE)"
	@echo "  llm:       $(SD_LLM)"
	@lsof -nP -iTCP:$(SD_PORT) -sTCP:LISTEN || true

sd-logs: ## Tail the sd-server log
	@tail -n 200 "$(SD_LOG)"
