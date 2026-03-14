# Copilot instructions for mlx-learning

This repository is a minimal Python project (pyproject.toml, hello.py). The file below helps future Copilot sessions understand how to build, test, and reason about this repository.

## Build, test, and lint commands
- Build: This project uses modern Python packaging via pyproject.toml. No build step is required for development. To create a wheel or sdist (if needed):
  - python -m build

- Install dependencies for development (venv recommended):
  - python -m venv .venv
  - source .venv/bin/activate  # macOS / Linux
  - python -m pip install --upgrade pip
  - python -m pip install -e .  # installs package in editable mode

- Tests: No test suite is present. If tests are added with pytest, run the full suite with:
  - pytest
  Run a single test function or file with:
  - pytest path/to/test_file.py::test_function_name

- Linting / Formatting: No linting configuration is present. Common commands to run if configuration is added:
  - flake8
  - ruff .
  - black .

If CI/workflow files are later added, prefer copying their commands here.

## High-level architecture
- Purpose: A tiny starter Python package named `mlx-learning` (see pyproject.toml). The repository currently contains a single module:
  - hello.py — contains a simple `main()` function that prints a message and runs when executed as __main__.

- Packaging: Managed via pyproject.toml (PEP 517/518). No dependencies are declared. The project targets Python >=3.13.

- Typical flow for Copilot sessions:
  1. Inspect pyproject.toml to discover package metadata and Python version.
  2. Inspect top-level scripts (e.g., hello.py) to find runnable examples and expected CLI entrypoints.
  3. If tests or src/ appear later, prefer running tests and reading package modules to learn behavior.

## Key conventions and repo-specific notes
- Project layout: Minimal single-module layout. No src/ package present. If repository grows, expect pyproject.toml to be authoritative for packaging and dependency info.

- Python version pinning: pyproject.toml sets `requires-python = ">=3.13"`. Use that when suggesting language features or typing.

- No CI or test configs: Do not assume test frameworks or linters are present. Before suggesting tests/lints/CI changes, add or check for pytest/flake8/ruff/black configuration files.

- Editing guidance for Copilot:
  - When asked to add new functionality, add a package/module under a `src/` layout or update pyproject.toml accordingly, and include tests (pytest) and a tox/CI step where appropriate.
  - Keep changes minimal and surgical: update pyproject.toml when adding runtime or dev dependencies.

## Files to check first (priority for Copilot)
1. pyproject.toml — package metadata, Python version, build/backend.
2. README.md — user-level instructions and examples.
3. Any top-level .py scripts (e.g., hello.py) — runnable examples and simple behaviors.

## AI assistant integrations and other assistant configs
- No CLAUDE.md, .cursorrules, AGENTS.md, .windsurfrules, CONVENTIONS.md, .clinerules, or similar files were found. If added later, incorporate their important parts here.

---

If you want, configure MCP servers (e.g., Playwright) relevant to this project. Would you like to set up any MCP servers now?

Summary: created .github/copilot-instructions.md with build/test/lint guidance, high-level architecture, and repo-specific conventions. Would you like to adjust or extend any section (for example, add exact test commands once pytest is added)?
