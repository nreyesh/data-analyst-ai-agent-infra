# Building Analytics AI Agent Ecosystem — Architecture & Conventions Guide

This document captures the architectural decisions, security standards, naming conventions, and CI/CD patterns established for the **Building Analytics** ecosystem. Any future infrastructure, microservices, or AI agents in this project must adhere to these conventions.

---

## 1. Repository & Codebase Hierarchy

The project follows a **Modular Git Submodule Multi-Repo Architecture**:

```
data-analyst-ai-agent/                     # Major Parent (Container / Orchestration Repo)
├── .gitmodules                            # Tracks submodule commits & paths
├── README.md
├── infra/                                 # Submodule: nreyesh/infra (IaC & Cloud Architecture)
├── backend/                               # Submodule: nreyesh/backend (FastAPI / Agent Services)
└── front/                                 # Submodule: nreyesh/front (React Frontend)
```

### Git & Branching Strategy
* **Autonomous Child Repositories:** Each child repository (`infra`, `backend`, `front`) maintains its own git history, independent commit messages, and semantic versioning.
* **Branches:**
  * `dev`: Active development, integration, and deployment to the Google Cloud `dev` project.
  * `main`: Production-ready, stable releases deployed strictly to Google Cloud `prod`.
* **Submodule Pointers:** Commits in the parent repository only update the pointer hash of the child submodules.

---

## 2. Infrastructure as Code (Terraform) Conventions

* **Tool:** Terraform >= 1.5.0 with `hashicorp/google` provider (~> 5.0).
* **State Management:** Remote backend stored in Google Cloud Storage (`gcs`).
  * State uses **partial configuration** (`backend "gcs" {}`).
  * The CI/CD pipeline dynamically injects `-backend-config="bucket=..."` and `-backend-config="prefix=terraform/state/${env}"` to prevent cross-environment state leaks.
* **Environment Separation:** Strict isolation via `.tfvars` files:
  * `environments/dev.tfvars`: Project `building-analytics-dev-513719`
  * `environments/prod.tfvars`: Project `building-analytics-prod`

---

## 3. Standardized Resource Naming Convention

All Google Cloud resources must strictly adhere to the unified prefix pattern:
$$\text{building-analytics-}<\text{resource-type}>-\$\{var.environment\}$$

| Resource Type | Resource Category | Standardized Pattern | Example (`dev`) |
| :--- | :--- | :--- | :--- |
| **Artifact Registry** | Container Registry | `building-analytics-repo-${env}` | `building-analytics-repo-dev` |
| **Cloud Storage** | Data Lake / Uploads | `building-analytics-data-${env}` | `building-analytics-data-dev` |
| **Secret Manager** | Database Passwords | `building-analytics-db-pass-${env}` | `building-analytics-db-pass-dev` |
| **VPC Network** | Custom Network | `building-analytics-vpc-${env}` | `building-analytics-vpc-dev` |
| **Subnet** | Private Subnet | `building-analytics-subnet-${env}` | `building-analytics-subnet-dev` |
| **Private IP Allocation** | VPC Peering Range | `building-analytics-ip-alloc-${env}` | `building-analytics-ip-alloc-dev` |
| **Cloud SQL Server Instance** | Compute / Engine Server | `building-analytics-instance-${env}-${hex}` | `building-analytics-instance-dev-a1b2c3d4` |
| **PostgreSQL Database** | Logical SQL DB | `building_analytics_db_${env}` | `building_analytics_db_dev` |
| **Runtime Service Account** | IAM Identity | `building-analytics-runner-${env}` | `building-analytics-runner-dev` |
| **Cloud Run Backend** | Compute / Microservice | `building-analytics-backend-${env}` | `building-analytics-backend-dev` |

---

## 4. Security & Least Privilege Architecture

### A. CI/CD Keyless Authentication (Workload Identity Federation)
* **Zero Static JSON Keys:** Neither GitHub Secrets nor local machines store long-lived service account keys.
* **Workload Identity Pool:** `github-pool-${env}` validates incoming GitHub Actions OIDC tokens.
* **Enforced Attribute Condition:** `assertion.repository_owner == 'nreyesh'` restricts pool access strictly to the owner's GitHub repositories.
* **Service Account Binding:** Bound to `attribute.repository/nreyesh/infra` with role `roles/iam.workloadIdentityUser`.

### B. Database Security (Zero Public IP)
* **Private Cloud SQL Instance:** `ipv4_enabled = false`. The database possesses **zero public IP addresses** and cannot be reached via the internet.
* **Private Service Access:** Peered directly into the private VPC (`building-analytics-vpc-${env}`).
* **Secret Manager Integration:** Passwords are generated via `random_password` and saved automatically into Secret Manager. Passwords are never placed in Git or tfvars.

### C. Backend & Frontend Ingress Architecture (Zero Direct Exposure)
* **Private Backend:** Cloud Run service sets `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`. Public internet calls to `*.run.app` are rejected.
* **Reverse Proxy:** Firebase Hosting serves the React frontend publicly and proxies `/api/**` traffic internally to Cloud Run over Google's private backbone.
* **Benefits:** Eliminates CORS errors, protects backend from DDoS/scraping, and keeps edge caching on Firebase CDN.

### D. Multi-Tenant Data Isolation (Trusted Subsystem Pattern)
* End-users log in via **Firebase Authentication** on the React frontend.
* The frontend passes verified JWT ID tokens to Cloud Run: `Authorization: Bearer <TOKEN>`.
* Cloud Run runs under `building-analytics-runner-${env}`, which acts as the database gatekeeper.
* Backend services enforce tenant scoping on every SQL query (`WHERE user_id = :current_user_id`). Users cannot execute raw SQL directly.

---

## 5. Maintenance Checklist

### Deploying Changes to `dev`
```bash
cd infra
git checkout dev
git add .
git commit -m "feat(infra): your message"
git push origin dev
```
GitHub Actions will automatically run:
1. `terraform init` with dynamic dev backend config.
2. `terraform plan -var-file="environments/dev.tfvars"`.
3. `terraform apply -auto-approve -var-file="environments/dev.tfvars"`.

### Promoting to Production (`main`)
Create a Pull Request from `dev` to `main`:
1. PR triggers `terraform plan -var-file="environments/prod.tfvars"`.
2. Review the plan.
3. Merge PR -> GitHub Actions runs `terraform apply` against the `prod` project.
