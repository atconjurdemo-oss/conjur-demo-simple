"""
conjur_client.py — retrieve secrets from Conjur.

Secrets are read from the shared volume written by the Secrets Provider
sidecar container, with a direct Conjur REST API call as fallback.

get_secret(secret_id) is the only public function the rest of the app uses.
"""

import os
import time
import logging
from pathlib import Path
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

log = logging.getLogger(__name__)

# ── Strategy 1: sidecar volume ───────────────────────────────────────────────
SECRETS_VOLUME = Path(os.getenv("CONJUR_SECRETS_VOLUME", "/conjur/secrets"))
SECRETS_FILE   = SECRETS_VOLUME / "secrets.env"


def _load_dotenv() -> dict:
    if not SECRETS_FILE.exists():
        return {}
    result = {}
    for line in SECRETS_FILE.read_text().splitlines():
        line = line.strip()
        if line and "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            v = v.strip().strip('"').strip("'")
            result[k.strip()] = v
    return result


def _from_volume(secret_id: str) -> Optional[str]:
    key = secret_id.replace("/", "_")
    env = _load_dotenv()
    if env:
        log.debug("secret from sidecar dotenv: %s", key)
        return env.get(key)
    return None


# ── Strategy 2: Conjur REST API via JWT authenticator ────────────────────────
CONJUR_URL     = os.getenv("CONJUR_APPLIANCE_URL", "")
CONJUR_ACCOUNT = os.getenv("CONJUR_ACCOUNT", "myConjurAccount")
CONJUR_AUTHN   = os.getenv(
    "CONJUR_AUTHN_URL",
    f"{CONJUR_URL}/authn-jwt/k8s-cluster/{CONJUR_ACCOUNT}/authenticate",
)
SA_TOKEN = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")


def _session() -> requests.Session:
    s = requests.Session()
    s.mount("https://", HTTPAdapter(max_retries=Retry(
        total=4, backoff_factor=0.5, status_forcelist=[500, 502, 503, 504]
    )))
    cert = os.getenv("CONJUR_SSL_CERTIFICATE", "")
    s.verify = cert if cert else True
    return s


def _jwt_authenticate() -> str:
    jwt = SA_TOKEN.read_text().strip()
    resp = _session().post(CONJUR_AUTHN, data={"jwt": jwt})
    resp.raise_for_status()
    log.info("Conjur JWT authentication succeeded")
    return resp.text


def _from_api(secret_id: str) -> str:
    token = _jwt_authenticate()
    url = (f"{CONJUR_URL}/secrets/{CONJUR_ACCOUNT}/variable/"
           f"{requests.utils.quote(secret_id, safe='')}")
    resp = _session().get(
        url, headers={"Authorization": f'Token token="{token}"'}
    )
    resp.raise_for_status()
    log.info("fetched %s from Conjur API", secret_id)
    return resp.text.strip()


# ── Public interface ──────────────────────────────────────────────────────────

def get_secret(secret_id: str, retries: int = 12, delay: float = 10.0) -> str:
    """Return secret value, retrying until the sidecar has written the file."""
    for attempt in range(1, retries + 1):
        value = _from_volume(secret_id)
        if value:
            return value
        if CONJUR_URL:
            try:
                return _from_api(secret_id)
            except Exception as exc:
                log.warning("API attempt %d/%d: %s", attempt, retries, exc)
        else:
            log.warning("volume attempt %d/%d: %s not found yet", attempt, retries, secret_id)
        if attempt < retries:
            time.sleep(delay)
    raise RuntimeError(
        f"Could not retrieve '{secret_id}' after {retries} attempts. "
        "Check sidecar logs or CONJUR_APPLIANCE_URL."
    )
