# CyberArk Technical Challenge — Conjur OSS on GKE

Demonstrates **zero hardcoded credentials** using CyberArk Conjur OSS.
Database passwords never appear in manifests, environment variables, or source code —
they are fetched at pod startup via Kubernetes JWT authentication against Conjur.

---

## Live Services

| Service | URL |
|---|---|
| Landing Page | `http://<NGINX-IP>/` |
| Incident Tracker | `http://<NGINX-IP>/app` |
| Conjur Admin UI | `http://<NGINX-IP>/ui` |
| Architecture Presentation | `http://<NGINX-IP>/presentation/` |

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## Architecture

```
Internet
  └── NGINX Ingress (single external IP)
        ├── /              → Landing page (nginx static)
        ├── /app           → Incident Tracker (Flask + MySQL)
        ├── /ui            → Conjur Admin UI (Flask)
        └── /presentation/ → Architecture slides (nginx static)

securetask namespace               conjur namespace
┌──────────────────────┐          ┌──────────────────────────┐
│ webapp pod           │          │ Conjur OSS + PostgreSQL   │
│  ├── init: sidecar ──│──JWT────▶│                          │
│  └── Flask app       │          │ conjur-ui pod             │
│                      │          │  ├── init: sidecar ───JWT▶│
│ mysql pod            │          │  └── Flask Admin UI       │
│  └── MySQL 8         │          └──────────────────────────┘
└──────────────────────┘
```

### Secret delivery (Push-to-File sidecar)

```
1. Pod starts
2. Secrets Provider init container:
   ├── Reads pod SA JWT from /var/run/secrets/kubernetes.io/serviceaccount/token
   ├── POSTs JWT to Conjur /authn-jwt/k8s-cluster/...
   ├── Conjur validates JWT against GKE OIDC issuer
   ├── Returns DB credentials
   └── Writes /conjur/secrets/secrets.env (in-memory shared volume)
3. Flask app starts → reads secrets.env → connects to MySQL
```

No Kubernetes Secrets are used for database credentials.

---

## Repository Layout

```
conjur-demo-simple/
├── app/                        Incident Tracker (Flask + MySQL)
├── conjur-ui/                  Conjur Admin UI (Flask)
├── landing/                    Landing page (static HTML)
├── presentation/               Architecture slides (static HTML)
├── conjur-policy/
│   ├── root.yml                Top-level policy branches
│   ├── database.yml            Secrets + host identities + permits
│   └── authn-jwt.yml           JWT authenticator webservice
├── k8s/
│   ├── 00-namespace.yaml
│   ├── conjur-ui/              serviceaccount, configmap, deployment
│   ├── mysql/                  statefulset
│   ├── webapp/                 serviceaccount, configmap, deployment
│   └── gateway/                ingress-conjur, ingress-securetask, presentation
├── .zap/
│   ├── rules.tsv               DAST false-positive suppressions
│   └── xml_to_sarif.py         ZAP XML → SARIF converter
└── .github/workflows/
    ├── ci.yml                  Lint · SAST · OCV on pull requests
    ├── cd.yml                  Build · Scan · SBOM · Push · Deploy · DAST
    ├── conjur-install.yml      Install NGINX Ingress + Conjur OSS (manual)
    └── conjur-seed.yml         Load policies + write secrets (manual)
```

---

## Pipelines

### First-time cluster setup (manual triggers)

**1. Conjur Installation** (`conjur-install.yml`)

Installs NGINX Ingress Controller and Conjur OSS via Helm.
Initializes the Conjur account and stores the admin API key as a cluster Secret.

**2. Conjur Seed** (`conjur-seed.yml`)

Loads the three policy files and writes all database secrets to Conjur.
Run once after installation; safe to re-run (idempotent).

### Continuous Delivery (`cd.yml`)

Triggered automatically on every push to `main` that touches `app/`, `conjur-ui/`, `landing/`, or `k8s/`.

```
Build webapp
  └── Trivy scan (HIGH/CRITICAL, exit 1)
  └── Push to GHCR
  └── SBOM → sbom-webapp-<sha>.spdx.json (artifact)

Build conjur-ui
  └── Trivy scan (HIGH/CRITICAL, exit 1)
  └── Push to GHCR
  └── SBOM → sbom-conjur-ui-<sha>.spdx.json (artifact)

Deploy (production environment gate)
  └── Apply k8s manifests
  └── Smoke test (/healthz)
  └── DAST — OWASP ZAP baseline scan → SARIF uploaded to GitHub Security
```

### CI (`ci.yml`)

Runs on pull requests:
- **Semgrep** SAST — Python security rules
- **pip-audit** OCV (Open-source Component Verification)
- **Lint** — flake8

---

## Credentials

### Conjur Admin UI login

- **Username:** `admin`
- **API Key:**
```bash
kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d
```

---

## Conjur Policy Summary

| Variable | Path | Who can read |
|---|---|---|
| DB host / port / user / name | `myapp/database/*` | `webapp` + `conjur-ui` |
| DB app password | `myapp/database/password` | `webapp` + `conjur-ui` |
| DB root password | `myapp/database/root-password` | `webapp` only |
| JWT issuer / JWKS / audience | `conjur/authn-jwt/k8s-cluster/*` | Conjur internal |

Identities:
- `host/myapp/webapp` — SA `webapp` in namespace `securetask`
- `host/myapp/conjur-ui` — SA `conjur-ui` in namespace `conjur`

---

## Kubernetes Secrets

| Secret | Namespace | Purpose | Sensitivity |
|---|---|---|---|
| `conjur-data-key` | conjur | Conjur database encryption key | High |
| `conjur-admin-api-key` | conjur | Conjur admin API key | High |
| `conjur-ssl-cert` | securetask | Conjur TLS cert for sidecar | Low |
| `flask-secret` | securetask | Webapp CSRF signing key | Medium |
| `conjur-ui-secret` | conjur | Conjur UI session signing key | Medium |

**No MySQL passwords are stored in Kubernetes Secrets.**
Both are fetched from Conjur at pod startup via the Secrets Provider sidecar.

---

## Security Controls

| Control | Implementation |
|---|---|
| Secret management | CyberArk Conjur OSS |
| Authentication | Kubernetes JWT (pod identity = credential) |
| Secret delivery | Secrets Provider sidecar — Push-to-File |
| Container scanning | Trivy (HIGH/CRITICAL, blocks push) |
| SAST | Semgrep (Python security rules) |
| OCV | pip-audit (dependency CVE check) |
| DAST | OWASP ZAP baseline scan |
| SBOM | Syft via anchore/sbom-action (SPDX JSON) |
| CSRF | Flask-WTF on all state-changing routes |
