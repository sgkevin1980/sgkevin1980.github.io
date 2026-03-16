---
layout: default
title: "Zero-Egress Clusters on ROSA HCP and ARO"
date: 2026-03-16
---

# Zero-Egress Clusters on ROSA HCP and ARO

## A Practical Comparison

**Author:** Kevin Ye
**Date:** March 2026

---

## Introduction

Many customers in regulated industries (financial services,
government, healthcare) require clusters with no internet-bound
egress traffic. This article shares practical learnings from
provisioning zero-egress clusters on both **ROSA HCP (AWS)**
and **ARO (Azure)**, comparing the architecture, prerequisites,
access patterns, and gotchas encountered along the way.

**What is zero-egress?** A zero-egress cluster has no outbound
internet connectivity. Worker nodes cannot reach the public
internet — all communication with cloud services happens
through private endpoints (AWS VPC Endpoints or Azure Service
Endpoints). This is distinct from a "private cluster" which
only makes the API/ingress private but may still allow outbound
internet traffic via NAT Gateway or Load Balancer.

---

## Architecture Comparison at a Glance

| Aspect | ROSA HCP | ARO |
|--------|----------|-----|
| **Control Plane** | Red Hat hosted | In customer VNet |
| **Egress Control** | No NAT GW + VPC Endpoints | Azure FW + UDR |
| **Private Endpoints** | S3, STS, ECR, CloudWatch | Storage, ACR |
| **Subnets** | Private only | Master, Worker, FW, Jump |
| **Private API** | `--private` | `api_server_profile=Private` |
| **Private Ingress** | `--default-ingress-private` | `ingress_profile=Private` |
| **Access** | Client VPN or VPC Peering | P2S VPN or sshuttle |
| **Complexity** | Moderate | Higher (FW adds cost) |

---

## ROSA HCP Zero-Egress

### How It Works

ROSA HCP's zero-egress mode is straightforward because the
control plane runs in Red Hat's infrastructure, not in the
customer VPC. The customer VPC only contains worker nodes,
which communicate with AWS services through VPC Endpoints.

**Architecture diagram:**
```
     +------------------------+
     | Red Hat Managed Infra  |
     | (Control Plane via     |
     |  AWS PrivateLink)      |
     +-----------+------------+
                 | PrivateLink
  X No IGW      | (private)
  X No NAT GW   |
                 v
+==========================================+
| Customer VPC (10.0.0.0/16)               |
| Private Subnets Only                     |
|                                          |
| +------------+ +------------+ +--------+ |
| | Subnet AZ-a| | Subnet AZ-b| | Sub    | |
| | 10.0.0.0/18| | 10.0.64/18 | | AZ-c   | |
| |            | |            | |        | |
| | +--------+ | | +--------+ | |+------+| |
| | |Worker  | | | |Worker  | | ||Worker|| |
| | |Node    | | | |Node    | | |+------+| |
| | +--------+ | | +--------+ | |        | |
| |            | |            | |        | |
| | tag:       | | tag:       | | tag:   | |
| | internal-  | | internal-  | | int-   | |
| | elb=1      | | elb=1      | | elb=1  | |
| +------------+ +------------+ +--------+ |
|                                          |
| +-- VPC Endpoints ----------------------+|
| |                                       ||
| | +-----------+ +-----------+ +-------+ ||
| | |S3 Gateway | |STS Intf   | |ECR API| ||
| | |FREE       | |~$7/mo     | |~$7/mo | ||
| | +-----------+ +-----------+ +-------+ ||
| |                                       ||
| | +-----------+ +-----------+ +-------+ ||
| | |ECR DKR   | |CW Logs    | |CW Mon | ||
| | |~$7/mo    | |~$7/mo     | |~$7/mo | ||
| | +-----------+ +-----------+ +-------+ ||
| +---------------------------------------+|
|                                          |
| +-- AWS Client VPN (optional) ----------+|
| | Client CIDR: 10.100.0.0/22           ||
| | Split tunnel: enabled                ||
| +--+------------------------------------+|
|    ^                                     |
+====|=====================================+
     |
     | OpenVPN tunnel
     |
 +---+----------+
 | Laptop       |
 | (Developer)  |
 +--------------+
```

### Prerequisites

1. **VPC with private subnets only** — no public
   subnets, no NAT Gateway
2. **VPC Endpoints** (minimum required):

