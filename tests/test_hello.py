import pytest

from mlx_learning.hello import main


def test_hello(capsys: pytest.CaptureFixture[str]) -> None:
    main()
    captured = capsys.readouterr()
    assert "Hello from mlx-learning!" in captured.out
