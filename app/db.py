"""
db.py — MySQL connection pool.
Credentials fetched from Conjur at startup — never hardcoded.
"""

import os
import logging
from typing import Optional

from mysql.connector import pooling

from conjur_client import get_secret

log = logging.getLogger(__name__)

_SECRETS = {
    "host":     os.getenv("DB_HOST_SECRET",     "myapp/database/host"),
    "port":     os.getenv("DB_PORT_SECRET",     "myapp/database/port"),
    "user":     os.getenv("DB_USER_SECRET",     "myapp/database/user"),
    "password": os.getenv("DB_PASSWORD_SECRET", "myapp/database/password"),
    "name":     os.getenv("DB_NAME_SECRET",     "myapp/database/name"),
}

_pool: Optional[pooling.MySQLConnectionPool] = None


def _build_pool() -> pooling.MySQLConnectionPool:
    log.info("fetching DB credentials from Conjur…")
    cfg = {k: get_secret(v) for k, v in _SECRETS.items()}
    return pooling.MySQLConnectionPool(
        pool_name="webapp",
        pool_size=5,
        host=cfg["host"],
        port=int(cfg["port"]),
        user=cfg["user"],
        password=cfg["password"],
        database=cfg["name"],
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