| Service | Type | Cost |
|---------|------|------|
| `s3` | Gateway | Free |
| `sts` | Interface | ~$7/mo |
| `ecr.api` | Interface | ~$7/mo |
| `ecr.dkr` | Interface | ~$7/mo |

Optional for observability:

| Service | Type | Purpose |
|---------|------|---------|
| `logs` | Interface | CloudWatch Logs |
| `monitoring` | Interface | CloudWatch Mon |

3. **Subnet tagging**:
   `kubernetes.io/role/internal-elb = 1`
4. **VPC Endpoint SG**: Allow HTTPS (443) from VPC CIDR

> **Important**: `elasticloadbalancing` and `ec2` endpoints
> are NOT required for ROSA HCP — the control plane runs
> in Red Hat's infrastructure.

### Cluster Creation

The critical flags are `--private` (API via PrivateLink)
and `--default-ingress-private` (internal LB for ingress):

```bash
rosa create cluster \
  --cluster-name=my-ze-cluster \
  --mode=auto --hosted-cp \
  --operator-roles-prefix my-ze-cluster \
  --oidc-config-id "<oidc-config-id>" \
  --subnet-ids="<subnet-1>,<subnet-2>,<subnet-3>" \
  --region <region> \
  --machine-cidr 10.0.0.0/16 \
  --private \
  --default-ingress-private
```

### Terraform Approach (Validated Pattern)

```
Repo structure:
===============

validated-pattern/
+-- Makefile            # make cluster.<name>.<op>
+-- Makefile.cluster    # Cluster operations
+-- terraform/          # Root Terraform config
|   +-- 10-main.tf      # Modules by network_type
|   +-- 01-variables.tf
|   +-- 90-outputs.tf
+-- modules/
|   +-- infrastructure/
|       +-- network-private/  # Zero-egress
|       |   +-- 10-main.tf    # VPC, subnets,
|       |                     # endpoints, SGs
|       +-- network-public/   # (not used)
+-- clusters/
|   +-- egress-zero/          # Cluster config
|   |   +-- terraform.tfvars
|   +-- public/
|       +-- terraform.tfvars
+-- scripts/
    +-- cluster/    # init/plan/apply/destroy
    +-- vpn/        # VPN start/stop/status
    +-- tunnel/     # sshuttle (deprecated)
```

The validated pattern uses a modular approach:

- `network_type = "private"` — private subnets only
- `zero_egress = true` — no NAT GW, strict SGs
- `private = true` — API via PrivateLink

Key Terraform configuration:

```hcl
cluster_name = "my-ze-cluster"
network_type = "private"
zero_egress  = true
private      = true
region       = "<region>"
vpc_cidr     = "10.0.0.0/16"

# Access: AWS Client VPN
enable_client_vpn     = true
vpn_client_cidr_block = "10.100.0.0/22"
vpn_split_tunnel      = true
```

The network module automatically:
- Creates VPC with private subnets only
- Provisions all required VPC Endpoints
- Applies strict security groups
- Tags subnets for internal ELB

### Step-by-Step: Deploy with Terraform

#### Prerequisites

- AWS CLI configured and authenticated
- ROSA CLI installed (`rosa login`)
- Terraform CLI (>= 1.x)
- `oc` CLI for cluster access

#### Step 1: Review the cluster config

```bash
cd validated-pattern
ls clusters/
# Available: egress-zero, public, etc.
```

Example `clusters/egress-zero/terraform.tfvars`:

```hcl
cluster_name = "my-ze-cluster"

# Network Configuration
network_type = "private"
zero_egress  = true
private      = true
region       = "<region>"
vpc_cidr     = "10.0.0.0/16"

# AWS Client VPN
enable_client_vpn         = true
vpn_client_cidr_block     = "10.100.0.0/22"
vpn_split_tunnel          = true
vpn_session_timeout_hours = 12

# Cluster Topology
multi_az              = true
default_instance_type = "m5.xlarge"
openshift_version     = "4.19.24"

# Network CIDRs
service_cidr = "172.30.0.0/16"
pod_cidr     = "10.128.0.0/14"
host_prefix  = 23
```

#### Step 2: Initialize

```bash
make cluster.egress-zero.init
```

#### Step 3: Plan and review

```bash
make cluster.egress-zero.plan
```

Review the plan — you should see:
- VPC with private subnets only
- VPC Endpoints (S3, STS, ECR, CloudWatch)
- Security groups with restricted egress
- ROSA HCP cluster with `private = true`
- AWS Client VPN endpoint (if enabled)

#### Step 4: Apply

