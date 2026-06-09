"""
conjur_client.py — read secrets written by the Conjur Secrets Provider sidecar.

The sidecar fetches secrets from Conjur at pod startup and writes them to
/conjur/secrets/secrets.env in dotenv format. This module just reads that file.
"""

import logging
import os
import time
from pathlib import Path

log = logging.getLogger(__name__)

SECRETS_FILE = Path(os.getenv("CONJUR_SECRETS_VOLUME", "/conjur/secrets")) / "secrets.env"


def _load() -> dict:
    if not SECRETS_FILE.exists():
        return {}
    result = {}
    for line in SECRETS_FILE.read_text().splitlines():
        line = line.strip()
        if line and "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            result[k.strip()] = v.strip().strip('"').strip("'")
    return result


def get_secret(secret_id: str, retries: int = 12, delay: float = 10.0) -> str:
    """Return secret value by its Conjur variable ID, retrying until the sidecar writes it."""
    key = secret_id.replace("/", "_")
    for attempt in range(1, retries + 1):
        secrets = _load()
        if key in secrets:
            return secrets[key]
        log.warning("secret not ready yet (%d/%d): %s", attempt, retries, key)
        if attempt < retries:
            time.sleep(delay)
    raise RuntimeError(f"Secret '{secret_id}' not found after {retries} attempts. Check sidecar logs.")
