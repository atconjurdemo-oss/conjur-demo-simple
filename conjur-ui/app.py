"""
Conjur OSS UI — Python/Flask web interface for CyberArk Conjur OSS.
All user actions are recorded to MySQL via audit_db.py.
Credentials are fetched from Conjur — never hardcoded.
"""

import os
import base64
import logging
from functools import wraps

import requests
from flask import (Flask, render_template, request, redirect,
                   url_for, session, flash, jsonify)

import audit_db

logging.basicConfig(level=logging.DEBUG,
                    format="%(asctime)s %(levelname)s %(name)s — %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "dev-secret-change-in-prod")

# When served under a sub-path (e.g. /ui), set APPLICATION_ROOT so url_for
# generates correct paths. Defaults to / for local development.
app.config["APPLICATION_ROOT"] = os.environ.get("APPLICATION_ROOT", "/")
app.config["PREFERRED_URL_SCHEME"] = "https"

CONJUR_URL     = os.environ.get("CONJUR_APPLIANCE_URL", "https://conjur.conjur.duckdns.org")
CONJUR_ACCOUNT = os.environ.get("CONJUR_ACCOUNT", "myConjurAccount")
VERIFY         = os.environ.get("CONJUR_SSL_VERIFY", "true").lower() != "false"

# Initialise the audit DB pool immediately at startup using the pod JWT.
# This is a no-op (logs a warning) if running outside the cluster.
import threading

# Initialise the audit DB pool in a background thread — never blocks the UI.
threading.Thread(target=audit_db.init_pool, daemon=True).start()


@app.before_request
def ensure_audit_db():
    """Retry DB init in background if previous attempt failed."""
    if not audit_db.is_ready():
        threading.Thread(target=audit_db.init_pool, daemon=True).start()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _session() -> requests.Session:
    s = requests.Session()
    s.verify = VERIFY
    return s


def _token() -> str:
    return session.get("token", "")


def _headers(token: str) -> dict:
    encoded = base64.b64encode(token.encode()).decode()
    return {"Authorization": f'Token token="{encoded}"'}


def _ip() -> str:
    return request.headers.get("X-Forwarded-For", request.remote_addr or "")


def conjur_authenticate(username: str, api_key: str) -> str:
    login = requests.utils.quote(username, safe="")
    url   = f"{CONJUR_URL}/authn/{CONJUR_ACCOUNT}/{login}/authenticate"
    resp  = _session().post(url, data=api_key,
                            headers={"Content-Type": "text/plain"})
    resp.raise_for_status()
    return resp.text


def api_get(path: str) -> requests.Response:
    return _session().get(f"{CONJUR_URL}{path}", headers=_headers(_token()))


def api_put(path: str, data: bytes, content_type="application/x-yaml") -> requests.Response:
    return _session().put(f"{CONJUR_URL}{path}", data=data,
                          headers={**_headers(_token()), "Content-Type": content_type})


def api_patch(path: str, data: bytes, content_type="application/x-yaml") -> requests.Response:
    return _session().patch(f"{CONJUR_URL}{path}", data=data,
                            headers={**_headers(_token()), "Content-Type": content_type})


def api_post(path: str, data, content_type="text/plain") -> requests.Response:
    return _session().post(f"{CONJUR_URL}{path}", data=data,
                           headers={**_headers(_token()), "Content-Type": content_type})


def _handle_expired(r: requests.Response) -> bool:
    """If 401, clear session and redirect. Returns True if caller should abort."""
    if r.status_code == 401:
        audit_db.record(session.get("username", "?"), "session_expired",
                        client_ip=_ip(), result="fail")
        session.clear()
        flash("Session expired — please log in again.", "warning")
        return True
    return False


# ── Auth decorator ────────────────────────────────────────────────────────────

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "token" not in session:
            flash("Please log in.", "warning")
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/healthz")
def healthz():
    return jsonify(status="ok", audit_db=audit_db.is_ready())


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "admin").strip()
        api_key  = request.form.get("api_key", "").strip()
        try:
            token = conjur_authenticate(username, api_key)
            session.clear()
            session["token"]    = token
            session["username"] = username
            session["api_key"]  = api_key

            audit_db.record(username, "login", result="success", client_ip=_ip())
            flash("Logged in successfully.", "success")
            return redirect(url_for("dashboard"))
        except requests.HTTPError as e:
            audit_db.record(username, "login", result="fail",
                            detail=str(e.response.status_code), client_ip=_ip())
            flash(f"Authentication failed ({e.response.status_code}): {e.response.text}",
                  "danger")
        except Exception as e:
            flash(f"Connection error: {e}", "danger")
    return render_template("login.html", conjur_url=CONJUR_URL, account=CONJUR_ACCOUNT)