```bash
make cluster.egress-zero.apply
```

Cluster creation takes ~15-25 minutes.

#### Step 5: Connect via VPN

```bash
# Show VPN config
make cluster.egress-zero.vpn-config

# Start VPN tunnel
make cluster.egress-zero.vpn-start

# Verify VPN
make cluster.egress-zero.vpn-status
```

#### Step 6: Login

```bash
# Show endpoints and credentials
make cluster.egress-zero.show-endpoints
make cluster.egress-zero.show-credentials

# Login via oc CLI
make cluster.egress-zero.login
```

#### Step 7: (Optional) Bootstrap GitOps

```bash
make cluster.egress-zero.bootstrap
```

#### Cleanup

```bash
# Sleep (preserves DNS, IAM, secrets)
make cluster.egress-zero.sleep

# Or fully destroy
make cluster.egress-zero.destroy
```

### Zero-Egress Security Groups

In zero-egress mode, SGs are locked down:

**VPC Endpoint SG:**
- Inbound: HTTPS (443) from VPC CIDR
- Outbound: None

**Worker Node SG:**
- Inbound: All traffic from VPC CIDR
- Outbound: HTTPS (443) to VPC CIDR only,
  DNS (53 UDP/TCP) to VPC CIDR only

### Access Patterns

Since the cluster has no public endpoints:

1. **AWS Client VPN** (recommended)
2. **VPC Peering + Bastion**
3. **Route53 Private Hosted Zone association**

```
Option 1: AWS Client VPN (Recommended)
=======================================

+--------+  OpenVPN  +-------------+  private  +-------+
| Laptop |--------->| Client VPN  |---------->| ROSA  |
|        | split    | Endpoint    |  subnet   | HCP   |
+--------+ tunnel   +-------------+           | API   |
                                              | Apps  |
                                              +-------+

Option 2: VPC Peering + Bastion
================================

+--------+   +--------------+  VPC Peering  +-------+
| Laptop |-->| Bastion VPC  |<============>| ROSA  |
| RDP/   |   | +----------+ | Route tables | VPC   |
| SSH    |   | | Bastion  | | SG rules +   | API   |
+--------+   | | Host     | | R53 PHZ      | Apps  |
             | +----------+ |              +-------+
             +--------------+
```

### Gotchas and Lessons Learned

1. **Must use BOTH `--private` AND
   `--default-ingress-private`**: Using only `--private`
   causes ingress to attempt a public LB, which fails
   with "Must have at least one public subnet."

2. **Subnet tagging is critical**: Without
   `kubernetes.io/role/internal-elb=1`, the internal
   LB for ingress stays in `<pending>` state.

3. **DNS across VPC peering**: Associate the ROSA
   cluster's Route53 private hosted zones with the
   bastion VPC for DNS resolution.

4. **SG rules for peered VPC**: Add ingress rules to
   both VPC endpoint SG and default ROSA SG for
   bastion VPC CIDR.

5. **VPC Endpoints cost**: ~$7-10/mo each. Budget
   ~$30-60/mo for 4-6 endpoints.

---

## ARO Zero-Egress

### How It Works

ARO's zero-egress approach is more involved because:
- Control plane runs **inside the customer VNet**
- Egress restriction uses **Azure Firewall** + UDR
- Firewall needs explicit FQDN rules

