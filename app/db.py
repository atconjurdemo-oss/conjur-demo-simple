"""
db.py — MySQL connection pool.
Credentials are read from /conjur/secrets/secrets.env written by the
Conjur Secrets Provider sidecar at pod startup.
"""

import logging
import os
import time
from pathlib import Path
from typing import Optional

from mysql.connector import pooling

log = logging.getLogger(__name__)

# Sidecar writes secrets here in dotenv format
_SECRETS_FILE = Path(os.getenv("CONJUR_SECRETS_VOLUME", "/conjur/secrets")) / "secrets.env"

_pool: Optional[pooling.MySQLConnectionPool] = None


def _read_secrets(retries: int = 12, delay: float = 10.0) -> dict:
    """Read secrets.env written by the Conjur Secrets Provider sidecar."""
    for attempt in range(1, retries + 1):
        if _SECRETS_FILE.exists():
            result = {}
            for line in _SECRETS_FILE.read_text().splitlines():
                line = line.strip()
                if line and "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    result[k.strip()] = v.strip().strip('"').strip("'")
            if result:
                return result
        log.warning("secrets not ready yet (%d/%d)", attempt, retries)
        if attempt < retries:
            time.sleep(delay)
    raise RuntimeError("Secrets file not found. Check the Conjur Secrets Provider sidecar logs.")


def _build_pool() -> pooling.MySQLConnectionPool:
    log.info("Reading DB credentials from Conjur sidecar volume...")
    s = _read_secrets()
    return pooling.MySQLConnectionPool(
        pool_name="webapp",
        pool_size=5,
        host=s["myapp_database_host"],
        port=int(s["myapp_database_port"]),
        user=s["myapp_database_user"],
        password=s["myapp_database_password"],
        database=s["myapp_database_name"],
    )


def get_connection():
    global _pool
    if _pool is None:
        _pool = _build_pool()
    return _pool.get_connection()


def init_schema() -> None:
    ddl = """
    CREATE TABLE IF NOT EXISTS incidents (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        title      VARCHAR(255) NOT NULL,
        severity   ENUM('critical','high','medium','low') NOT NULL DEFAULT 'medium',
        status     ENUM('open','investigating','resolved') NOT NULL DEFAULT 'open',
        notes      TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(ddl)
        conn.commit()
        log.info("schema initialised")
    finally:
        conn.close()
