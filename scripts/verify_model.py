#!/usr/bin/env python3
"""Perform a short inference and inspect local config.json for model_type."""
import json
from urllib import request
url = 'http://127.0.0.1:5001/chat/completions'
model = 'models/mlx-community__gemma-4-26b-a4b-it-4bit'
payload = json.dumps({
    'model': model,
    'messages': [
        {'role': 'system', 'content': 'Reply with your model_type only.'},
        {'role': 'user', 'content': 'Report your model_type'}
    ],
    'max_tokens': 10,
    'temperature': 0.0
}).encode('utf-8')
req = request.Request(url, data=payload, headers={'Content-Type': 'application/json'})
try:
    with request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
    print('server_response:', json.dumps(resp, ensure_ascii=False))
except Exception as e:
    print('server request failed:', e)

# authoritative
try:
    with open('models/mlx-community__gemma-4-26b-a4b-it-4bit/config.json', 'r') as f:
        cfg = json.load(f)
    print('config.json model_type:', cfg.get('model_type'))
except Exception as e:
    print('failed to read config.json:', e)
    raise
