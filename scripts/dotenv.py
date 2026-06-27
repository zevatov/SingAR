"""Minimal .env loader — no external dependencies. Loads `.env` from the
project root (parent of this file's directory) into os.environ if present.
Existing environment variables take precedence over file values.
"""
import os
from pathlib import Path


def load_env() -> None:
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if not env_path.exists():
        return
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            # Don't override already-set env vars.
            os.environ.setdefault(key, value)
