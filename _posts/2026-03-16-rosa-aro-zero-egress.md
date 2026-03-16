---
layout: default
title: "Zero-Egress Clusters on ROSA HCP and ARO: A Practical Comparison"
date: 2026-03-16
---

# Zero-Egress Clusters on ROSA HCP and ARO: A Practical Comparison

**Author:** Kevin Ye
**Date:** March 2026

---

## Introduction

Many customers in regulated industries (financial services, government, healthcare) require clusters with no internet-bound egress traffic. This article shares practical learnings from provisioning zero-egress clusters on both **ROSA HCP (AWS)** and **ARO (Azure)**, comparing the architecture, prerequisites, access patterns, and gotchas encountered along the way.

**What is zero-egress?** A zero-egress cluster has no outbound internet connectivity. Worker nodes cannot reach the public internet — all communication with cloud services happens through private endpoints (AWS VPC Endpoints or Azure Private Endpoints/Service Endpoints). This is distinct from a "private cluster" which only makes the API/ingress private but may still allow outbound internet traffic via NAT Gateway or Load Balancer.

---

## Architecture Comparison at a Glance

| Aspect | ROSA HCP (AWS) | ARO (Azure) |
|--------|----------------|-------------|
| **Control Plane** | Hosted by Red Hat (not in customer VPC) | Deployed in customer VNet (master subnet) |
| **Egress Control Mechanism** | No NAT Gateway + VPC Endpoints only | Azure Firewall + UDR (UserDefinedRouting) |
| **Required Private Endpoints** | S3 (Gateway), STS, ECR API, ECR DKR, CloudWatch Logs, CloudWatch Monitoring | Storage, Container Registry (Service Endpoints on subnets) |
| **Subnet Requirements** | Private subnets only (no public subnets needed) | Master subnet, Worker subnet, Firewall subnet, Jumphost subnet |
| **Private API** | `--private` flag (PrivateLink) | `api_server_profile = "Private"` |
| **Private Ingress** | `--default-ingress-private` flag | `ingress_profile = "Private"` |
| **Access Method** | VPC Peering + Bastion, or AWS Client VPN | Jumphost with SSH tunnel, Azure P2S VPN, or sshuttle |
| **Terraform Automation** | Validated pattern with modular network types | Single repo with conditional resources (`count`) |
| **Approximate Setup Complexity** | Moderate | Higher (Firewall adds cost and config) |

---

## ROSA HCP Zero-Egress

### How It Works

ROSA HCP's zero-egress mode is relatively straightforward because the control plane runs in Red Hat's infrastructure, not in the customer VPC. The customer VPC only contains worker nodes, which communicate with AWS services through VPC Endpoints.

**Architecture diagram:**
```
                          +--------------------------+
                          |   Red Hat Managed Infra   |
                          |  (Control Plane via       |
                          |   AWS PrivateLink)        |
                          +------------+-------------+
                                       | PrivateLink
                   X  No Internet      | (private connectivity)
                   X  Gateway / NAT    |
                                       v
+==================================================================================+
|  Customer VPC (10.30.0.0/16) — Private Subnets Only, No NAT GW, No IGW          |
|                                                                                  |
|  +---------------------------+  +---------------------------+  +---------------+ |
|  | Private Subnet AZ-a       |  | Private Subnet AZ-b       |  | Private Sub   | |
|  | 10.30.0.0/18              |  | 10.30.64.0/18             |  | AZ-c          | |
|  |                           |  |                           |  | 10.30.128.0/18| |
|  |  +-------+  +-------+    |  |  +-------+  +-------+    |  |               | |
|  |  |Worker |  |Worker |    |  |  |Worker |  |Worker |    |  |  +-------+    | |
|  |  |Node   |  |Node   |    |  |  |Node   |  |Node   |    |  |  |Worker |    | |
|  |  +-------+  +-------+    |  |  +-------+  +-------+    |  |  +-------+    | |
|  |                           |  |                           |  |               | |
|  |  tag: kubernetes.io/      |  |  tag: kubernetes.io/      |  |  tag: k8s.io/ | |
|  |  role/internal-elb=1      |  |  role/internal-elb=1      |  |  internal-elb | |
|  +---------------------------+  +---------------------------+  +---------------+ |
|                                                                                  |
|  +--VPC Endpoints (private connectivity to AWS services)-------------------------+
|  |                                                                               |
|  |  +------------------+   +------------------+   +------------------+           |
|  |  | S3 (Gateway)     |   | STS (Interface)  |   | ECR API          |           |
|  |  | FREE             |   | ~$7/mo           |   | (Interface)      |           |
|  |  +------------------+   +------------------+   | ~$7/mo           |           |
|  |                                                 +------------------+           |
|  |  +------------------+   +------------------+   +------------------+           |
|  |  | ECR DKR          |   | CloudWatch Logs  |   | CloudWatch       |           |
|  |  | (Interface)      |   | (Interface)      |   | Monitoring       |           |
|  |  | ~$7/mo           |   | ~$7/mo           |   | (Interface)      |           |
|  |  +------------------+   +------------------+   +------------------+           |
|  +-------------------------------------------------------------------------------+
|                                                                                  |
|  +--AWS Client VPN Endpoint (optional)-------------------------------------------+
|  |  Client CIDR: 10.100.0.0/22  |  Split tunnel: enabled                        |
|  +-------------------------------+----------------------------------------------+
|                 ^                                                                |
+==================================================================================+
                  |
                  | OpenVPN tunnel
                  |
          +-------+-------+
          |   Laptop       |
          |   (Developer)  |
          +----------------+
```

