from mlx_learning.hello import main
import pytest

def test_hello(capsys):
    main()
    captured = capsys.readouterr()
    assert "Hello from mlx-learning!" in captured.out