@app.get("/logout")
def logout():
    audit_db.record(session.get("username", "?"), "logout", client_ip=_ip())
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("login"))


@app.get("/refresh")
@login_required
def refresh():
    try:
        token = conjur_authenticate(session["username"], session["api_key"])
        session["token"] = token
        audit_db.record(session["username"], "token_refresh",
                        result="success", client_ip=_ip())
        flash("Token refreshed.", "success")
    except Exception as e:
        audit_db.record(session.get("username", "?"), "token_refresh",
                        result="fail", detail=str(e), client_ip=_ip())
        flash(f"Refresh failed: {e}", "danger")
    return redirect(request.referrer or url_for("dashboard"))


# ── Dashboard ─────────────────────────────────────────────────────────────────

@app.get("/")
@login_required
def dashboard():
    health = {}
    server_info = {}
    authenticators = {}

    try:
        r = api_get("/health")
        health = r.json() if r.ok else {"error": f"HTTP {r.status_code}: {r.text}"}
    except Exception as e:
        health = {"error": str(e)}

    try:
        r = api_get("/info")
        if r.ok:
            server_info = r.json()
    except Exception as e:
        log.warning("/info error: %s", e)

    try:
        r = api_get(f"/{CONJUR_ACCOUNT}/authenticators")
        if r.ok:
            authenticators = r.json()
    except Exception as e:
        log.warning("/authenticators error: %s", e)

    audit_db.record(session["username"], "view_dashboard", client_ip=_ip())
    return render_template("dashboard.html",
                           health=health,
                           server_info=server_info,
                           authenticators=authenticators,
                           conjur_url=CONJUR_URL,
                           account=CONJUR_ACCOUNT,
                           username=session.get("username"),
                           audit_ready=audit_db.is_ready())


# ── Variables ─────────────────────────────────────────────────────────────────

@app.get("/variables")
@login_required
def variables():
    items = []
    r = api_get(f"/resources/{CONJUR_ACCOUNT}/variable?limit=200")
    if _handle_expired(r):
        return redirect(url_for("login"))
    if r.ok:
        items = r.json()
    else:
        flash(f"Could not load variables: HTTP {r.status_code} — {r.text}", "danger")
    audit_db.record(session["username"], "list_variables",
                    detail=f"count={len(items)}", client_ip=_ip())
    return render_template("variables.html", variables=items,
                           account=CONJUR_ACCOUNT,
                           username=session.get("username"))


@app.route("/variables/get", methods=["POST"])
@login_required
def variable_get():
    var_id  = request.form.get("variable_id", "").strip()
    value   = error = None
    encoded = requests.utils.quote(var_id, safe="")
    r = api_get(f"/secrets/{CONJUR_ACCOUNT}/variable/{encoded}")
    if r.ok:
        value = r.text
        audit_db.record(session["username"], "get_variable",
                        resource=var_id, result="success", client_ip=_ip())
    else:
        error = f"HTTP {r.status_code}: {r.text}"
        audit_db.record(session["username"], "get_variable",
                        resource=var_id, result="fail",
                        detail=error, client_ip=_ip())
    return render_template("variable_value.html",
                           var_id=var_id, value=value, error=error,
                           username=session.get("username"))