### Prerequisites

1. **VPC with private subnets only** — no public subnets, no NAT Gateway
2. **VPC Endpoints** (minimum required):

   | Service | Type | Cost |
   |---------|------|------|
   | `com.amazonaws.<region>.s3` | Gateway | Free |
   | `com.amazonaws.<region>.sts` | Interface | ~$7/mo |
   | `com.amazonaws.<region>.ecr.api` | Interface | ~$7/mo |
   | `com.amazonaws.<region>.ecr.dkr` | Interface | ~$7/mo |

   Optional but recommended for observability:
   | Service | Type | Purpose |
   |---------|------|---------|
   | `com.amazonaws.<region>.logs` | Interface | CloudWatch Logs |
   | `com.amazonaws.<region>.monitoring` | Interface | CloudWatch Monitoring |

3. **Subnet tagging**: All private subnets must have `kubernetes.io/role/internal-elb = 1`
4. **Security group for VPC endpoints**: Allow HTTPS (443) inbound from VPC CIDR

> **Important**: `elasticloadbalancing` and `ec2` endpoints are NOT required for ROSA HCP — the control plane runs in Red Hat's infrastructure.

### Cluster Creation

The critical flags are `--private` (API via PrivateLink) and `--default-ingress-private` (internal load balancer for ingress):

```bash
rosa create cluster --cluster-name=kev-ze1 \
     --mode=auto --hosted-cp \
     --operator-roles-prefix kev-ze1 \
     --oidc-config-id "<oidc-config-id>" \
     --subnet-ids="<private-subnet-1>,<private-subnet-2>,<private-subnet-3>" \
     --region ap-southeast-1 \
     --machine-cidr 10.30.0.0/16 \
     --private \
     --default-ingress-private
```

### Terraform Approach (Validated Pattern)

```
  Repo: latest-validated-pattern
  ===============================

  latest-validated-pattern/
  +-- Makefile                        # Root: make cluster.<name>.<op>
  +-- Makefile.cluster                # Cluster operations (init/plan/apply/destroy)
  +-- terraform/                      # Root Terraform config
  |   +-- 10-main.tf                  # Calls modules based on network_type
  |   +-- 01-variables.tf
  |   +-- 90-outputs.tf
  +-- modules/
  |   +-- infrastructure/
  |       +-- network-private/        # <-- Used for zero-egress
  |       |   +-- 10-main.tf          #     VPC, private subnets, VPC endpoints,
  |       |                           #     security groups, route tables
  |       +-- network-public/         #     (not used for zero-egress)
  +-- clusters/
  |   +-- egress-zero/                # <-- Cluster-specific config
  |   |   +-- terraform.tfvars        #     network_type="private", zero_egress=true
  |   +-- public/
  |       +-- terraform.tfvars
  +-- scripts/
      +-- cluster/                    # init, plan, apply, destroy scripts
      +-- vpn/                        # VPN start/stop/status
      +-- tunnel/                     # sshuttle start/stop (deprecated)
```

The validated pattern uses a modular approach with separate network types:

- `network_type = "private"` — creates only private subnets (no public subnets)
- `zero_egress = true` — enables zero-egress mode (no NAT Gateway, strict security groups)
- `private = true` — makes API endpoint private via PrivateLink

