"""
audit_db.py — MySQL audit logger for Conjur UI.

Authentication flow (Kubernetes JWT authenticator):
  1. Read the pod's service-account JWT from the mounted token file.
  2. POST it to Conjur's authn-jwt endpoint (internal ClusterIP — no external URL).
  3. Conjur validates the JWT against the GKE OIDC issuer, checks the host
     identity (myapp/conjur-ui) and its permissions, returns a short-lived token.
  4. Use that token to fetch the 5 database variables from Conjur.
  5. Open a MySQL connection pool and create the audit table.

No admin API key or external URL is used — the pod's identity is its credential.
"""

import os
import base64
import logging
import threading
from datetime import datetime, timezone
from pathlib import Path

import requests
import mysql.connector
from mysql.connector import pooling

log = logging.getLogger(__name__)

# Internal Conjur ClusterIP service — never leaves the cluster.
CONJUR_INTERNAL_URL = os.environ.get(
    "CONJUR_INTERNAL_URL", "https://conjur-oss.conjur.svc.cluster.local"
)
CONJUR_ACCOUNT = os.environ.get("CONJUR_ACCOUNT", "myConjurAccount")
CONJUR_AUTHN_JWT_SERVICE = os.environ.get(
    "CONJUR_AUTHN_JWT_SERVICE", "k8s-cluster"
)
# Service-account token mounted by Kubernetes into every pod.
SA_TOKEN_PATH = Path(
    os.environ.get("SA_TOKEN_PATH",
                   "/var/run/secrets/kubernetes.io/serviceaccount/token")
)
# The conjur-ui host identity declared in the Conjur policy.
CONJUR_HOST_ID = os.environ.get("CONJUR_HOST_ID", "host/myapp/conjur-ui")

# Internal Conjur uses its own TLS cert — set to False to skip verification
# (acceptable for in-cluster traffic on a private network).
CONJUR_VERIFY = os.environ.get("CONJUR_INTERNAL_VERIFY", "false").lower() != "false"

_pool: pooling.MySQLConnectionPool | None = None
_lock = threading.Lock()


# ── JWT authentication ────────────────────────────────────────────────────────

def _jwt_authenticate() -> str:
    """
    Authenticate to Conjur using the pod's Kubernetes service-account JWT.
    Returns a short-lived Conjur access token (raw string).
    """
    if not SA_TOKEN_PATH.exists():
        raise RuntimeError(f"SA token not found at {SA_TOKEN_PATH}. "
                           "Is automountServiceAccountToken enabled?")

    jwt = SA_TOKEN_PATH.read_text().strip()
    # Include the host login in the URL for URL-based identity
    host_encoded = requests.utils.quote(CONJUR_HOST_ID, safe="")
    url = (f"{CONJUR_INTERNAL_URL}/authn-jwt/{CONJUR_AUTHN_JWT_SERVICE}"
           f"/{CONJUR_ACCOUNT}/{host_encoded}/authenticate")

    log.debug("JWT authn → %s", url)
    resp = requests.post(
        url,
        data={"jwt": jwt},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        verify=CONJUR_VERIFY,
        timeout=3,
    )
    log.debug("JWT authn response: %s — %s", resp.status_code, resp.text[:500])
    resp.raise_for_status()
    log.info("Conjur JWT authentication succeeded (host: %s)", CONJUR_HOST_ID)
    return resp.text


def _fetch_secret(token: str, variable_id: str) -> str:
    """Retrieve a single Conjur variable using a valid access token."""
    encoded_tok = base64.b64encode(token.encode()).decode()
    encoded_id  = requests.utils.quote(variable_id, safe="")
    url = f"{CONJUR_INTERNAL_URL}/secrets/{CONJUR_ACCOUNT}/variable/{encoded_id}"

    resp = requests.get(
        url,
        headers={"Authorization": f'Token token="{encoded_tok}"'},
        verify=CONJUR_VERIFY,
        timeout=5,
    )
    resp.raise_for_status()
    return resp.text.strip()


# ── Pool bootstrap ────────────────────────────────────────────────────────────

def init_pool() -> None:
    """
    Called at pod startup. Authenticates via JWT, fetches DB credentials
    from Conjur, and opens the MySQL connection pool.
    No admin key, no external URL, no hardcoded credentials.
    """
    global _pool
    with _lock:
        if _pool is not None:
            return
        try:
            token    = _jwt_authenticate()
            host     = os.environ.get("DB_HOST_OVERRIDE") or \
                       _fetch_secret(token, "myapp/database/host")
            port     = int(_fetch_secret(token, "myapp/database/port"))
            user     = _fetch_secret(token, "myapp/database/user")
            password = _fetch_secret(token, "myapp/database/password")
            database = _fetch_secret(token, "myapp/database/name")

            _pool = pooling.MySQLConnectionPool(
                pool_name="conjur_ui_audit",
                pool_size=3,
                host=host,
                port=port,
                user=user,
                password=password,
                database=database,
                connection_timeout=5,
            )
            _create_table()
            log.info("Audit DB pool ready → %s:%s/%s (via Conjur JWT authn)",
                     host, port, database)
        except Exception as e:
            log.warning("Audit DB unavailable — will retry on next request: %s", e)
            _pool = None


def _create_table() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS conjur_audit_log (
        id          INT AUTO_INCREMENT PRIMARY KEY,
        ts          DATETIME(3)  NOT NULL,
        username    VARCHAR(128) NOT NULL,
        action      VARCHAR(64)  NOT NULL,
        resource    VARCHAR(512),
        detail      TEXT,
        result      VARCHAR(16)  NOT NULL DEFAULT 'success',
        client_ip   VARCHAR(64)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """
    conn = _pool.get_connection()
    try:
        cur = conn.cursor()
        cur.execute(ddl)
        conn.commit()
    finally:
        conn.close()


# ── Public API ────────────────────────────────────────────────────────────────

def record(username: str, action: str, resource: str = "",
           detail: str = "", result: str = "success",
           client_ip: str = "") -> None:
    """Write one audit event. Silently drops if DB pool is not ready."""
    if _pool is None:
        log.debug("AUDIT(no-db) %s %s %s %s", username, action, resource, result)
        return
    try:
        conn = _pool.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                """INSERT INTO conjur_audit_log
                   (ts, username, action, resource, detail, result, client_ip)
                   VALUES (%s,%s,%s,%s,%s,%s,%s)""",
                (datetime.now(timezone.utc), username, action,
                 resource[:512], detail[:2000], result, client_ip),
            )
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        log.warning("Audit write failed: %s", e)


def get_recent(limit: int = 200) -> list[dict]:
    """Return the most recent audit rows as a list of dicts."""
    if _pool is None:
        return []
    try:
        conn = _pool.get_connection()
        try:
            cur = conn.cursor(dictionary=True)
            cur.execute(
                """SELECT id, ts, username, action, resource,
                          detail, result, client_ip
                   FROM conjur_audit_log
                   ORDER BY id DESC LIMIT %s""",
                (limit,),
            )
            return cur.fetchall()
        finally:
            conn.close()
    except Exception as e:
        log.warning("Audit read failed: %s", e)
        return []


def is_ready() -> bool:
    return _pool is not None
