import time

import requests
import typer
from rich.console import Console
from rich.table import Table

console = Console()
app = typer.Typer()


def warmup_model(base_url: str, model_name: str, timeout: float | None = None) -> float | None:
    """Trigger model load with a tiny request; return elapsed seconds (or None on failure)."""
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": "hi"}],
        "stream": False,
        "max_tokens": 1,
    }
    try:
        start = time.perf_counter()
        resp = requests.post(url, json=payload, timeout=timeout)
        elapsed = time.perf_counter() - start
        if resp.status_code != 200:
            console.print(f"[bold red]Warmup failed ({resp.status_code}):[/bold red] {resp.text[:200]}")
            return None
        return elapsed
    except requests.RequestException as e:
        console.print(f"[bold red]Warmup error:[/bold red] {e}")
        return None


def unload_model(base_url: str, model_name: str) -> bool:
    """Tell omlx to free the model from memory."""
    url = f"{base_url.rstrip('/')}/v1/models/{model_name}/unload"
    try:
        resp = requests.post(url, timeout=60)
    except requests.RequestException as e:
        console.print(f"[yellow]Unload request failed for {model_name}: {e}[/yellow]")
        return False
    if resp.status_code == 200:
        return True
    # 400 "Model not loaded" is fine — nothing to free.
    if resp.status_code == 400 and "not loaded" in resp.text.lower():
        return True
    console.print(f"[yellow]Unload {model_name}: {resp.status_code} {resp.text[:200]}[/yellow]")
    return False


def test_omlx(base_url: str, model_name: str, prompt: str, max_tokens: int = 512, verbose: bool = False):
    console.print(f"[bold blue]--- Testing omlx: {model_name} @ {base_url} ---[/bold blue]")
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    payload = {
        "model": model_name,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "max_tokens": max_tokens,
    }

    try:
        start_time = time.perf_counter()
        response = requests.post(url, json=payload)
        end_time = time.perf_counter()

        if response.status_code == 200:
            data = response.json()
            usage = data.get("usage", {})
            tokens = usage.get("completion_tokens", 0)

            duration = end_time - start_time
            tps = tokens / duration if duration > 0 else 0

            console.print(f"[cyan]Generated Tokens:[/cyan] {tokens}")
            console.print(f"[cyan]Duration:[/cyan] {duration:.2f}s")
            console.print(f"[bold magenta]Tokens/sec (wall clock):[/bold magenta] {tps:.2f}")

            if verbose:
                content = data["choices"][0]["message"]["content"]
                console.print(f"[dim]{content[:100]}...[/dim]")

            return tps
        else:
            console.print(f"[bold red]omlx error: {response.status_code} - {response.text}[/bold red]")
            return None
    except requests.exceptions.ConnectionError:
        console.print(f"[bold red]Could not connect to omlx at {base_url}. Is it running?[/bold red]")
        return None


@app.command()
def benchmark(
    models: list[str] = typer.Argument(..., help="omlx model name(s) to benchmark (e.g. model1 model2)"),
    omlx_url: str = typer.Option("http://127.0.0.1:8000", help="omlx base URL"),
    prompt: str = typer.Option("Write a 200-word introduction to quantum computing for a 10-year-old.", help="Prompt to use"),
    max_tokens: int = typer.Option(512, help="Max tokens to generate"),
    warmup: bool = typer.Option(True, help="Warm up each model before timing (excludes cold-load from tokens/sec)"),
    unload: bool = typer.Option(True, help="Unload each model after testing to free memory before the next"),
    verbose: bool = typer.Option(False, help="Show verbose output"),
):
    """
    Benchmark omlx model(s) sequentially: load -> test -> unload -> next.
    """
    console.rule("[bold]omlx Benchmark[/bold]")

    results: dict[str, float] = {}
    load_times: dict[str, float] = {}

    for idx, model in enumerate(models, start=1):
        console.rule(f"[bold cyan][{idx}/{len(models)}] {model}[/bold cyan]")
        try:
            if warmup:
                load_s = warmup_model(omlx_url, model)
                if load_s is None:
                    console.print(f"[red]Skipping {model}: warmup failed[/red]")
                    continue
                load_times[model] = load_s
                console.print(f"[dim]Loaded/warmed in {load_s:.2f}s[/dim]")

            tps = test_omlx(omlx_url, model, prompt, max_tokens, verbose)
            if tps:
                results[model] = tps
        finally:
            if unload:
                if unload_model(omlx_url, model):
                    console.print(f"[dim]Unloaded {model}[/dim]")

    # Summary
    if results:
        console.rule("[bold]Comparison Result[/bold]")
        table = Table(title="Performance Comparison")
        table.add_column("Model", style="cyan")
        table.add_column("Tokens/sec", justify="right", style="magenta")
        if load_times:
            table.add_column("Load (s)", justify="right", style="yellow")
        if len(results) >= 2:
            table.add_column("Relative Speed", justify="right", style="green")

        base_tps = min(results.values())
        for model, tps in sorted(results.items(), key=lambda x: x[1], reverse=True):
            row = [model, f"{tps:.2f}"]
            if load_times:
                row.append(f"{load_times[model]:.2f}" if model in load_times else "-")
            if len(results) >= 2:
                row.append(f"{tps / base_tps:.2f}x")
            table.add_row(*row)

        console.print(table)


if __name__ == "__main__":
    app()
