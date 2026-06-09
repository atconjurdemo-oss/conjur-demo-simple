# Conjur OSS Demo — Secure 2-Tier App on GKE

Demonstrates **zero hardcoded credentials** using CyberArk Conjur OSS.

## Architecture

```
Internet → NGINX Ingress → Flask App (Incident Tracker)
                                ↓ JWT auth
                           Conjur OSS ← fetches DB password
                                ↓
                            MySQL 8
```

**The secret flow:**
1. Pod starts → Conjur Secrets Provider init container runs
2. Init container presents pod's Kubernetes JWT to Conjur
3. Conjur validates JWT against GKE OIDC, returns secrets
4. Secrets written to in-memory volume → Flask app connects to MySQL
5. No passwords ever in manifests, env vars, or code

## Deploy in 5 steps

```bash
# Prerequisites: kubectl, helm, conjur CLI pointed at a GKE cluster

# 1. Install Conjur OSS
bash scripts/01-install-conjur.sh

# 2. Initialize account (one-time)
bash scripts/02-init-account.sh

# 3. Load policies and seed secrets
bash scripts/03-seed.sh

# 4. Deploy the app
bash scripts/04-deploy-app.sh

# 5. Verify
bash scripts/05-verify.sh
```

## What Conjur protects

| Secret | Stored in | Who can read |
|---|---|---|
| MySQL app password | Conjur | Only webapp pod via JWT |
| MySQL root password | Conjur | Admin only |
| DB host/port/user/name | Conjur | Only webapp pod via JWT |

## Tech stack

- **GKE** — Kubernetes cluster
- **Conjur OSS** — secrets management (JWT authenticator)
- **Secrets Provider for K8s** — sidecar that fetches secrets
- **Flask** — Python web app (Incident Tracker)
- **MySQL 8** — backend database
- **NGINX Ingress** — external access
- **cert-manager** — automatic TLS via Let's Encrypt
