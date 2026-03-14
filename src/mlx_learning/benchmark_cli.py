import time

import requests
import typer
from mlx_lm import generate, load
from rich.console import Console
from rich.table import Table

console = Console()
app = typer.Typer()

def test_mlx(model_path: str, prompt: str, max_tokens: int = 512, verbose: bool = False):
    console.print(f"\n[bold green]--- Testing MLX: {model_path} ---[/bold green]")
    try:
        model, tokenizer = load(model_path)
    except Exception as e:
        console.print(f"[bold red]Failed to load MLX model: {e}[/bold red]")
        return None

    # Warmup
    if verbose:
        console.print("[yellow]Warming up...[/yellow]")

    # We run generate to measure.
    # To get precise tokens/s without verbose output polluting the stream,
    # we can use the time measurements around the generate call.
    # Note: MLX generate is lazy in some contexts but here it returns the string.

    start_time = time.perf_counter()
    output = generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=verbose)
    end_time = time.perf_counter()

    # Calculate tokens.
    # We need to encode the output to count tokens accurately if we don't trust the simple split.
    # However, generate returns the text. Let's re-encode to count.
    # Note: This includes the prompt in some countings, but usually we care about generated tokens.
    # mlx_lm.generate returns the *generated* text.

    generated_tokens = len(tokenizer.encode(output))
    duration = end_time - start_time
    tps = generated_tokens / duration

    console.print(f"[cyan]Generated Tokens:[/cyan] {generated_tokens}")
    console.print(f"[cyan]Duration:[/cyan] {duration:.2f}s")
    console.print(f"[bold magenta]Tokens/sec:[/bold magenta] {tps:.2f}")

    if verbose:
        console.print(f"[dim]{output[:100]}...[/dim]")

    return tps

def test_ollama(model_name: str, prompt: str, max_tokens: int = 512, verbose: bool = False):
    console.print(f"\n[bold blue]--- Testing Ollama: {model_name} ---[/bold blue]")
    url = "http://localhost:11434/api/generate"
    payload = {
        "model": model_name,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": max_tokens
        }
    }

    try:
        response = requests.post(url, json=payload)

        if response.status_code == 200:
            data = response.json()
            tokens = data.get("eval_count", 0)
            duration_ns = data.get("eval_duration", 1) # nanoseconds
            # Duration reported by Ollama is precise for eval
            # But let's use our wall clock for consistency with MLX or use Ollama's internal metric?
            # Ollama's eval_duration is strictly generation time.
            # Our wall clock includes network RTT.
            # Let's use Ollama's metric for fairness to the engine,
            # but note that MLX is local so wall clock is fair for it.
            # Actually, to be fair, we should use wall clock for both as "end-to-end" latency
            # or use the engine's reported speed if available.
            # The previous script used tokens / (duration_ns / 1e9).

            tps = tokens / (duration_ns / 1e9)

            console.print(f"[cyan]Generated Tokens:[/cyan] {tokens}")
            console.print(f"[cyan]Duration:[/cyan] {duration_ns / 1e9:.2f}s")
            console.print(f"[bold magenta]Tokens/sec:[/bold magenta] {tps:.2f}")

            if verbose:
                console.print(f"[dim]{data['response'][:100]}...[/dim]")

            return tps
        else:
            console.print(f"[bold red]Ollama error: {response.status_code}[/bold red]")
            return None
    except requests.exceptions.ConnectionError:
        console.print("[bold red]Could not connect to Ollama. Is it running?[/bold red]")
        return None

@app.command()
def benchmark(
    ollama_model: str = typer.Option("qwen3.5:latest", help="Ollama model name"),
    mlx_model: str = typer.Option("mlx-community/Qwen3.5-9B-MLX-4bit", help="MLX model path/repo"),
    prompt: str = typer.Option("Write a 200-word introduction to quantum computing for a 10-year-old.", help="Prompt to use"),
    max_tokens: int = typer.Option(512, help="Max tokens to generate"),
    verbose: bool = typer.Option(False, help="Show verbose output"),
    compare: bool = typer.Option(True, help="Run comparison"),
):
    """
    Benchmark MLX vs Ollama performance.
    """
    console.rule("[bold]MLX vs Ollama Benchmark[/bold]")

    results = {}

    # Test Ollama
    if compare or not mlx_model:
        tps = test_ollama(ollama_model, prompt, max_tokens, verbose)
        if tps:
            results["Ollama"] = tps

    # Test MLX
    if compare or not ollama_model:
        tps = test_mlx(mlx_model, prompt, max_tokens, verbose)
        if tps:
            results["MLX"] = tps

    # Summary
    if len(results) > 1:
        console.rule("[bold]Comparison Result[/bold]")
        table = Table(title="Performance Comparison")
        table.add_column("Engine", style="cyan")
        table.add_column("Tokens/sec", justify="right", style="magenta")
        table.add_column("Relative Speed", justify="right", style="green")

        base_tps = min(results.values())

        for engine, tps in results.items():
            speedup = tps / base_tps
            table.add_row(engine, f"{tps:.2f}", f"{speedup:.2f}x")

        console.print(table)

if __name__ == "__main__":
    app()