Key Terraform configuration (`terraform.tfvars`):
```hcl
cluster_name = "kev-ze1"
network_type = "private"
zero_egress  = true
private      = true
region       = "ap-southeast-1"
vpc_cidr     = "10.30.0.0/16"

# Access: AWS Client VPN (preferred over bastion)
enable_client_vpn     = true
vpn_client_cidr_block = "10.100.0.0/22"
vpn_split_tunnel      = true
```

The network module automatically:
- Creates VPC with private subnets only
- Provisions all required VPC Endpoints (S3, STS, ECR, CloudWatch)
- Applies strict security groups (egress limited to VPC CIDR on port 443 and DNS)
- Tags subnets for internal ELB

### Step-by-Step: Deploy ROSA HCP Zero-Egress with Terraform

The `latest-validated-pattern` repo provides a modular Terraform setup with a cluster-based directory structure. Each cluster has its own `terraform.tfvars` under `clusters/<cluster-name>/`.

#### Prerequisites

- AWS CLI configured and authenticated
- ROSA CLI installed and logged in (`rosa login`)
- Terraform CLI (>= 1.x)
- `oc` CLI (for cluster access after deployment)

#### Step 1: Clone the repo and review the cluster config

```bash
cd latest-validated-pattern
ls clusters/
# Available clusters: egress-zero, public, etc.
```

Review or create a cluster config directory (e.g., `clusters/egress-zero/`) with a `terraform.tfvars`:

```hcl
# clusters/egress-zero/terraform.tfvars

cluster_name = "kev-ze1"

# Network Configuration
network_type = "private"    # Private subnets only for zero-egress
zero_egress  = true         # No internet egress, only VPC endpoints
private      = true         # Private API endpoint (PrivateLink)
region       = "ap-southeast-1"
vpc_cidr     = "10.30.0.0/16"

# AWS Client VPN (recommended for zero-egress access)
enable_client_vpn         = true
vpn_client_cidr_block     = "10.100.0.0/22"   # Must not overlap with vpc_cidr
vpn_split_tunnel          = true
vpn_session_timeout_hours = 12

# Cluster Topology
multi_az              = true         # Multi-AZ for HA
default_instance_type = "m5.xlarge"
openshift_version     = "4.19.24"

# Network CIDRs
service_cidr = "172.30.0.0/16"
pod_cidr     = "10.128.0.0/14"
host_prefix  = 23
```

#### Step 2: Initialize the infrastructure

```bash
make cluster.egress-zero.init
```

This runs `terraform init` in the `terraform/` directory using the cluster-specific variables.

#### Step 3: Plan and review

```bash
make cluster.egress-zero.plan
```

Review the plan output. For a zero-egress cluster, you should see:
- VPC with private subnets only (no public subnets, no NAT Gateway)
- VPC Endpoints: S3 (Gateway), STS, ECR API, ECR DKR, CloudWatch Logs, CloudWatch Monitoring
- Security groups with restricted egress (HTTPS to VPC CIDR only)
- ROSA HCP cluster with `private = true`
- AWS Client VPN endpoint (if enabled)

#### Step 4: Apply (create the cluster)

```bash
make cluster.egress-zero.apply
```

This provisions all infrastructure and creates the ROSA HCP cluster. Cluster creation typically takes 15-25 minutes.

#### Step 5: Connect via VPN and access the cluster

```bash
# Show VPN config and connection instructions
make cluster.egress-zero.vpn-config

# Start VPN tunnel (uses OpenVPN)
make cluster.egress-zero.vpn-start

# Verify VPN is connected
make cluster.egress-zero.vpn-status
```

#### Step 6: Login to the cluster

```bash
# Show API and console URLs
make cluster.egress-zero.show-endpoints

# Show admin credentials
make cluster.egress-zero.show-credentials

# Login via oc CLI (auto-starts VPN if needed)
make cluster.egress-zero.login
```

#### Step 7: (Optional) Bootstrap GitOps

If `enable_gitops_bootstrap = true` is set in tfvars:

```bash
make cluster.egress-zero.bootstrap
```

#### Cleanup

```bash
# Sleep the cluster (preserves DNS, IAM, secrets — can wake later)
make cluster.egress-zero.sleep

# Or fully destroy all resources
make cluster.egress-zero.destroy
```

### Zero-Egress Security Groups

In zero-egress mode, security groups are locked down:

**VPC Endpoint SG:**
- Inbound: HTTPS (443) from VPC CIDR
- Outbound: None (no egress rules)

**Worker Node SG:**
- Inbound: All traffic from VPC CIDR
- Outbound: HTTPS (443) to VPC CIDR only, DNS (53 UDP/TCP) to VPC CIDR only

