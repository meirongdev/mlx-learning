# MLX Learning & Benchmark

This repository contains tools and scripts for learning and benchmarking [MLX](https://github.com/ml-explore/mlx) on Apple Silicon, specifically comparing it against [Ollama](https://ollama.com).

## Prerequisites

- **Python 3.11+**
- **[uv](https://github.com/astral-sh/uv)** (Recommended for fast dependency management)
- **Ollama** (for comparison benchmarks)

## Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd mlx-learning
    ```

2.  **Install dependencies using `uv`:**
    ```bash
    uv sync
    ```
    This will create a virtual environment and install all required packages.

## Usage

### Running the Benchmark

We provide a CLI tool `mlx-bench` to compare generation speed between MLX and Ollama.

To run the default benchmark (comparing Qwen 3.5 9B):

```bash
uv run mlx-bench
```

**Options:**

- `--ollama-model`: Specify the Ollama model tag (default: `qwen3.5:latest`)
- `--mlx-model`: Specify the MLX model path or HuggingFace repo (default: `mlx-community/Qwen3.5-9B-MLX-4bit`)
- `--prompt`: Custom prompt text
- `--max-tokens`: Maximum tokens to generate
- `--verbose`: Show generated text and detailed logs

Example:
```bash
uv run mlx-bench --prompt "Explain black holes" --max-tokens 256
```

### Development

**Linting & Formatting:**
```bash
uv run ruff check .
uv run ruff format .
```

**Type Checking:**
```bash
uv run mypy .
```

**Running Tests:**
```bash
uv run pytest
```

## Benchmark Results (M2 MBP 32GB)

We tested the generation performance of MLX vs Ollama using Qwen 3.5 9B (4-bit quantization).

| Engine | Model | Tokens/sec | Relative Speed |
| :--- | :--- | :--- | :--- |
| Ollama | qwen3.5:latest (9B) | 18.58 | 1.00x |
| MLX | Qwen3.5-9B-MLX-4bit | 28.35 | 1.53x |

**Run it yourself:**
```bash
uv run mlx-bench --max-tokens 128
```

## Directory Structure

- `src/mlx_learning/`: Source code package
- `tests/`: Unit and integration tests
- `pyproject.toml`: Project configuration and dependencies