@app.route("/variables/set", methods=["POST"])
@login_required
def variable_set():
    var_id  = request.form.get("variable_id", "").strip()
    value   = request.form.get("value", "")
    encoded = requests.utils.quote(var_id, safe="")
    r = api_post(f"/secrets/{CONJUR_ACCOUNT}/variable/{encoded}", data=value)
    if _handle_expired(r):
        return redirect(url_for("login"))
    if r.ok:
        audit_db.record(session["username"], "set_variable",
                        resource=var_id, result="success", client_ip=_ip())
        flash(f"Variable '{var_id}' updated successfully.", "success")
    else:
        audit_db.record(session["username"], "set_variable",
                        resource=var_id, result="fail",
                        detail=f"HTTP {r.status_code}: {r.text}", client_ip=_ip())
        flash(f"Set variable failed: HTTP {r.status_code} — {r.text}", "danger")
    return redirect(url_for("variables"))


# ── Policies ──────────────────────────────────────────────────────────────────

@app.get("/policies")
@login_required
def policies():
    items = []
    r = api_get(f"/resources/{CONJUR_ACCOUNT}/policy?limit=200")
    if _handle_expired(r):
        return redirect(url_for("login"))
    if r.ok:
        items = r.json()
    else:
        flash(f"Could not load policies: HTTP {r.status_code} — {r.text}", "danger")
    audit_db.record(session["username"], "list_policies",
                    detail=f"count={len(items)}", client_ip=_ip())
    return render_template("policies.html", policies=items,
                           account=CONJUR_ACCOUNT,
                           username=session.get("username"))


@app.route("/policies/load", methods=["POST"])
@login_required
def policy_load():
    branch      = request.form.get("branch", "root").strip()
    policy_yaml = request.form.get("policy_yaml", "").strip()
    method      = request.form.get("method", "put")

    if not policy_yaml:
        flash("Policy YAML is empty.", "warning")
        return redirect(url_for("policies"))

    encoded = requests.utils.quote(branch, safe="")
    path    = f"/policies/{CONJUR_ACCOUNT}/policy/{encoded}"
    data    = policy_yaml.encode()

    if method == "patch":
        r = api_patch(path, data)
    elif method == "post":
        r = api_post(path, data, content_type="application/x-yaml")
    else:
        r = api_put(path, data)

    if _handle_expired(r):
        return redirect(url_for("login"))

    if r.ok:
        audit_db.record(session["username"], "load_policy",
                        resource=branch, detail=f"method={method}",
                        result="success", client_ip=_ip())
        flash(f"Policy loaded into '{branch}' successfully.", "success")
    else:
        audit_db.record(session["username"], "load_policy",
                        resource=branch,
                        detail=f"method={method} HTTP {r.status_code}: {r.text[:300]}",
                        result="fail", client_ip=_ip())
        flash(f"Policy load failed: HTTP {r.status_code} — {r.text}", "danger")

    return redirect(url_for("policies"))


# ── Resources ─────────────────────────────────────────────────────────────────

@app.get("/resources")
@login_required
def resources():
    kind  = request.args.get("kind", "")
    items = []
    path  = f"/resources/{CONJUR_ACCOUNT}"
    if kind:
        path += f"/{kind}"
    path += "?limit=200"
    r = api_get(path)
    if _handle_expired(r):
        return redirect(url_for("login"))
    if r.ok:
        items = r.json()
    else:
        flash(f"HTTP {r.status_code}: {r.text}", "danger")
    audit_db.record(session["username"], "list_resources",
                    detail=f"kind={kind or 'all'} count={len(items)}",
                    client_ip=_ip())
    return render_template("resources.html", resources=items,
                           kind=kind, account=CONJUR_ACCOUNT,
                           username=session.get("username"))


# ── Audit log ─────────────────────────────────────────────────────────────────

@app.get("/audit")
@login_required
def audit():
    limit  = min(int(request.args.get("limit", 100)), 500)
    events = audit_db.get_recent(limit)
    audit_db.record(session["username"], "view_audit",
                    detail=f"limit={limit}", client_ip=_ip())
    return render_template("audit.html", events=events,
                           limit=limit, audit_ready=audit_db.is_ready(),
                           account=CONJUR_ACCOUNT,
                           username=session.get("username"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