**Architecture diagram:**
```
                 Internet
                    ^
                    | (only FW has public IP;
                    |  nodes can't reach internet
                    |  unless FW rules allow it)
                    |
+===================|======================+
| Azure VNet (10.0.0.0/20)                |
|                   |                      |
| +-----------------+-------------------+ |
| | AzureFirewallSubnet (10.0.6.0/23)   | |
| |                                     | |
| | +---------------------+            | |
| | | Azure Firewall      | App Rules: | |
| | | Pub IP: x.x.x.x     | *.azurecr  | |
| | | Priv IP: 10.0.6.4  <-- *.quay.io | |
| | +---------------------+ *.redhat   | |
| |        ^                            | |
| +--------|---+------------------------+ |
|          |   |                          |
|   UDR:0/0   | UDR:0/0                  |
|   ->10.0.6.4| ->10.0.6.4               |
|          |   |                          |
| +--------++ | +----------+ +---------+ |
| | Master  | | | Worker   | | Jumphost| |
| | Subnet  | | | Subnet   | | Subnet  | |
| | 10.0.0  | | | 10.0.2   | | 10.0.4  | |
| | .0/23   | | | .0/23    | | .0/23   | |
| |         | | |          | |         | |
| | +--+--+ | | | +--+--+ | | +-----+ | |
| | |CP|CP| | | | |WK|WK| | | |Jump | | |
| | +--+--+ | | | +--+--+ | | |host | | |
| | +--+    | | | +--+    | | |VM   | | |
| | |CP|    | | | |WK|    | | +-----+ | |
| | +--+    | | | +--+    | |         | |
| |         | | |          | |         | |
| | SvcEndpt| | | SvcEndpt | |         | |
| | Stor,ACR| | | Stor,ACR | |         | |
| +---------+ | +----------+ +---------+ |
|             |                           |
| +-----------+--------------------------+|
| | (Optional) PE Subnet (10.0.8.0/23)  ||
| | +-------------+                     ||
| | | ACR Private |  DNS: *.azurecr.io  ||
| | | Endpoint    |                     ||
| | +-------------+                     ||
| +--------------------------------------+|
|                                         |
| +-- GatewaySubnet (10.0.0.64/27) ------+|
| | +-------------+                      ||
| | | VPN Gateway | P2S VPN: OpenVPN     ||
| | | (VpnGw1)    | Pool: 172.16.0.0/24  ||
| | +-------------+ EKU: clientAuth!     ||
| +--+-----------------------------------+|
|    ^                                    |
+=====|====================================+
      |
      | OpenVPN / Tunnelblick
      |
  +---+---------+
  | Laptop      |
  | (Developer) |
  +-------------+
```

### Prerequisites

1. **Azure Firewall** with a public IP
2. **Route Table** with UDR:
   `0.0.0.0/0 -> VirtualAppliance (FW IP)`
3. **Firewall Application Rules** for FQDNs
4. **Service Endpoints** on subnets:
   `Microsoft.Storage`, `Microsoft.ContainerRegistry`
5. **Cluster flag**:
   `outbound_type = "UserDefinedRouting"`

### Firewall Rules Required

**Azure-specific:**
- `*.azurecr.io`, `*.azure.com`
- `login.microsoftonline.com`
- `*.windows.net`
- `*.ods.opinsights.azure.com`
- `*.oms.opinsights.azure.com`
- `*.monitoring.azure.com`

**Red Hat / OpenShift:**
- `registry.redhat.io`, `*.registry.redhat.io`
- `registry.access.redhat.com`
- `*.quay.io`, `quay.io`, `cdn.quay.io`
- `cert-api.access.redhat.com`
- `api.openshift.com`, `mirror.openshift.com`
- `sso.redhat.com`
- `*.redhat.com`, `*.openshift.com`

**Docker (if needed):**
- `*cloudflare.docker.com`
- `*registry-1.docker.io`
- `auth.docker.io`

### Terraform Approach

```
Repo structure:
===============

terraform-aro/
+-- Makefile          # make create-zero-egress
+-- 00-terraform.tf   # Provider config
+-- 01-variables.tf   # All variables
+-- 02-locals.tf      # Computed locals
+-- 03-data.tf        # Existing RG, VNet
+-- 10-network.tf     # NSGs
+-- 11-egress.tf      # FW + UDR (conditional)
+-- 20-iam.tf         # SP / managed identities
+-- 30-jumphost.tf    # Bastion (conditional)
+-- 40-acr.tf         # Private ACR (conditional)
+-- 50-cluster.tf     # ARO cluster
+-- 90-outputs.tf     # URLs, credentials
+-- modules/
|   +-- aro-permissions/  # SP/MI module
+-- terraform.tfvars      # Your config
```

ARO uses conditional resources:

```hcl
api_server_profile      = "Private"
ingress_profile         = "Private"
restrict_egress_traffic = true
```

When `restrict_egress_traffic = true`:
- Azure Firewall + subnet created
- Route table with UDR created
- Application rules added for FQDNs
- Jumphost VM auto-created

### Step-by-Step: Deploy with Terraform

#### Prerequisites

- Azure CLI (`az`) installed and logged in
- Terraform CLI (>= 1.12)
- `oc` CLI for cluster access
- Existing Azure RG, VNet, and subnets
- Red Hat pull secret

#### Step 1: Prepare the existing network

```bash
cd terraform-aro

# Add service endpoints to subnets
make prep-subnets
```

Or manually:

