# Conjur OSS Demo — Secure 2-Tier App on GKE

Demonstrates **zero hardcoded credentials** using CyberArk Conjur OSS.
The database password never appears in manifests, environment variables, or source code —
it is fetched at pod startup via JWT authentication against Conjur.

---

## Architecture

```
Internet → NGINX Ingress → Flask App (Incident Tracker)  http://<IP>/app
                                  ↓ JWT auth at startup
                             Conjur OSS (cluster-internal)
                                  ↓ returns secrets
                              MySQL 8  (securetask namespace)

Internet → LoadBalancer → Conjur UI (Admin Dashboard)    http://<UI-IP>
                                  ↓ admin login
                             Conjur OSS
```

### Secret flow (no passwords in k8s)

```
1. Pod starts
2. conjur-secrets-provider init container runs
   └── Reads pod SA JWT from /var/run/secrets/kubernetes.io/serviceaccount/token
   └── POSTs JWT to Conjur /authn-jwt/k8s-cluster/...
   └── Conjur validates JWT against GKE OIDC issuer
   └── Returns DB credentials
   └── Writes /conjur/secrets/secrets.env
3. Flask app starts → reads secrets.env → connects to MySQL
```

---

## Repository layout

```
conjur-demo-simple/
├── app/                       Flask Incident Tracker
├── conjur-ui/                 Flask Conjur Admin UI
├── conjur-policy/
│   ├── root.yml               Top-level policy branches
│   ├── database.yml           Secrets + host identities + permits
│   └── authn-jwt.yml          JWT authenticator webservice
├── k8s/
│   ├── 00-namespace.yaml
│   ├── conjur/
│   │   └── helm-values.yaml   Conjur OSS Helm values
│   ├── conjur-ui/
│   │   ├── serviceaccount.yaml
│   │   ├── configmap.yaml
│   │   └── deployment.yaml
│   ├── mysql/
│   │   └── statefulset.yaml
│   └── webapp/
│       ├── serviceaccount.yaml
│       ├── configmap.yaml
│       ├── deployment.yaml
│       └── ingress.yaml
└── scripts/
    ├── 01-install-conjur.sh   Install NGINX + Conjur OSS
    ├── 02-init-account.sh     Initialize Conjur account (once)
    ├── 03-seed.sh             Load policies + write secrets
    ├── 04-deploy-app.sh       Build + deploy Incident Tracker
    ├── 05-verify.sh           Health check all components
    └── 06-deploy-conjur-ui.sh Build + deploy Conjur Admin UI
```

---

## Prerequisites

| Tool | Install |
|---|---|
| `kubectl` | Configured against your GKE cluster |
| `helm` | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| `gcloud` | Google Cloud SDK |

---

## Deploy in 6 steps

### 1 — Install Conjur OSS

```bash
bash scripts/01-install-conjur.sh
```

Installs NGINX Ingress Controller and Conjur OSS via Helm.
Conjur is accessible only within the cluster — no external URL needed.

### 2 — Initialize account (once)

```bash
bash scripts/02-init-account.sh
```

Creates the Conjur account and stores the admin API key as a k8s Secret.

### 3 — Load policies and seed secrets

```bash
export DB_APP_PASSWORD=YourSecurePassword
bash scripts/03-seed.sh
```

Loads the three policy files and writes all database secrets to Conjur.
The root password is generated once and stored in Conjur — never regenerated on re-runs.

### 4 — Deploy the Incident Tracker

```bash
export PROJECT_ID=your-gcp-project
export REGION=europe-west1
bash scripts/04-deploy-app.sh
```

Builds the Docker image (or uses Cloud Build if Docker is unavailable),
applies all k8s manifests, and waits for the rollout.

### 5 — Verify

```bash
bash scripts/05-verify.sh
```

Checks every component and confirms all secrets are readable in Conjur.

### 6 — Deploy Conjur Admin UI (optional)

```bash
bash scripts/06-deploy-conjur-ui.sh
```

Deploys the Conjur UI dashboard — shows policies, variables, and live audit logs.

---

## Access

| App | URL |
|---|---|
| Incident Tracker | `http://<NGINX-IP>/app` |
| Conjur Admin UI | `http://<CONJUR-UI-IP>` |

Get IPs:
```bash
# Incident Tracker IP
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Conjur UI IP
kubectl -n conjur get svc conjur-ui \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Conjur UI login:
```bash
# Account: myConjurAccount
# Username: admin
# Password:
kubectl -n conjur get secret conjur-admin-api-key \
  -o jsonpath='{.data.key}' | base64 -d
```

---

## Conjur policy summary

| Variable | Path | Who can read |
|---|---|---|
| DB host/port/user/name | `myapp/database/*` | `webapp` + `conjur-ui` pods |
| DB app password | `myapp/database/password` | `webapp` + `conjur-ui` pods |
| DB root password | `myapp/database/root-password` | `webapp` pod only |
| JWT issuer/jwks/audience | `conjur/authn-jwt/k8s-cluster/*` | Conjur internal |

Authentication:
- `host/myapp/webapp` — Kubernetes SA `webapp` in namespace `securetask`
- `host/myapp/conjur-ui` — Kubernetes SA `conjur-ui` in namespace `conjur`

---

## k8s Secrets installed

| Secret | Namespace | Contains | Sensitive |
|---|---|---|---|
| `conjur-data-key` | conjur | Conjur encryption key | High |
| `conjur-admin-api-key` | conjur | Conjur admin API key | High |
| `conjur-ssl-cert` | securetask | Conjur self-signed cert | Low |
| `flask-secret` | securetask | Flask CSRF key | Medium |
| `conjur-ui-secret` | conjur | Conjur UI Flask key | Medium |

No MySQL passwords in k8s Secrets — both are fetched from Conjur at pod startup.
