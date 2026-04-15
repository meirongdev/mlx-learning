#!/usr/bin/env bash
set -euo pipefail
BASE_URL=${BASE_URL:-http://127.0.0.1:5001}
MODEL=${MODEL:-models/mlx-community__gemma-4-26b-a4b-it-4bit}
PYTHON_VENV=.venv/bin/python

echo "=== querying server $BASE_URL for model $MODEL ==="
curl -sS -X POST "$BASE_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"Reply with your model_type only.\"},{\"role\":\"user\",\"content\":\"Report your model_type\"}],\"max_tokens\":10,\"temperature\":0.0}" || true

echo
echo "=== authoritative check: reading config.json ==="
if [ -x "$PYTHON_VENV" ]; then
  "$PYTHON_VENV" - <<'PY'
import json,sys
p='models/mlx-community__gemma-4-26b-a4b-it-4bit/config.json'
try:
    j=json.load(open(p))
    print('config.json model_type:', j.get('model_type'))
except Exception as e:
    print('failed to read config.json:', e)
    sys.exit(2)
PY
else
  python - <<'PY'
import json,sys
p='models/mlx-community__gemma-4-26b-a4b-it-4bit/config.json'
try:
    j=json.load(open(p))
    print('config.json model_type:', j.get('model_type'))
except Exception as e:
    print('failed to read config.json:', e)
    sys.exit(2)
PY
fi
