# Repository Guidelines

This document provides essential guidance for contributors to the `mlx-learning` repository.

## Project Structure & Module Organization

The project is organized into a clean, modular structure:

- `src/mlx_learning/`: The core Python package. Contains the `mlx-bench` CLI and library logic.
- `tests/`: Unit and integration tests for verifying core functionality.
- `scripts/`: Utility scripts for bootstrapping and model verification.
- `models/`: Directory for storing downloaded model weights (not tracked by Git).
- `Makefile`: Entry point for managing the development environment and server lifecycles.

## Build, Test, and Development Commands

We use `uv` for dependency management and task execution.

- **Environment Setup**: 
  - `make quickstart`: Runs the full bootstrap process (idempotent).
  - `uv sync`: Installs dependencies for the current environment.
- **Development & Quality Control**:
  - `uv run ruff check .`: Lints the codebase using Ruff.
  - `uv run ruff format .`: Formats the code.
  - `uv run mypy .`: Performs strict type checking.
  - `uv run pytest`: Executes the test suite.
- **Serving**:
  - `make server-start`: Starts the `mlx_lm` server.
  - `make omlx-start`: Starts the `omlx` multi-model server.

## Coding Style & Naming Conventions

Maintain high code quality by adhering to these standards:

- **Style & Linting**: All code must pass `ruff` linting and formatting. Use double quotes for strings and 4-space indentation.
- **Type Safety**: This project uses strict type checking. Ensure all functions and variables are correctly typed for `mypy`.
- **Naming**: Follow PEP 8 conventions for Python (e.g., `snake_case` for functions/variables, `PascalCase` for classes).

## Testing Guidelines

- **Framework**: We use `pytest` for all testing.
- **Execution**: Run tests with `uv run pytest`.
- **Structure**: Tests should reside in the `tests/` directory and follow the pattern `test_<module_name>.py`.
- **Coverage**: Ensure new features include corresponding unit tests to maintain stability.

## Commit & Pull Request Guidelines

- **Commits**: Use descriptive, imperative-style commit messages (e.g., `Add feature X`, `Fix bug Y`).
- **Pull Requests**: 
  - Ensure all tests pass (`uv run pytest`) before submitting.
  - Provide a clear description of the changes and any necessary environment adjustments.
  - If the change affects benchmark performance, include the performance delta.