### Access Patterns

Since the cluster has no public endpoints, access requires one of:

1. **AWS Client VPN** (recommended) — connect your laptop directly to the VPC
2. **VPC Peering + Bastion** — peer a bastion VPC to the ROSA VPC, then SSH tunnel or use a Windows bastion with a browser
3. **Route53 Private Hosted Zone association** — associate the cluster's private hosted zones with the bastion/VPN VPC for DNS resolution

```
  Option 1: AWS Client VPN (Recommended)
  =======================================

  +----------+    OpenVPN     +------------------+    private    +----------------+
  |  Laptop  | ------------> | AWS Client VPN   | -----------> | ROSA HCP       |
  |          |  split tunnel  | Endpoint in VPC  |   subnet     | Worker Nodes   |
  +----------+                +------------------+              | API (Private)  |
                                                                | Apps (Private) |
                                                                +----------------+

  Option 2: VPC Peering + Bastion
  ================================

                  +---------------------+         VPC Peering        +------------------+
  +----------+   | Bastion VPC          |  <=====================>  | ROSA VPC         |
  |  Laptop  |-->| (172.168.0.0/16)     |     Route tables +        | (10.30.0.0/16)   |
  |   RDP/   |   |  +----------------+  |     Security groups +     |  Worker Nodes    |
  |   SSH    |   |  | Windows/Linux  |  |     Route53 PHZ assoc     |  API (Private)   |
  +----------+   |  | Bastion Host   |  |                           |  Apps (Private)  |
                  |  +----------------+  |                           +------------------+
                  +---------------------+
```

### Gotchas and Lessons Learned

1. **Must use BOTH `--private` AND `--default-ingress-private`**: Using only `--private` will cause the ingress to attempt creating a public-facing load balancer, which fails in a private-only subnet setup with "Must have at least one public subnet."

2. **Subnet tagging is critical**: Without `kubernetes.io/role/internal-elb=1` on private subnets, the internal load balancer for ingress will be stuck in `<pending>` state.

3. **DNS resolution across VPC peering**: If using a bastion in a separate VPC, you must associate the ROSA cluster's Route53 private hosted zones with the bastion VPC. Otherwise, `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>` won't resolve.

4. **Security group rules for peered VPC**: After VPC peering, you need to add ingress rules to both the VPC endpoint SG and the default ROSA SG to allow traffic from the bastion VPC CIDR.

5. **VPC Endpoints cost**: Each Interface endpoint costs ~$7-10/month. With 4-6 endpoints, budget ~$30-60/month for endpoints alone.

---

## ARO Zero-Egress

### How It Works

ARO's zero-egress approach is more involved because:
- The control plane runs **inside the customer VNet** (unlike ROSA HCP)
- Egress restriction uses **Azure Firewall** with User Defined Routing (UDR)
- The firewall needs explicit application rules for Red Hat and Azure service FQDNs

