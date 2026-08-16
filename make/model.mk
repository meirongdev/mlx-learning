# Model download, machine detection, and macOS GPU memory tuning.
#
# This repo runs on two machines with different memory subsystems (M2 Pro
# 200 GB/s, M5 153.6 GB/s), so anything host-dependent prints the detected
# machine first — otherwise logs and benchmark numbers are unattributable.

.PHONY: detect-machine optimize-system model-download

##@ Models & machine

detect-machine: ## Print chip / RAM / bandwidth / GPU wired limit
	@bash scripts/detect_machine.sh

model-download: server-install ## Download MODEL_REPO into MODEL_DIR (HF_TOKEN optional)
	@bash scripts/detect_machine.sh
	@echo "Target: $(MODEL_REPO) -> $(MODEL_DIR)"
	@mkdir -p "$(dir $(MODEL_DIR))"
	@HF_TOKEN="$(HF_TOKEN)" MODEL_REPO="$(MODEL_REPO)" MODEL_DIR="$(MODEL_DIR)" $(PYTHON) -c '\
from pathlib import Path; \
import os; \
from huggingface_hub import snapshot_download; \
repo = os.environ["MODEL_REPO"]; \
target = Path(os.environ["MODEL_DIR"]); \
token = os.environ.get("HF_TOKEN") or None; \
target.mkdir(parents=True, exist_ok=True); \
print(f"Downloading {repo} -> {target}" + (" (with HF_TOKEN)" if token else " (anonymous)")); \
snapshot_download(repo_id=repo, token=token, local_dir=target); \
print(f"Model is ready at {target}")'

# macOS resets iogpu.wired_limit_mb on every reboot. If it drops below the omlx
# ceiling, omlx clamps to the kernel value and logs
# "Metal cap (…) is below the oMLX static ceiling (…)".
optimize-system: ## Raise macOS GPU wired memory limit to 30720 MB (needs sudo)
	@echo "Optimizing GPU wired memory limit..."
	@bash scripts/detect_machine.sh
	@echo "Current value: $$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 'not set')"
	@echo "Setting to 30720 (30.0 GB; omlx's recommended cap for 32GB Macs with large models)..."
	sudo sysctl iogpu.wired_limit_mb=30720
	@echo "Done. NOTE: macOS resets this on reboot — re-run after each boot."
