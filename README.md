# GitOps with ArgoCD on Amazon EKS

A complete GitOps implementation deploying a **three-tier web application** to **Amazon EKS** using **ArgoCD** for continuous delivery, **Kustomize** for manifest management, and **Terraform** for full infrastructure provisioning. Git is the single source of truth — any change pushed to the manifests is automatically detected by ArgoCD and applied to the cluster.

---

## Table of Contents

- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [GitOps Workflow](#gitops-workflow)
- [Cloud Best Practices](#cloud-best-practices)
- [Infrastructure Details](#infrastructure-details)
- [Getting Started](#getting-started)
- [Working with Kustomize](#working-with-kustomize)
- [Production Considerations](#production-considerations)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌────────────────────────────────────────────────────────┐
│                    AWS VPC                             │
│                                                        │
│  ┌──────────────────┐    ┌──────────────────┐          │
│  │  Public Subnet   │    │  Public Subnet   │          │
│  │   (AZ 1)         │    │   (AZ 2)         │          │
│  └──────────────────┘    └──────────────────┘          │
│                                                        │
│  ┌──────────────────┐    ┌──────────────────┐          │
│  │  Private Subnet  │    │  Private Subnet  │          │
│  │   (AZ 1)         │    │   (AZ 2)         │          │
│  │                  │    │                  │          │
│  │  ┌────────────┐  │    │  ┌────────────┐  │          │
│  │  │ EKS Nodes  │  │    │  │ EKS Nodes  │  │          │
│  │  └────────────┘  │    │  └────────────┘  │          │
│  └──────────────────┘    └──────────────────┘          │
└─────────────────────────────────────────────────────────┘

Namespace: fullstack-prod
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Frontend   │───▶│   Backend    │──▶ │  PostgreSQL │
│  React App  │     │  Node.js API│     │  Database   │
│  Port 3000  │     │  Port 8080  │     │  Port 5432  │
│ LoadBalancer│     │  ClusterIP  │     │  ClusterIP  │
└─────────────┘     └─────────────┘     └─────────────┘
```

### Three-Tier Application

| Tier | Technology | Port | Service Type |
|------|-----------|------|-------------|
| **Frontend** | React | 3000 | LoadBalancer |
| **Backend** | Node.js API | 8080 | ClusterIP |
| **Database** | PostgreSQL | 5432 | ClusterIP |

The frontend is exposed via an AWS LoadBalancer. The backend and database are internal-only, reachable only within the cluster — following the principle of least exposure.

---

## Tech Stack

| Tool | Purpose |
|------|---------|
| **Amazon EKS** | Managed Kubernetes cluster on AWS |
| **Terraform** | Provisions VPC, EKS cluster, and installs ArgoCD |
| **ArgoCD** | GitOps operator — watches Git and syncs to cluster |
| **Kustomize** | Manages image tags, replicas, and namespace across manifests |
| **Amazon S3 + DynamoDB** | Terraform remote backend and state locking |

---

## Project Structure

```
gitops-eks/
├── terraform/                   # Infrastructure as Code
│   ├── terraform.tf             # Terraform and provider requirements
│   ├── providers.tf             # Provider configurations
│   ├── variables.tf             # Input variables
│   ├── main.tf                  # VPC, EKS cluster, ArgoCD (via Helm)
│   └── outputs.tf               # Output values
│
└── manifests/                   # Kubernetes manifests (ArgoCD source of truth)
    ├── kustomization.yaml       # Kustomize config — image tags, replicas, namespace
    ├── namespace.yaml           # Namespace: 3tirewebapp-dev
    ├── secret.yaml              # PostgreSQL credentials (K8s Secret)
    ├── postgres.yaml            # PostgreSQL Deployment + Service
    ├── backend.yaml             # Backend API Deployment + Service
    ├── frontend.yaml            # Frontend Deployment + LoadBalancer Service
    └── argocd-app.yaml          # ArgoCD Application manifest
```

---

## GitOps Workflow

This project implements a pull-based GitOps model. The cluster pulls its desired state from Git — no external system pushes into the cluster.

```
1. Developer pushes code changes to application repository
         │
         ▼
2. CI/CD pipeline builds new container images and pushes to registry
         │
         ▼
3. Update manifests/kustomization.yaml with new image tags
         │
         ▼
4. ArgoCD detects the change (polls Git every ~3 min or via webhook)
         │
         ▼
5. ArgoCD syncs — applies updated manifests to EKS cluster
         │
         ▼
6. Kubernetes performs a rolling update with zero downtime
```

**Kustomize's role in this flow:** Rather than editing image tags directly in each manifest file, the `kustomization.yaml` acts as a central control point. When a new image is built, only the tag in `kustomization.yaml` needs to change — Kustomize patches all the relevant manifests at render time before ArgoCD applies them.

```yaml
# manifests/kustomization.yaml — update this to trigger a deployment
images:
  - name: frontend
    newTag: "v1.2.0"
  - name: backend
    newTag: "v1.2.0"
```

**ArgoCD auto-sync and self-healing are enabled**, meaning:
- Changes pushed to the `manifests/` directory are deployed automatically without manual intervention
- If a resource is manually changed in the cluster (e.g. `kubectl edit`), ArgoCD detects the drift and reverts it back to the Git state

---

## Cloud Best Practices

### Infrastructure as Code with Terraform

The entire AWS infrastructure — VPC, subnets, EKS cluster, node groups, IAM roles, and ArgoCD — is provisioned via Terraform. Nothing is created by clicking in the AWS console. This means:

- Infrastructure changes are reviewed like code, through pull requests
- The environment can be torn down and recreated identically in any AWS region
- `terraform plan` shows exactly what will change before anything is applied
- Every change has a full Git history and audit trail

### Network Architecture — VPC with Public and Private Subnets

The EKS cluster follows AWS network best practices:

- **Two Availability Zones** — worker nodes are spread across AZ 1 and AZ 2, so an AZ outage does not take down the application
- **Private subnets** for EKS worker nodes — nodes have no public IP addresses and are not directly reachable from the internet
- **Public subnets** for load balancers — the frontend LoadBalancer sits in the public subnet and routes traffic to pods in private subnets
- This separation ensures application workloads are shielded from direct internet exposure while remaining externally accessible through a controlled entry point

### Latest Provider and Module Versions

This project uses current major versions as of 2026:

- **AWS Provider `6.x`** — latest major version
- **EKS Module `21.x`** — includes breaking changes from earlier versions, handled correctly:
  - `cluster_name` → `name`
  - `cluster_version` → `kubernetes_version`
  - `cluster_endpoint_public_access` → `endpoint_public_access`
  - `aws-auth` ConfigMap removed in favour of **EKS Access Entries** (API-based authentication)
- **Helm Provider `3.x`** and **Kubernetes Provider `3.x`**

Using current versions matters because it avoids deprecated APIs, benefits from security patches, and ensures the code reflects how these tools actually work today rather than patterns that have been superseded.

### ArgoCD Auto-Sync and Self-Healing

ArgoCD is configured with both `automated.selfHeal: true` and `automated.prune: true`:

- **Auto-sync** means any commit to `manifests/` is applied to the cluster without any manual trigger
- **Self-healing** means drift is corrected automatically — the cluster always reflects what Git says, not what someone manually applied with `kubectl`
- **Prune** means resources removed from Git are also removed from the cluster — no orphaned resources accumulate over time

This trio enforces Git as the absolute source of truth for everything running in the cluster.

### Kustomize for Manifest Management

Rather than duplicating YAML or hardcoding values across multiple manifest files, Kustomize provides:

- **Centralised image tag management** — one change in `kustomization.yaml` propagates to all deployments
- **Replica management** — scale all tiers from a single location
- **Namespace injection** — all resources are consistently deployed to `fullstack-prod` without repeating the namespace in every file
- **Common annotations** — labels and annotations applied uniformly across all resources

### Separation of Concerns

Infrastructure code (`terraform/`) and application manifests (`manifests/`) live in the same repository but are completely independent. A manifest update to roll out a new app version never touches Terraform. An infrastructure change never accidentally triggers an application redeployment. Each layer has its own lifecycle.

---

## Infrastructure Details

### What Terraform Provisions

- **VPC** with CIDR block, public and private subnets across two Availability Zones, internet gateway, NAT gateway, and route tables
- **EKS Cluster** with a managed node group running in private subnets
- **IAM roles and policies** for the cluster, node group, and service accounts — following least privilege
- **ArgoCD** installed into the `argocd` namespace via the Helm Terraform provider

### What ArgoCD Manages

ArgoCD watches the `manifests/` directory and owns everything in the `fullstack-prod` namespace:

- PostgreSQL StatefulSet/Deployment and ClusterIP Service
- Backend Node.js Deployment and ClusterIP Service
- Frontend React Deployment and LoadBalancer Service
- Namespace and Secret resources

---

## Getting Started

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0
- `kubectl`
- An S3 bucket and DynamoDB table for Terraform remote state (or remove the backend block to use local state)

### 1. Provision Infrastructure

```bash
cd terraform/
terraform init
terraform plan
terraform apply
```

This creates the VPC, EKS cluster, and installs ArgoCD via Helm. The full apply takes approximately 15–20 minutes.

### 2. Connect kubectl to the Cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name gitops-eks-cluster
kubectl get nodes
```

### 3. Retrieve the ArgoCD Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### 4. Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` — username: `admin`, password from step 3.

### 5. Deploy the Application

**Via kubectl:**
```bash
kubectl apply -f manifests/argocd-app.yaml
```

**Via ArgoCD UI:** Create a new application using the settings defined in `manifests/argocd-app.yaml`.

ArgoCD will immediately sync and deploy all three tiers to the `fullstack-prod` namespace.

### 6. Access the Application

```bash
kubectl get svc frontend -n fullstack-prod
```

Copy the `EXTERNAL-IP` from the LoadBalancer service — this is the public URL for the React frontend.

---

## Working with Kustomize

### Preview Rendered Manifests

Before pushing any changes, preview exactly what Kustomize will render:

```bash
kubectl kustomize manifests/
```

### Update Image Tags (Triggering a Deployment)

Edit `manifests/kustomization.yaml` to update the image tag for any tier:

```yaml
images:
  - name: frontend
    newTag: "v1.3.0"
  - name: backend
    newTag: "v1.3.0"
```

Then commit and push:

```bash
git add manifests/kustomization.yaml
git commit -m "deploy: bump frontend and backend to v1.3.0"
git push
```

ArgoCD detects the change and rolls out the update automatically.

### Scale Replicas

```yaml
# manifests/kustomization.yaml
replicas:
  - name: frontend
    count: 3
  - name: backend
    count: 3
```

Commit and push — ArgoCD applies the scale change without any `kubectl scale` command needed.

---

## Production Considerations

### 🔐 Database Credentials

**Current approach:** PostgreSQL credentials are stored in a Kubernetes Secret (`manifests/secret.yaml`). This is acceptable for a demonstration but has limitations — the secret values are base64-encoded (not encrypted) and live in the Git repository.

**Production approach:** Use **AWS Secrets Manager** with the **External Secrets Operator (ESO)**. Credentials are stored in Secrets Manager and synced into the cluster as Kubernetes Secrets at runtime — nothing sensitive lives in Git.

```yaml
# Production: ExternalSecret pulls from AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: postgres-secret
  data:
    - secretKey: password
      remoteRef:
        key: prod/postgres/credentials
        property: password
```

### 🔁 CI/CD Integration

This project focuses on the CD side (ArgoCD + GitOps). In a full team workflow, a CI pipeline would sit upstream:

```
Code push → CI builds image → pushes to ECR → 
updates image tag in kustomization.yaml → commits to repo → 
ArgoCD detects change → syncs cluster
```

The image tag update step can be automated in CI using `kustomize edit set image`:

```bash
cd manifests/
kustomize edit set image frontend=123456789.dkr.ecr.us-east-1.amazonaws.com/frontend:${GIT_SHA}
git commit -am "ci: update frontend image to ${GIT_SHA}"
git push
```

Images should always be tagged with the **Git commit SHA**, never `latest` — this ensures every deployment is traceable and rollback is as simple as reverting the commit.

### 🔒 IAM — Least Privilege with IRSA

Worker nodes should not carry broad IAM permissions. Use **IAM Roles for Service Accounts (IRSA)** to give each pod only the specific AWS permissions it needs, tied to its Kubernetes service account via the EKS OIDC provider. This way a compromised pod cannot access AWS resources it was never meant to touch.

### 🌐 Private Cluster Endpoint

For production, disable the public EKS API endpoint entirely. Access the cluster only through a VPN or AWS PrivateLink. This removes the Kubernetes control plane from the internet attack surface.

### 📊 Observability

- **CloudWatch Container Insights** for node and pod metrics
- **kube-prometheus-stack** (Prometheus + Grafana) for application-level monitoring
- **ArgoCD notifications** to Slack or PagerDuty on sync failure or application health degradation

### 🔄 High Availability

- Enable the **Cluster Autoscaler** or **Karpenter** to automatically provision nodes when pods are pending
- Add **Horizontal Pod Autoscaler (HPA)** to the frontend and backend deployments
- Set **Pod Disruption Budgets (PDB)** to ensure rolling updates never take all replicas offline simultaneously
- Consider promoting PostgreSQL to **Amazon RDS** — a managed database with automated backups, multi-AZ failover, and point-in-time recovery, rather than running stateful workloads inside Kubernetes

---

## Troubleshooting

### Check ArgoCD Application Status

```bash
kubectl get application -n argocd
argocd app get fullstack-app
```

### Manually Trigger a Sync

```bash
argocd app sync fullstack-app
```

### View Application Logs

```bash
# Frontend
kubectl logs -f deployment/frontend -n fullstack-prod

# Backend
kubectl logs -f deployment/backend -n fullstack-prod

# PostgreSQL
kubectl logs -f deployment/postgres -n fullstack-prod
```

### Check ArgoCD Sync Errors

```bash
kubectl describe application 3tier-app -n argocd
```

### Clean Up

```bash
# Remove the ArgoCD application (deletes all app resources)
kubectl delete -f manifests/argocd-app.yaml

# Destroy all infrastructure
cd terraform/
terraform destroy
```

---

*Built to demonstrate a production-pattern GitOps workflow on AWS — three-tier application delivery with ArgoCD, Kustomize, and Terraform-provisioned EKS.*