**Architecture diagram:**
```
                                    Internet
                                       ^
                                       | (only firewall has public IP;
                                       |  cluster nodes cannot reach internet
                                       |  unless firewall FQDN rules allow it)
                                       |
+======================================|==========================================+
|  Azure VNet (10.0.0.0/20)            |                                          |
|                                       |                                          |
|  +-----------------------------------+--------------------------------------+   |
|  | AzureFirewallSubnet (10.0.6.0/23)                                        |   |
|  |                                                                          |   |
|  |  +-----------------------------+                                         |   |
|  |  | Azure Firewall              |   Application Rules:                    |   |
|  |  | Public IP: x.x.x.x         |   - *.azurecr.io, *.azure.com          |   |
|  |  | Private IP: 10.0.6.4       <----  - registry.redhat.io, *.quay.io    |   |
|  |  +-----------------------------+   - *.openshift.com, *.redhat.com      |   |
|  |         ^                          - login.microsoftonline.com           |   |
|  +---------|-----------+-------------+--------------------------------------+   |
|            |           |             |                                          |
|     UDR: 0.0.0.0/0    |      UDR: 0.0.0.0/0                                    |
|     -> 10.0.6.4       |      -> 10.0.6.4                                        |
|            |           |             |                                          |
|  +---------+---------+ | +-----------+----------+                               |
|  | Master Subnet     | | | Worker Subnet         |                              |
|  | 10.0.0.0/23       | | | 10.0.2.0/23           |                              |
|  |                   | | |                        |                              |
|  | +-----+ +-----+  | | | +------+ +------+     |   +------------------------+ |
|  | |CP   | |CP   |  | | | |Worker| |Worker|     |   | Jumphost Subnet        | |
|  | |Node | |Node |  | | | |Node  | |Node  |     |   | 10.0.4.0/23            | |
|  | +-----+ +-----+  | | | +------+ +------+     |   |                        | |
|  | +-----+          | | | +------+               |   | +--------------------+ | |
|  | |CP   |          | | | |Worker|               |   | | Jumphost VM        | | |
|  | |Node |          | | | |Node  |               |   | | Public IP: y.y.y.y | | |
|  | +-----+          | | | +------+               |   | | SSH / sshuttle     | | |
|  |                   | | |                        |   | +--------------------+ | |
|  | NSG + Service     | | | NSG + Service          |   +------------------------+ |
|  | Endpoints:        | | | Endpoints:             |                              |
|  | Storage, ACR      | | | Storage, ACR           |                              |
|  +-------------------+ | +------------------------+                              |
|                        |                                                         |
|  +---------------------+-------------------------------------------------------+|
|  | (Optional) Private Endpoint Subnet (10.0.8.0/23)                             ||
|  |  +-------------------+                                                       ||
|  |  | ACR Private       |   Private DNS Zone: *.azurecr.io                      ||
|  |  | Endpoint          |                                                       ||
|  |  +-------------------+                                                       ||
|  +------------------------------------------------------------------------------+|
|                                                                                  |
|  +---(Optional) GatewaySubnet (10.0.0.64/27)------------------------------------+
|  |  +-------------------+                                                       |
|  |  | VPN Gateway       |  P2S VPN: OpenVPN protocol                            |
|  |  | (VpnGw1 SKU)      |  Client pool: 172.16.0.0/24                           |
|  |  +-------------------+  Root CA + Client cert (EKU: clientAuth required!)     |
|  +------+----------------------------------------------------------------------- +
|         ^                                                                        |
+=========|========================================================================+
          |
          | OpenVPN / Tunnelblick
          |
  +-------+-------+
  |   Laptop       |
  |   (Developer)  |
  +----------------+
```

### Prerequisites

1. **Azure Firewall** with a public IP (required for the firewall itself, but cluster traffic is routed through it)
2. **Route Table** with UDR: `0.0.0.0/0 -> VirtualAppliance (Firewall private IP)`
3. **Firewall Application Rules** for required FQDNs
4. **Service Endpoints** on subnets: `Microsoft.Storage`, `Microsoft.ContainerRegistry`
5. **Cluster creation flag**: `outbound_type = "UserDefinedRouting"`

### Firewall Rules Required

ARO requires specific FQDN-based firewall rules to function:

**Azure-specific:**
- `*.azurecr.io`, `*.azure.com`, `login.microsoftonline.com`
- `*.windows.net`, `dc.services.visualstudio.com`
- `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com`, `*.monitoring.azure.com`

**Red Hat / OpenShift:**
- `registry.redhat.io`, `*.registry.redhat.io`, `registry.access.redhat.com`
- `*.quay.io`, `quay.io`, `cdn.quay.io`, `cdn01-03.quay.io`
- `cert-api.access.redhat.com`, `api.openshift.com`, `api.access.redhat.com`
- `mirror.openshift.com`, `sso.redhat.com`
- `*.redhat.com`, `*.openshift.com`, `*.microsoft.com`

**Docker (if needed):**
- `*cloudflare.docker.com`, `*registry-1.docker.io`, `auth.docker.io`

### Terraform Approach

```
  Repo: aroze
  ============

  aroze/
  +-- Makefile                        # make create-zero-egress / destroy
  +-- 00-terraform.tf                 # Provider config (azurerm ~>4.21.1)
  +-- 01-variables.tf                 # All variables (cluster, network, egress)
  +-- 02-locals.tf                    # Computed locals
  +-- 03-data.tf                      # Data sources (existing RG, VNet, subnets)
  +-- 10-network.tf                   # NSGs (always created)
  +-- 11-egress.tf                    # Azure Firewall + UDR + rules
  |                                   #   (conditional: restrict_egress_traffic)
  +-- 20-iam.tf                       # Service principals / managed identities
  +-- 30-jumphost.tf                  # Bastion VM (conditional: private API/ingress)
  +-- 40-acr.tf                       # Private ACR (conditional: acr_private)
  +-- 50-cluster.tf                   # ARO cluster resource
  +-- 90-outputs.tf                   # API URL, console URL, credentials
  +-- modules/
  |   +-- aro-permissions/            # Vendored SP/MI permission module (v0.2.1)
  +-- terraform.tfvars                # Your cluster-specific config
```

