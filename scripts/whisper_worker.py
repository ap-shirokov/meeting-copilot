#!/usr/bin/env python3
"""Persistent local transcription worker; newline-delimited JSON in/out."""
import json, os, sys, traceback
try:
    import mlx_whisper
except Exception as e:
    print(json.dumps({"error": "MLX Whisper импорт: " + str(e)}, ensure_ascii=False), flush=True)
    sys.exit(1)
model = os.environ.get("WHISPER_MODEL", "mlx-community/whisper-large-v3-mlx")
for line in sys.stdin:
    path = None
    try:
        req=json.loads(line)
        path=req['path']
        result=mlx_whisper.transcribe(path, path_or_hf_repo=model, language=None, verbose=False)
        print(json.dumps({"text":result.get("text", "").strip()}, ensure_ascii=False), flush=True)
    except Exception as e:
        print(json.dumps({"error":str(e)}, ensure_ascii=False), flush=True)
    finally:
        if path:
            try: os.remove(path)
            except OSError: pass