```bash
az network vnet subnet update \
  -g <resource-group> \
  --vnet-name <vnet-name> \
  -n <master-subnet> \
  --service-endpoints \
  Microsoft.Storage \
  Microsoft.ContainerRegistry

az network vnet subnet update \
  -g <resource-group> \
  --vnet-name <vnet-name> \
  -n <worker-subnet> \
  --service-endpoints \
  Microsoft.Storage \
  Microsoft.ContainerRegistry
```

#### Step 2: Create terraform.tfvars

```bash
make tfvars
# Then edit terraform.tfvars
```

Key variables for zero-egress:

```hcl
# Existing Azure resources
resource_group_name       = "<resource-group>"
vnet_name                 = "<vnet-name>"
control_plane_subnet_name = "<master-subnet>"
machine_subnet_name       = "<worker-subnet>"

# Cluster configuration
cluster_name    = "my-aro-ze"
location        = "<azure-region>"
subscription_id = "<subscription-id>"

# Zero-egress (all four required together)
api_server_profile      = "Private"
ingress_profile         = "Private"
restrict_egress_traffic = true
outbound_type           = "UserDefinedRouting"

# Firewall subnet CIDR
aro_firewall_subnet_cidr_block = "10.0.6.0/23"

# Access method
create_jumphost = false

# Pull secret
pull_secret_path = "~/Downloads/pull-secret.txt"
```

> **Important**: The four zero-egress variables must
> all be set together. Missing any one results in a
> broken configuration.

#### Step 3: Initialize and deploy

```bash
# All-in-one (prep-subnets + init + plan + apply)
make create-zero-egress
```

Or step by step:

```bash
make init
terraform plan -out aro.plan
terraform apply aro.plan
```

ARO creation takes **35-50 minutes**.

#### Step 4: Access the cluster

**Option A: Jumphost** (if `create_jumphost = true`)

```bash
JUMP_IP=$(terraform output -raw public_ip)

# SSH tunnel
sudo ssh \
  -L 6443:api.<domain>.aroapp.io:6443 \
  -L 443:console-openshift-console\
.apps.<domain>.aroapp.io:443 \
  aro@$JUMP_IP

# Or sshuttle
sshuttle --dns -NHr aro@$JUMP_IP \
  10.0.0.0/20 --daemon
```

**Option B: Azure P2S VPN** (see below)

#### Step 5: Login

```bash
make show_credentials
make login

# Or manually:
API_URL=$(terraform output -raw api_url)
oc login $API_URL \
  --username=kubeadmin \
  --password=<password> \
  --insecure-skip-tls-verify=true
```

#### Cleanup

```bash
# Service principal cluster
make destroy

# Managed identity cluster
make destroy-managed-identity
```

### Azure P2S VPN for Private ARO Access

```
Azure P2S VPN Access Flow
=========================

+--------+              +----------------+
| Laptop |   OpenVPN    | VPN Gateway    |
| (macOS)|  Tunnelblick | (VpnGw1)      |
|        |------------>| GatewaySubnet  |
+--------+              | 10.0.0.64/27   |
    |                   +------+---------+
    | IP: 172.16.0.x          |
    |                         | same VNet
    |    +--------------------+
    |    |
    |    v
    |  +------------------------------+
    |  | ARO VNet                     |
    |  |                              |
    |  | API ---> api.<dom>:6443      |
    |  | Web ---> *.apps.<dom>:443    |
    |  | OAuth -> oauth-*:443         |
    |  +------------------------------+
    |
    | DNS: /etc/hosts required
    | (P2S doesn't forward private DNS)
    |
    +--> api.<dom>.<region>.aroapp.io
    |     -> <API private IP>
    +--> console-openshift-console
    |    .apps.<dom>.<region>.aroapp.io
    |     -> <Ingress private IP>
    +--> oauth-openshift
         .apps.<dom>.<region>.aroapp.io
          -> <Ingress private IP>

Certificate Chain:
+----------+  signs  +--------------+
| Root CA  |-------->| Client Cert  |
| (upload  |         | MUST include |
|  to GW)  |         | EKU:         |
+----------+         | clientAuth   |
                     +--------------+
```

**Setup steps:**

1. **Create GatewaySubnet** (minimum /27)
2. **Deploy VPN Gateway** (VpnGw1, ~30-45 min)
3. **Generate certs**: Root CA + Client cert with
   `extendedKeyUsage = clientAuth`
4. **Configure P2S**: Upload root cert, set client
   pool (e.g., `172.16.0.0/24`), OpenVPN protocol
5. **Connect**: Import `.ovpn` into Tunnelblick