ARO uses conditional resources controlled by variables:

```hcl
# Enable private cluster with egress restriction
api_server_profile       = "Private"
ingress_profile          = "Private"
restrict_egress_traffic  = true   # Creates Azure Firewall + UDR
```

When `restrict_egress_traffic = true`:
- Azure Firewall and its subnet are created
- Route table with UDR is created and associated with master/worker subnets
- Application rule collections are added for Azure, Red Hat, and Docker FQDNs
- A jumphost VM is automatically created for cluster access

### Step-by-Step: Deploy ARO Zero-Egress with Terraform

The `aroze` repo uses a single Terraform root with conditional resources. It expects **existing Azure resources** (resource group, VNet, subnets) and layers the ARO cluster, firewall, and jumphost on top.

#### Prerequisites

- Azure CLI (`az`) installed and logged in
- Terraform CLI (>= 1.12)
- `oc` CLI (for cluster access after deployment)
- An existing Azure resource group, VNet, and subnets (master + worker)
- Red Hat pull secret (download from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

#### Step 1: Prepare the existing network

Before running Terraform, add required service endpoints to the existing subnets. The Makefile has a target for this:

```bash
cd aroze

# This adds Microsoft.Storage and Microsoft.ContainerRegistry service endpoints
# to both master and worker subnets
make prep-subnets
```

Or manually:

```bash
az network vnet subnet update -g kevin-rg --vnet-name kev-ne1-vnet \
  -n MASTER-SUBNET --service-endpoints Microsoft.Storage Microsoft.ContainerRegistry

az network vnet subnet update -g kevin-rg --vnet-name kev-ne1-vnet \
  -n WORKER-SUBNET --service-endpoints Microsoft.Storage Microsoft.ContainerRegistry
```

#### Step 2: Create the terraform.tfvars

```bash
# Copy the example file
make tfvars

# Then edit terraform.tfvars with your values
```

Key variables for zero-egress:

```hcl
# terraform.tfvars

# Existing Azure resources (must exist before running Terraform)
resource_group_name       = "kevin-rg"
vnet_name                 = "kev-ne1-vnet"
control_plane_subnet_name = "MASTER-SUBNET"
machine_subnet_name       = "WORKER-SUBNET"

# Cluster configuration
cluster_name    = "kev-aro-ze"
location        = "southeastasia"
subscription_id = "<your-azure-subscription-id>"

# Zero-egress settings — all four of these are required together
api_server_profile      = "Private"
ingress_profile         = "Private"
restrict_egress_traffic = true                # Creates Azure Firewall + UDR
outbound_type           = "UserDefinedRouting" # Routes egress through firewall

# Firewall subnet CIDR (must fit in your existing VNet address space)
aro_firewall_subnet_cidr_block = "10.0.0.128/26"

# Access method: jumphost or VPN (set false if using Azure P2S VPN)
create_jumphost = false

# Pull secret for Red Hat registry access (required for OperatorHub)
pull_secret_path = "~/Downloads/pull-secret.txt"
```

> **Important**: The four zero-egress variables (`api_server_profile`, `ingress_profile`, `restrict_egress_traffic`, `outbound_type`) must all be set together. Missing any one of them will result in a broken configuration.

#### Step 3: Initialize and deploy

```bash
# Option A: Use the zero-egress make target (includes prep-subnets + init)
make create-zero-egress
```

This runs:
1. `make prep-subnets` — adds service endpoints to existing subnets
2. `terraform init -upgrade`
3. `terraform plan -out aro.plan`
4. `terraform apply aro.plan`

Or step by step:

```bash
# Initialize
make init

# Plan (review the output carefully)
terraform plan -out aro.plan

# Apply
terraform apply aro.plan
```

ARO cluster creation typically takes **35-50 minutes** (longer than ROSA HCP due to in-VNet control plane).

#### Step 4: Access the cluster

**Option A: Jumphost** (if `create_jumphost = true`)

```bash
# Get jumphost IP and credentials
JUMP_IP=$(terraform output -raw public_ip)

# SSH tunnel for API and console access
sudo ssh -L 6443:api.<domain>.<location>.aroapp.io:6443 \
  -L 443:console-openshift-console.apps.<domain>.<location>.aroapp.io:443 \
  aro@$JUMP_IP

# Or use sshuttle for full VPN-like access
sshuttle --dns -NHr aro@$JUMP_IP 10.0.0.0/20 --daemon
```

**Option B: Azure P2S VPN** (see the dedicated section below for setup)

#### Step 5: Login to the cluster

```bash
# Show credentials
make show_credentials

# Login via oc CLI
make login

# Or manually:
API_URL=$(terraform output -raw api_url)
oc login $API_URL --username=kubeadmin --password=<password> --insecure-skip-tls-verify=true
```

#### Cleanup

```bash
# Destroy all resources (service principal cluster)
make destroy

# For managed identity clusters, use the special target:
make destroy-managed-identity
```

### Access Pattern

1. **Jumphost VM**: Auto-provisioned when API or ingress is Private. SSH into the jumphost, then access the cluster.
2. **SSH tunnel**: Forward ports 6443 (API) and 443 (console) through the jumphost.
3. **sshuttle**: VPN-like access through the jumphost — `sshuttle --dns -NHr aro@$JUMP_IP 10.0.0.0/20 --daemon`
4. **Azure P2S VPN**: Set up a VPN Gateway with OpenVPN for direct laptop-to-VNet connectivity (see detailed guide below).

### Azure P2S VPN for Private ARO Access

For a better developer experience than SSH tunneling, Azure Point-to-Site VPN provides direct connectivity:

```
  Azure P2S VPN Access Flow
  =========================

  +----------+                     +--------------------+
  |  Laptop  |    OpenVPN          |  Azure VPN Gateway |
  |  (macOS) |    (Tunnelblick)    |  (VpnGw1 SKU)     |
  |          | ------------------> |  GatewaySubnet     |
  +----------+                     |  10.0.0.64/27      |
       |                           +----+---------------+
       | Client IP: 172.16.0.x          |
       |                                | same VNet
       |    +---------------------------+
       |    |
       |    v
       |  +--------------------------------------------------+
       |  |  ARO VNet (10.0.0.0/24)                          |
       |  |                                                  |
       |  |  API Server -----> api.<domain>.aroapp.io:6443   |
       |  |  Console --------> *.apps.<domain>.aroapp.io:443 |
       |  |  OAuth ----------> oauth-openshift.apps.*:443    |
       |  +--------------------------------------------------+
       |
       |  DNS: /etc/hosts entries required
       |  (Azure P2S doesn't auto-forward private DNS zones)
       +---> api.<domain>.<region>.aroapp.io         -> <API private IP>
       +---> console-openshift-console.apps.<domain> -> <Ingress private IP>
       +---> oauth-openshift.apps.<domain>           -> <Ingress private IP>

  Certificate Chain (required):
  +----------------+     signs     +------------------+
  | Root CA        | ------------> | Client Cert      |
  | (self-signed)  |               | MUST include:    |
  | uploaded to    |               | extendedKeyUsage |
  | VPN Gateway    |               | = clientAuth     |
  +----------------+               +------------------+
```

**Setup steps:**

1. **Create GatewaySubnet** in the ARO VNet (minimum /27)
2. **Deploy VPN Gateway** (VpnGw1 SKU, takes 30-45 minutes)
3. **Generate certificates**: Root CA + Client cert with `extendedKeyUsage = clientAuth`
4. **Configure P2S**: Upload root cert, set client address pool (e.g., `172.16.0.0/24`), protocol = OpenVPN
5. **Connect**: Download VPN profile, import into Tunnelblick (macOS) or OpenVPN client

> **Key gotcha**: The client certificate MUST include `extendedKeyUsage = clientAuth` extension. Without it, the VPN Gateway silently rejects the connection with a `connection-reset` after TLS handshake — no error message, just a reset.

### Managed Identities (Preview)

ARO now supports managed identities as an alternative to service principals:
- Eliminates credential management (no SP secrets to rotate)
- Creates 9 user-assigned managed identities
- Currently requires ARM template deployment (Terraform `azurerm` provider doesn't support it natively yet)
- **Limitation**: NSGs cannot be attached to subnets when using managed identities (preview limitation)

### Gotchas and Lessons Learned

1. **Azure Firewall cost**: Azure Firewall Standard costs ~$900/month. This is a significant cost for lab/dev environments. Consider if the security benefit justifies the cost for non-production use.

2. **Firewall rule maintenance**: The list of required FQDNs can change with ARO/OpenShift updates. Monitor the [official Microsoft documentation](https://learn.microsoft.com/en-us/azure/openshift/howto-restrict-egress) for updates.

3. **VPN Gateway provisioning time**: 30-45 minutes. Plan accordingly and use `--no-wait` with monitoring.

4. **VPN certificate EKU**: The `extendedKeyUsage = clientAuth` requirement is not well-documented. Missing it causes silent connection resets that are difficult to debug.

5. **DNS resolution with VPN**: Azure P2S VPN doesn't automatically configure DNS forwarding for private DNS zones. You'll need to manually add `/etc/hosts` entries or set up DNS forwarding.

6. **Single VNet architecture**: The current approach puts the firewall in the same VNet as ARO. A hub-spoke model (firewall in a hub VNet, ARO in a spoke VNet) would be better for production but adds complexity.

---

## Side-by-Side Summary

### Traffic Flow Comparison

```
  ROSA HCP Zero-Egress                          ARO Zero-Egress
  =====================                          ===============

  Worker Node                                    Worker Node
      |                                              |
      | (port 443 to VPC CIDR only)                  | (all egress -> UDR)
      v                                              v
  +-------------------+                          +-------------------+
  | VPC Endpoint      |                          | Azure Firewall    |
  | (per-service)     |                          | (FQDN filtering)  |
  |                   |                          |                   |
  | S3 -----> S3 Svc  |                          | Rule: *.quay.io   |--->  Internet
  | STS ----> STS Svc |                          | Rule: *.azurecr.io|      (filtered)
  | ECR ----> ECR Svc |                          | Rule: *.redhat.com|
  +-------------------+                          +-------------------+
       |                                              |
       X  No Internet path                            | Only allowed FQDNs
       X  (no NAT GW, no IGW)                        | pass through
                                                      v
  Control Plane:                                 Control Plane:
  Red Hat Managed (PrivateLink)                  In-VNet (Master Subnet)

  Cost: ~$30-60/mo                               Cost: ~$900+/mo
  (VPC Endpoints)                                 (Azure Firewall Standard)
```

| Category | ROSA HCP | ARO |
|----------|----------|-----|
| **Egress blocking mechanism** | No NAT GW + private subnets + VPC Endpoints | Azure Firewall + UDR + application rules |
| **Monthly cost of egress control** | ~$30-60 (VPC Endpoints) | ~$900+ (Azure Firewall) |
| **Setup complexity** | Lower (hosted control plane) | Higher (firewall rules, UDR, multiple subnets) |
| **Required subnets** | Private subnets only (1 per AZ) | Master, Worker, Firewall, Jumphost, (Optional) PE subnet |
| **FQDN allowlisting needed?** | No (VPC Endpoints handle service access) | Yes (firewall application rules) |
| **Control plane location** | Red Hat managed (outside customer VPC) | Customer VNet (master subnet) |
| **Best access method** | AWS Client VPN or VPC Peering | Azure P2S VPN or sshuttle |
| **Terraform maturity** | Validated pattern (modular) | Single repo (conditional resources) |
| **Managed identity support** | N/A (uses STS/OIDC) | Preview (9 managed identities) |

---

## Recommendations

### For Customers

1. **Start with ROSA HCP** if on AWS — zero-egress is simpler and cheaper to implement due to the hosted control plane and VPC Endpoint model.
2. **Budget for Azure Firewall** if on ARO — it's a non-trivial cost (~$900/mo) that customers often overlook.
3. **Use VPN for developer access** — both AWS Client VPN and Azure P2S VPN provide much better developer experience than SSH tunneling through bastion hosts.
4. **Plan for DNS** — private clusters require careful DNS configuration. Route53 Private Hosted Zone associations (AWS) or `/etc/hosts` entries (Azure) are needed for cross-VPC/VPN access.

### For SAs/Architects

1. **Know the VPC Endpoint requirements** — customers often ask "what endpoints do I need?" The answer differs between ROSA HCP (4-6 endpoints) and traditional ROSA (more endpoints needed since control plane is in-VPC).
2. **Test egress thoroughly** — deploy a sample application and verify it can pull images, authenticate, and access required services.
3. **Document firewall rules** — for ARO, maintain a living document of required FQDNs. These change with OpenShift versions.
4. **Consider hub-spoke for production** — single VNet works for demos but production ARO should use hub-spoke architecture.

---

## References

- [ROSA Zero-Egress Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/)
- [ARO Egress Restriction Guide](https://learn.microsoft.com/en-us/azure/openshift/howto-restrict-egress)
- [ARO Private Cluster Guide](https://learn.microsoft.com/en-us/azure/openshift/howto-create-private-cluster-4x)
- [AWS VPC Endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints.html)
- [Azure P2S VPN Overview](https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-about)
- [ROSA CLI Reference](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/rosa_cli/rosa-get-started-cli)
