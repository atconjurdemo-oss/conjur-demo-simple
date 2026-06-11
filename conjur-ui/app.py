"""
Conjur OSS UI — Python/Flask web interface for CyberArk Conjur OSS.
Shows policies, variables, resources, and live Conjur audit logs.
No MySQL dependency — logs are fetched via the Kubernetes API.
"""

import os
import base64
import logging
from functools import wraps
from pathlib import Path

import requests
from flask import (Flask, render_template, request, redirect,
                   url_for, session, flash, jsonify)
from werkzeug.middleware.dispatcher import DispatcherMiddleware
from werkzeug.wrappers import Response

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s — %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "dev-secret-change-in-prod")
_SUBPATH = os.environ.get("APPLICATION_ROOT", "/").rstrip("/")
app.config["APPLICATION_ROOT"]        = _SUBPATH or "/"
app.config["PREFERRED_URL_SCHEME"]    = os.environ.get("PREFERRED_URL_SCHEME", "http")
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_SECURE"]   = False
app.config["SESSION_COOKIE_PATH"]     = _SUBPATH or "/"

CONJUR_URL     = os.environ.get("CONJUR_APPLIANCE_URL", "https://conjur-oss.conjur.svc.cluster.local")
CONJUR_ACCOUNT = os.environ.get("CONJUR_ACCOUNT", "myConjurAccount")
VERIFY         = os.environ.get("CONJUR_SSL_VERIFY", "true").lower() != "false"
CONJUR_NS      = os.environ.get("CONJUR_NAMESPACE", "conjur")

# Kubernetes in-cluster config
_K8S_API    = "https://kubernetes.default.svc"
_K8S_TOKEN  = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
_K8S_CA     = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def _k8s_headers() -> dict:
    if _K8S_TOKEN.exists():
        return {"Authorization": f"Bearer {_K8S_TOKEN.read_text().strip()}"}
    return {}


def _get_conjur_logs(lines: int = 200) -> list:
    """Fetch logs from conjur-oss container via Kubernetes API."""
    try:
        # Get pod name
        pods_url = f"{_K8S_API}/api/v1/namespaces/{CONJUR_NS}/pods"
        r = requests.get(pods_url, headers=_k8s_headers(),
                        verify=_K8S_CA, timeout=5,
                        params={"labelSelector": "app=conjur-oss"})
        r.raise_for_status()
        pod_name = r.json()["items"][0]["metadata"]["name"]

        # Get logs
        logs_url = (f"{_K8S_API}/api/v1/namespaces/{CONJUR_NS}"
                    f"/pods/{pod_name}/log")
        r = requests.get(logs_url, headers=_k8s_headers(),
                        verify=_K8S_CA, timeout=10,
                        params={"container": "conjur-oss",
                                "tailLines": lines})
        r.raise_for_status()
        return r.text.splitlines()
    except Exception as e:
        log.warning("Could not fetch k8s logs: %s", e)
        raise


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
    if r.status_code == 401:
        session.clear()
        flash("Session expired — please log in again.", "warning")
        return True
    return False


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "token" not in session:
            flash("Please log in.", "warning")
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ── Auth ──────────────────────────────────────────────────────────────────────

@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


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
            flash("Logged in successfully.", "success")
            return redirect(url_for("dashboard"))
        except requests.HTTPError as e:
            flash(f"Authentication failed ({e.response.status_code}): {e.response.text}", "danger")
        except Exception as e:
            flash(f"Connection error: {e}", "danger")
    return render_template("login.html", conjur_url=CONJUR_URL, account=CONJUR_ACCOUNT)


@app.get("/logout")
def logout():
    session.clear()
    flash("Logged out.", "info")
    return redirect(url_for("login"))


@app.get("/refresh")
@login_required
def refresh():
    try:
        token = conjur_authenticate(session["username"], session["api_key"])
        session["token"] = token
        flash("Token refreshed.", "success")
    except Exception as e:
        flash(f"Refresh failed: {e}", "danger")
    return redirect(request.referrer or url_for("dashboard"))