> **Key gotcha**: Client cert MUST include
> `extendedKeyUsage = clientAuth`. Without it, VPN
> Gateway silently rejects with a connection-reset
> after TLS handshake — no error, just a reset.

### Managed Identities (Preview)

ARO supports managed identities as an alternative
to service principals:
- No credential management (no SP secrets to rotate)
- Creates 9 user-assigned managed identities
- Requires ARM template deployment
- **Limitation**: NSGs cannot be attached to subnets
  (preview limitation)

### Gotchas and Lessons Learned

1. **Azure Firewall cost**: ~$900/month. Significant
   for lab/dev. Evaluate if justified.

2. **Firewall rule maintenance**: Required FQDNs can
   change with ARO/OpenShift updates. Monitor the
   [official docs][aro-egress] for updates.

3. **VPN Gateway provisioning**: 30-45 minutes.
   Use `--no-wait` with monitoring.

4. **VPN certificate EKU**: Not well-documented.
   Missing it causes silent connection resets.

5. **DNS with VPN**: P2S VPN doesn't auto-configure
   DNS forwarding. Need `/etc/hosts` entries.

6. **Single VNet**: Current approach has firewall in
   same VNet. Hub-spoke is better for production.

---

## Side-by-Side Summary

### Traffic Flow Comparison

```
ROSA HCP                    ARO
Zero-Egress                 Zero-Egress
===========                 ===========

Worker Node                 Worker Node
    |                           |
    | port 443                  | all egress
    | to VPC CIDR               | -> UDR
    v                           v
+--------------+          +--------------+
| VPC Endpoint |          | Azure FW     |
| (per-svc)    |          | (FQDN filter)|
|              |          |              |
| S3 -> S3 Svc|          | *.quay.io  --+-> Net
| STS-> STS   |          | *.azurecr  --+  (filtered)
| ECR-> ECR   |          | *.redhat   --+
+--------------+          +--------------+
     |                         |
     X No Internet             | Allowed FQDNs
     X (no NAT/IGW)            | pass through

Control Plane:             Control Plane:
Red Hat Managed            In-VNet
(PrivateLink)              (Master Subnet)

Cost: ~$30-60/mo           Cost: ~$900+/mo
(VPC Endpoints)            (Azure FW Std)
```

| Category | ROSA HCP | ARO |
|----------|----------|-----|
| **Egress mechanism** | No NAT + VPC Endpoints | Azure FW + UDR |
| **Monthly cost** | ~$30-60 | ~$900+ |
| **Complexity** | Lower | Higher |
| **Subnets** | Private (1/AZ) | Master, Worker, FW, Jump |
| **FQDN allowlist?** | No | Yes |
| **Control plane** | Red Hat managed | Customer VNet |
| **Best access** | Client VPN | P2S VPN / sshuttle |
| **Managed identity** | N/A (STS/OIDC) | Preview |

---

## Recommendations

### For Customers

1. **Start with ROSA HCP** if on AWS — simpler and
   cheaper due to hosted control plane.
2. **Budget for Azure Firewall** if on ARO —
   ~$900/mo is often overlooked.
3. **Use VPN for dev access** — much better than SSH
   tunneling through bastion hosts.
4. **Plan for DNS** — Route53 PHZ associations (AWS)
   or `/etc/hosts` entries (Azure) are needed.

### For SAs/Architects

1. **Know VPC Endpoint requirements** — differs
   between ROSA HCP (4-6) and traditional ROSA.
2. **Test egress thoroughly** — verify image pulls,
   auth, and required service access.
3. **Document firewall rules** — maintain a living
   doc of required FQDNs for ARO.
4. **Hub-spoke for production** — single VNet works
   for demos but not production ARO.

---

## References

- [ROSA Documentation][rosa-docs]
- [ARO Egress Restriction Guide][aro-egress]
- [ARO Private Cluster Guide][aro-private]
- [AWS VPC Endpoints][vpc-endpoints]
- [Azure P2S VPN Overview][azure-vpn]
- [ROSA CLI Reference][rosa-cli]

[rosa-docs]: https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/
[aro-egress]: https://learn.microsoft.com/en-us/azure/openshift/howto-restrict-egress
[aro-private]: https://learn.microsoft.com/en-us/azure/openshift/howto-create-private-cluster-4x
[vpc-endpoints]: https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints.html
[azure-vpn]: https://learn.microsoft.com/en-us/azure/vpn-gateway/point-to-site-about
[rosa-cli]: https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/rosa_cli/rosa-get-started-cli
