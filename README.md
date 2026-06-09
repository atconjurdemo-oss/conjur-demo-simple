# Conjur OSS Demo — Secure 2-Tier App on GKE

Zero hardcoded credentials using CyberArk Conjur OSS.

## Prerequisites

```bash
# Tools needed
kubectl    # pointed at your GKE cluster
helm       # v3
docker     # for building the image
conjur     # CLI: https://github.com/cyberark/conjur-cli-go/releases
```

## Deploy in 5 steps

```bash
export PROJECT_ID=<your-gcp-project>
export REGION=europe-west1
export CLUSTER_NAME=conjur-demo

# 1. Install Conjur OSS + NGINX
bash scripts/01-install-conjur.sh

# 2. Initialize Conjur account (one-time)
bash scripts/02-init-account.sh

# 3. Load policies and write secrets
export DB_APP_PASSWORD=MySecurePass123
bash scripts/03-seed.sh

# 4. Build and deploy the app
bash scripts/04-deploy-app.sh

# 5. Open the app
kubectl -n securetask port-forward svc/webapp 8080:80
# Browser: http://localhost:8080/app
```

## How it works

```
Pod starts
  └── Secrets Provider init container
        ├── Reads pod JWT from /var/run/secrets/kubernetes.io/serviceaccount/token
        ├── POSTs JWT to Conjur /authn-jwt/k8s-cluster/...
        ├── Conjur validates JWT against GKE OIDC
        ├── Returns DB credentials
        └── Writes /conjur/secrets/secrets.env
  └── Flask app starts
        └── Reads secrets.env → connects to MySQL
```

**No passwords in manifests, env vars, or source code.**

## Architecture

```
localhost:8080 → NGINX → Flask (Incident Tracker)
                              ↓ JWT auth at startup
                         Conjur OSS
                              ↓
                          MySQL 8
```

## Conjur policy summary

| Resource | Path | Who can read |
|---|---|---|
| DB password | `myapp/database/password` | webapp pod only |
| DB root password | `myapp/database/root-password` | webapp pod only |
| DB host/port/user/name | `myapp/database/*` | webapp pod only |