# ── Dashboard ─────────────────────────────────────────────────────────────────

@app.get("/dashboard")
@app.get("/")
@login_required
def dashboard():
    health = server_info = authenticators = {}
    try:
        r = api_get("/health")
        health = r.json() if r.ok else {"error": f"HTTP {r.status_code}"}
    except Exception as e:
        health = {"error": str(e)}
    try:
        r = api_get("/info")
        if r.ok:
            server_info = r.json()
    except Exception:
        pass
    try:
        r = api_get(f"/{CONJUR_ACCOUNT}/authenticators")
        if r.ok:
            authenticators = r.json()
    except Exception:
        pass
    return render_template("dashboard.html",
                           health=health, server_info=server_info,
                           authenticators=authenticators,
                           conjur_url=CONJUR_URL, account=CONJUR_ACCOUNT,
                           username=session.get("username"),
                           audit_ready=True)


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
        flash(f"Could not load variables: HTTP {r.status_code}", "danger")
    return render_template("variables.html", variables=items,
                           account=CONJUR_ACCOUNT, username=session.get("username"))


@app.route("/variables/get", methods=["POST"])
@login_required
def variable_get():
    var_id  = request.form.get("variable_id", "").strip()
    value   = error = None
    encoded = requests.utils.quote(var_id, safe="")
    r = api_get(f"/secrets/{CONJUR_ACCOUNT}/variable/{encoded}")
    if r.ok:
        value = r.text
    else:
        error = f"HTTP {r.status_code}: {r.text}"
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
        flash(f"Variable '{var_id}' updated successfully.", "success")
    else:
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
        flash(f"Could not load policies: HTTP {r.status_code}", "danger")
    return render_template("policies.html", policies=items,
                           account=CONJUR_ACCOUNT, username=session.get("username"))


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
        flash(f"Policy loaded into '{branch}' successfully.", "success")
    else:
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
    return render_template("resources.html", resources=items,
                           kind=kind, account=CONJUR_ACCOUNT,
                           username=session.get("username"))


# ── Conjur Audit Logs ─────────────────────────────────────────────────────────

@app.get("/audit")
@login_required
def audit():
    """Fetch live Conjur pod logs filtered to security-relevant events."""
    lines     = int(request.args.get("lines", 200))
    filter_kw = request.args.get("filter", "")
    events    = []
    error     = None
    try:
        raw_lines = _get_conjur_logs(lines)
        skip = ["GET /health", "GET /", "200 OK", "StatusController",
                "Parameters:", "Processing by Status", "kube-probe"]
        keywords = ["authenticate", "policy", "CONJ000",
                    "Failed", "Unauthorized", "permission", "secret",
                    "403", "401", "successfully"]
        for line in raw_lines:
            # Always skip noisy health check lines
            if any(x in line for x in skip):
                continue
            if filter_kw:
                # User-defined filter — show any matching line
                if filter_kw.lower() in line.lower():
                    events.append(line)
            else:
                # Default — show security-relevant lines only
                if any(k.lower() in line.lower() for k in keywords):
                    events.append(line)
    except Exception as e:
        error = str(e)

    return render_template("audit.html",
                           events=events, lines=lines,
                           filter_kw=filter_kw, error=error,
                           audit_ready=True,
                           account=CONJUR_ACCOUNT,
                           username=session.get("username"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)

# Mount under APPLICATION_ROOT so gunicorn serves the full /ui/... paths.
# DispatcherMiddleware sets SCRIPT_NAME correctly for url_for() and
# leaves paths outside the prefix (e.g. /healthz probes) returning 404
# from a no-op default app — that's fine since probes are scoped to /healthz.
_not_found = Response("not found", status=404)
application = DispatcherMiddleware(_not_found, {_SUBPATH: app}) if _SUBPATH else app
