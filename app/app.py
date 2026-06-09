"""
app.py — Incident Tracker demonstrating Conjur secrets management.
DB credentials are fetched from Conjur at runtime — never hardcoded.
"""

import json
import logging
import os
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, render_template, request
from flask_wtf.csrf import CSRFProtect
from prometheus_flask_exporter import PrometheusMetrics

import db


class _JsonFormatter(logging.Formatter):
    """Structured JSON logs for GKE / Cloud Logging."""
    def format(self, record):
        return json.dumps({
            "severity": record.levelname,
            "message":  record.getMessage(),
            "logger":   record.name,
        })


_handler = logging.StreamHandler()
_handler.setFormatter(_JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler])
log = logging.getLogger(__name__)

app = Flask(__name__)
app.config["SECRET_KEY"]          = os.environ.get("FLASK_SECRET_KEY", os.urandom(32))
app.config["WTF_CSRF_TIME_LIMIT"] = 3600

csrf    = CSRFProtect(app)
metrics = PrometheusMetrics(app, default_labels={"app": "incident-tracker"})

VALID_SEVERITIES = {"critical", "high", "medium", "low"}
MAX_TITLE_LEN    = 255
MAX_NOTES_LEN    = 2000


def _try_init_db():
    try:
        db.init_schema()
        return True
    except Exception as exc:
        log.warning("DB not ready yet: %s", exc)
        return False


def _audit(action: str, resource: str = "", detail: str = "", result: str = "success"):
    """Write an audit event to conjur_audit_log — same table as the Conjur UI."""
    try:
        conn = db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS conjur_audit_log (
                    id          INT AUTO_INCREMENT PRIMARY KEY,
                    ts          DATETIME(3)  NOT NULL,
                    username    VARCHAR(128) NOT NULL,
                    action      VARCHAR(64)  NOT NULL,
                    resource    VARCHAR(512),
                    detail      TEXT,
                    result      VARCHAR(16)  NOT NULL DEFAULT 'success',
                    client_ip   VARCHAR(64)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """)
            cur.execute("""
                INSERT INTO conjur_audit_log
                  (ts, username, action, resource, detail, result, client_ip)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (
                datetime.now(timezone.utc),
                "webapp",
                action,
                resource[:512] if resource else "",
                detail[:2000] if detail else "",
                result,
                request.remote_addr or "",
            ))
            conn.commit()
        finally:
            conn.close()
    except Exception as exc:
        log.debug("audit write skipped: %s", exc)


@app.get("/healthz")
@csrf.exempt
def healthz():
    return jsonify(status="ok"), 200


@app.get("/")
def index():
    _try_init_db()
    conn = db.get_connection()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("""
            SELECT id, title, severity, status, notes, created_at
            FROM incidents
            ORDER BY
                FIELD(severity, 'critical','high','medium','low'),
                created_at DESC
        """)
        incidents = cur.fetchall()
    finally:
        conn.close()
    return render_template("index.html", incidents=incidents)


@app.post("/incidents")
def add_incident():
    title    = request.form.get("title", "").strip()[:MAX_TITLE_LEN]
    severity = request.form.get("severity", "medium").lower()
    notes    = request.form.get("notes", "").strip()[:MAX_NOTES_LEN]

    if severity not in VALID_SEVERITIES:
        abort(400, "Invalid severity value.")

    if title:
        conn = db.get_connection()
        try:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO incidents (title, severity, notes) VALUES (%s, %s, %s)",
                (title, severity, notes),
            )
            conn.commit()
            log.info("incident created: title=%s severity=%s", title, severity)
            _audit("create_incident", resource=title,
                   detail=f"severity={severity}")
        finally:
            conn.close()
    return ("", 303, {"Location": "/app/"})


@app.post("/incidents/<int:incident_id>/advance")
def advance_status(incident_id: int):
    transitions = {"open": "investigating", "investigating": "resolved", "resolved": "open"}
    conn = db.get_connection()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT status, title FROM incidents WHERE id = %s", (incident_id,))
        row = cur.fetchone()
        if not row:
            abort(404)
        new_status = transitions.get(row["status"], "open")
        cur.execute("UPDATE incidents SET status = %s WHERE id = %s", (new_status, incident_id))
        conn.commit()
        log.info("incident %d advanced to %s", incident_id, new_status)
        _audit("advance_incident", resource=row["title"],
               detail=f"id={incident_id} {row['status']} -> {new_status}")
    finally:
        conn.close()
    return ("", 303, {"Location": "/app/"})


@app.post("/incidents/<int:incident_id>/delete")
def delete_incident(incident_id: int):
    conn = db.get_connection()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT title FROM incidents WHERE id = %s", (incident_id,))
        row = cur.fetchone()
        cur.execute("DELETE FROM incidents WHERE id = %s", (incident_id,))
        conn.commit()
        title = row["title"] if row else str(incident_id)
        log.info("incident %d deleted", incident_id)
        _audit("delete_incident", resource=title, detail=f"id={incident_id}")
    finally:
        conn.close()
    return ("", 303, {"Location": "/app/"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
