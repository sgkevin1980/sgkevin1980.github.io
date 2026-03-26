---
layout: default
title: "Azure Red Hat OpenShift (ARO) Design Considerations"
date: 2026-03-26
---


# Azure Red Hat OpenShift (ARO) — Design Considerations

---

## Table of Contents

1. [Deployment Model](#1-deployment-model)
2. [Network Planning](#2-network-planning)
3. [Access Control & Identity](#3-access-control--identity)
4. [Scalability & High Availability](#4-scalability--high-availability)
5. [Storage Integration](#5-storage-integration)
6. [Security](#6-security)
7. [Logging & Monitoring](#7-logging--monitoring)
8. [Disaster Recovery & Backup](#8-disaster-recovery--backup)
9. [Day 2 Operations](#9-day-2-operations)
10. [Shared Responsibility Model](#10-shared-responsibility-model)
11. [Cost Management](#11-cost-management)

---

## 1. Deployment Model

### Options

| Model | API Server | Ingress | Outbound | Use Case |
|-------|-----------|---------|----------|----------|
| **Public** | Public IP | Public LB | Public LB | Dev/test, non-sensitive workloads |
| **Private** | Private IP (control plane subnet) | Internal LB | Public LB (default) | Production, regulated workloads |
| **Private without Public IP** | Private IP | Internal LB | UDR (User Defined Routing) | Highest security, air-gapped/disconnected |

### Recommendation for Regulated / Enterprise Environments

- **Private cluster without public IP** (`--apiserver-visibility Private --ingress-visibility Private --outbound-type UserDefinedRouting`)
- API server is only accessible from within the VNET or peered networks
- Egress traffic is routed through Azure Firewall or NVA via UDR — no public IP is provisioned on the cluster
- Access to the OpenShift console and API requires a jump box, VPN, or Azure Bastion within the peered network
- Custom domain is recommended (e.g., `aro.example.com`) with enterprise-managed TLS certificates for both ingress and API server

### Key Decisions

| Decision | Options | Recommendation |
|----------|---------|----------------|
| Outbound type | LoadBalancer / UserDefinedRouting | **UDR** — required for no public IP |
| Custom domain | Default (`*.aroapp.io`) / Custom | **Custom domain** — enterprise branding and certificate control |
| Pull secret | With / Without Red Hat pull secret | **With** — enables Operator Hub and Red Hat registry access |
| Deployment method | Azure Portal / CLI / Terraform / ARM | **Terraform** — infrastructure-as-code, repeatable, auditable |
| Subscription model | Single / Separate for Prod & Non-Prod | **Separate subscriptions** — per-subscription resource limits, security isolation, billing separation |
| Cluster per environment | Shared / Dedicated per env | **Dedicated clusters** for Prod and Non-Prod — workload isolation, independent upgrade cycles |

### Bastion / Jump Box

For a private cluster, a bastion host is required for administrative access:

- **Azure Bastion** in the Hub VNET, or a dedicated jump box VM in a peered subnet
- Jump box specs: 4 vCPU, 8 GB RAM, 100 GB disk, RHEL 9+
- Required CLIs on jump box: `az` (Azure CLI), `oc` (OpenShift CLI), `terraform`, `helm`
- Alternative: Azure VPN Point-to-Site for developer access to private API

### Cluster Limits

| Parameter | Limit |
|-----------|-------|
| Max worker nodes | 250 |
| Max pods per node | 250 |
| Control plane nodes | 3 (fixed, managed by ARO) |
| Min worker nodes | 3 |
| Cluster cannot be moved | Between regions or subscriptions after deployment |

---

## 2. Network Planning

### VNET & Subnet Design

ARO requires a VNET with two dedicated subnets (control plane and worker nodes). Both subnets must be minimum **/27**, but **/23** is recommended for production.

| Component | CIDR Example | Minimum Size | Notes |
|-----------|-------------|-------------|-------|
| ARO VNET | 10.100.0.0/16 | /22 | Can use existing VNET |
| Control plane subnet | 10.100.0.0/23 | /27 | Service endpoints: `Microsoft.ContainerRegistry` |
| Worker node subnet | 10.100.2.0/23 | /27 | Service endpoints: `Microsoft.ContainerRegistry` |
| Pod network (overlay) | 10.128.0.0/14 | /18 | Non-routable, internal to OVN-Kubernetes SDN. Each node gets a /23 (512 IPs) |
| Service network | 172.30.0.0/16 | /16 | Cluster-internal service IPs |

### Key Rules
- Pod and Service CIDRs **must not overlap** with the VNET address range or any peered network
- Pod CIDR minimum /18 — each node is allocated a /23 subnet (512 pod IPs per node, not changeable)
- Plan for growth: if you expect 50 worker nodes, the worker subnet needs at least 50 IPs + buffer

### Private Link Endpoints

For a regulated / enterprise environment, all Azure PaaS services should be accessed via Private Link endpoints to prevent data traversing the public internet:

| Azure Service | Private Endpoint Required | Subnet |
|--------------|--------------------------|--------|
| Azure Key Vault | Yes | Dedicated Private Endpoints subnet |
| Azure Container Registry | Yes | Dedicated Private Endpoints subnet |
| Azure Storage (Blob, Files) | Yes | Dedicated Private Endpoints subnet |
| Azure SQL / CosmosDB | Yes | Dedicated Private Endpoints subnet |
| Azure Monitor (Log Analytics) | Yes (AMPLS) | Dedicated Private Endpoints subnet |
| Azure Service Bus / Event Hub | Yes | Dedicated Private Endpoints subnet |

- Create a **dedicated subnet** (e.g., `/24`) in the spoke VNET for Private Link endpoints
- Register Private DNS Zones (e.g., `privatelink.vaultcore.azure.net`) in the Hub VNET and link to spoke
- Disable public access on all PaaS services

### Ingress Control

| Approach | Description | Recommendation |
|----------|-------------|----------------|
| Default OpenShift Router | HAProxy-based ingress controller, deployed on worker nodes by default | **Use as primary ingress** |
| Azure Application Gateway + WAF | L7 load balancer with Web Application Firewall, SSL offloading, URL-based routing | **Recommended for external-facing apps** — deploy in a dedicated subnet in the spoke VNET; WAF policy provides OWASP rule sets, bot protection, and rate limiting |
| Internal Load Balancer | Private ingress (`--ingress-visibility Private`) | **Required for private cluster** |
| Custom ingress controller | NGINX, Traefik, etc. | Only if specific features needed |

### Egress Control

For a private cluster with UDR:

- **Azure Firewall** or **NVA** in the Hub VNET controls all egress traffic
- Route table on worker/control plane subnets with default route (0.0.0.0/0) pointing to the firewall
- Required egress destinations (proxied through ARO service — no explicit firewall rules needed):
  - `arosvc.azurecr.io` (system container images)
  - `management.azure.com` (Azure APIs)
  - `login.microsoftonline.com` (authentication)
  - `monitor.core.windows.net` (Geneva monitoring)
- Optional egress destinations (require explicit firewall allow rules):
  - `registry.redhat.io`, `quay.io`, `cdn*.quay.io` — Red Hat container registry and Operator Hub
  - `registry.access.redhat.com`, `registry.connect.redhat.com` — certified operators
  - `mirror.openshift.com` — cluster updates
  - `api.openshift.com` — update graph
- For disconnected/air-gapped: mirror required images to an internal Azure Container Registry

### Connectivity to On-Premises & Other VNETs

| Connectivity | Method | Notes |
|-------------|--------|-------|
| On-premises | **Azure ExpressRoute** or Site-to-Site VPN | ExpressRoute recommended for regulated environments — dedicated, private connection |
| Other Azure VNETs | **VNET Peering** | ARO spoke peered to Hub VNET; Hub peers to other spokes |
| DNS resolution | Azure Private DNS Zones + conditional forwarding | Forward on-prem domains to on-prem DNS; ARO uses CoreDNS with configurable forwarding |

### Landing Zone Integration

- Deploy ARO in a **Hub-Spoke topology** aligned with Azure Landing Zone best practices
- ARO cluster in a dedicated spoke VNET
- Hub VNET contains: Azure Firewall, VPN/ExpressRoute Gateway, Azure Bastion, DNS
- Network Security Groups (NSGs) are auto-created and managed by ARO — **do not modify**
- Private Link is used by Microsoft/Red Hat SRE to manage the cluster

### Recommended Architecture — Private ARO with Internal & External Apps

The following architecture shows a private ARO cluster (no public IP) serving both **internal-only** apps (accessed by employees via corporate network) and **external-facing** apps (accessed by customers via the internet).

There are **two approaches** to expose internet-facing applications from a private ARO cluster:

#### Approach A: Custom Domain at Cluster Level

Set a custom domain during cluster installation using the `--domain` flag. This replaces the default `*.aroapp.io` domain for all cluster routes (console, API, application routes).

- Set at creation time: `az aro create ... --domain example.com`
- All routes use this domain: `*.apps.example.com`
- Organization manages DNS (Azure DNS or corporate DNS) and TLS certificates
- **Cannot be changed after cluster creation**
- Reference: https://cloud.redhat.com/experts/aro/custom-domain-private-cluster/

#### Approach B: Additional IngressController with Dedicated Domain

Create a second IngressController post-install with its own domain and its own Azure Load Balancer. This is the **recommended approach** for exposing specific internet-facing apps while keeping the default router for internal traffic.

- Default IngressController remains internal (corporate traffic)
- Additional IngressController gets a dedicated domain (e.g., `*.api.example.com`) and its own Load Balancer
- The additional IngressController's Load Balancer can be **External** (public IP) — even though the cluster itself has no public IP on its nodes. The `--ingress-visibility Private` flag only applies to the default IngressController
- Reference: https://cloud.redhat.com/experts/aro/additional-ingress-controller/

| Aspect | Approach A (Custom Domain) | Approach B (Additional IngressController) |
|--------|---------------------------|------------------------------------------|
| When to set | Cluster creation (cannot change later) | Post-install (can add/remove anytime) |
| Scope | All cluster routes (console, API, apps) | Only routes matching `routeSelector` |
| Internet exposure | Still needs a separate mechanism (App Gateway, Front Door, or additional IngressController) | Built-in — additional IngressController can have its own public LB |
| Flexibility | One domain for everything | Different domains for different app groups |
| Recommendation | Use for custom branding of the cluster domain | **Recommended** for exposing specific apps to the internet |

> **Note:** Approaches A and B are complementary, not mutually exclusive. You can set a custom domain at cluster creation (Approach A) AND create additional IngressControllers (Approach B) for specific internet-facing apps.

#### Architecture Diagram

```
                                    INTERNET
                                       │
                      ┌────────────────┼────────────────┐
                      │ (Option 1)     │                │ (Option 2)
                      │                │                │
             ┌────────▼────────┐       │       ┌────────▼────────┐
             │  Azure Front     │       │       │ Public DNS      │
             │  Door + WAF      │       │       │ (example.com)   │
             │  (global L7)     │       │       │                 │
             └────────┬─────────┘       │       └────────┬────────┘
                      │ Pvt Link        │                │
                      ▼                 │                ▼
             ┌──────────────┐           │   ┌───────────────────────┐
             │ App Gateway  │           │   │ Public LB             │
             │ + WAF v2     │           │   │ (from additional      │
             │ (optional)   │           │   │  IngressController)   │
             └──────┬───────┘           │   └───────────┬───────────┘
                    │                   │               │
                    ▼                   │               ▼
═══════════════════════════════════════════════════════════════════════
                            HUB VNET (10.0.0.0/16)
═══════════════════════════════════════════════════════════════════════
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌───────────┐
  │Azure Firewall│  │ VPN/Express  │  │Azure Bastion │  │ DNS       │
  │(10.0.1.0/26) │  │ Route GW     │  │(10.0.3.0/26) │  │ Forwarder │
  │              │  │(10.0.2.0/27) │  │              │  │           │
  │ • Egress     │  │              │  │ • Admin      │  │ • Private │
  │   filtering  │  │ • On-prem    │  │   access to  │  │   DNS     │
  │ • FQDN rules │  │   connect    │  │   jump box   │  │   Zones   │
  └──────┬───────┘  └──────────────┘  └──────────────┘  └───────────┘
         │ UDR (0.0.0.0/0)
         │
═══════════════════════════╤══════════════════════════════════════════
                           │ VNET Peering
═══════════════════════════╧══════════════════════════════════════════
                       SPOKE VNET (10.100.0.0/16)
═══════════════════════════════════════════════════════════════════════
                                       │
  ┌────────────────────────────────────────────────────────────────┐
  │                    ARO CLUSTER (Private, No Public IP)         │
  │                                                                │
  │  ┌─────────────────┐  ┌─────────────────────────────────────┐ │
  │  │ Control Plane    │  │ Worker Node Subnet (10.100.2.0/23) │ │
  │  │ Subnet           │  │                                     │ │
  │  │ (10.100.0.0/23)  │  │  ┌───────────┐  ┌───────────────┐  │ │
  │  │                  │  │  │ Workers   │  │ Infra Nodes   │  │ │
  │  │  • 3x Control    │  │  │ (general) │  │ (post-install)│  │ │
  │  │    Plane Nodes   │  │  │           │  │               │  │ │
  │  │  • API Server    │  │  │ • App     │  │ • Router(s)   │  │ │
  │  │    (Private IP)  │  │  │   pods    │  │ • Prometheus  │  │ │
  │  │                  │  │  │           │  │ • Logging     │  │ │
  │  │                  │  │  │           │  │ • Registry    │  │ │
  │  └─────────────────┘  │  └───────────┘  └───────────────┘  │ │
  │                        │                                     │ │
  │                        │  ┌─────────────────────────────┐    │ │
  │                        │  │ Default IngressController   │    │ │
  │                        │  │ Internal LB (10.100.2.x)    │    │ │
  │                        │  │ → internal apps only        │    │ │
  │                        │  └─────────────────────────────┘    │ │
  │                        │                                     │ │
  │                        │  ┌─────────────────────────────┐    │ │
  │                        │  │ Additional IngressController│    │ │
  │                        │  │ Public LB or Internal LB    │    │ │
  │                        │  │ → internet-facing apps      │    │ │
  │                        │  └─────────────────────────────┘    │ │
  │                        └─────────────────────────────────────┘ │
  └────────────────────────────────────────────────────────────────┘
                                       │
  ┌────────────────────────────────────────────────────────────────┐
  │ App Gateway Subnet (10.100.4.0/24)  — OPTIONAL                │
  │ ┌──────────────────────────────────────┐                      │
  │ │ Azure Application Gateway + WAF v2   │                      │
  │ │ • Backend pool → Internal LB IP      │                      │
  │ │ • WAF rules (OWASP, bot, rate limit) │                      │
  │ │ • Path-based routing to services     │                      │
  │ └──────────────────────────────────────┘                      │
  └────────────────────────────────────────────────────────────────┘
                                       │
  ┌────────────────────────────────────────────────────────────────┐
  │ Private Endpoints Subnet (10.100.5.0/24)                      │
  │  • Key Vault      • ACR        • Storage Account              │
  │  • Log Analytics   • SQL/Cosmos • Service Bus                 │
  └────────────────────────────────────────────────────────────────┘
                                       │
  ┌────────────────────────────────────────────────────────────────┐
  │ Jump Box Subnet (10.100.6.0/27)                               │
  │  • Admin VM (RHEL 9, oc/az/terraform/helm CLI)                │
  │  • Accessed via Azure Bastion from Hub                        │
  └────────────────────────────────────────────────────────────────┘
```

### Traffic Flows

**External-facing apps** — Two options depending on security requirements:

**Option 1: Additional IngressController with Public LB (simpler, no Front Door)**

```
Internet → Public DNS → Public LB (Additional IngressController)
  → OpenShift Router (external) → external-app pods
```

- Simplest approach — no extra Azure services required
- Additional IngressController creates its own Azure Public Load Balancer
- TLS terminated at the Router (edge or passthrough)
- Add Azure DDoS Protection Standard on the VNET for DDoS mitigation
- Suitable when WAF is not required or handled at application level

**Option 2: Front Door + App Gateway (enterprise-grade, WAF at edge)**

```
Internet → Azure Front Door (WAF, TLS, DDoS) → Private Link → App Gateway (WAF v2)
  → Internal LB (Additional IngressController) → OpenShift Router → external-app pods
```

- Azure Front Door provides global L7 load balancing, DDoS protection, and edge WAF
- Application Gateway provides regional WAF with OWASP rules and URL-based routing
- Both the additional IngressController and default IngressController use Internal LBs in this option
- End-to-end TLS: Front Door → App Gateway → Router → pod (re-encrypt or passthrough)
- Recommended for apps requiring WAF, global distribution, or regulatory-mandated edge security

**Internal-only apps** (e.g., staff portals, back-office systems):

```
Corporate network → ExpressRoute/VPN → Hub VNET → Peering → Spoke VNET
  → Internal LB (Default IngressController) → OpenShift Router → internal-app pods
```

- No internet exposure — only reachable from corporate network
- OpenShift Routes with `host: staff.internal.example.com` route to the correct service
- DNS: internal apps resolve via Azure Private DNS Zones linked to corporate DNS

**Admin / Developer access:**

```
Admin laptop → Azure Bastion → Jump Box VM → oc login https://api.aro.example.com:6443
```

- API server has no public IP — only accessible from within the VNET
- Developers can also use Azure VPN Point-to-Site for `oc` CLI access

### Choosing an Internet Exposure Option

| Criteria | Option 1: Public LB | Option 2: Front Door + App Gateway |
|----------|---------------------|-----------------------------------|
| **Complexity** | Low | High |
| **Cost** | Low (LB only) | High (Front Door + App Gateway) |
| **WAF** | No (unless added separately) | Yes (edge + regional WAF) |
| **DDoS protection** | Azure DDoS Protection Standard | Built into Front Door |
| **Global load balancing** | No (single region) | Yes (multi-region) |
| **TLS offloading layers** | 1 (Router) | 3 (Front Door → App Gateway → Router) |
| **Suitable for** | Internal APIs, B2B, limited internet exposure | Customer-facing portals, mobile apps, regulatory-mandated WAF |

> **Recommendation for regulated environments:** Start with **Option 1** (Public LB) for B2B APIs and internal-facing internet services. Use **Option 2** (Front Door + App Gateway) for customer-facing apps that require WAF and DDoS protection.

### Separating Internal and External Traffic

By default, ARO creates a single default IngressController (router) with one Internal Load Balancer (on a private cluster). To separate internal and external traffic, deploy an **additional IngressController** with its own domain and Load Balancer.

| IngressController | Domain | Load Balancer | Serves |
|-------------------|--------|---------------|--------|
| `default` | `*.apps.internal.example.com` | Internal LB (Private IP) | Internal apps — corporate access only |
| `external` | `*.apps.example.com` | Public LB (for Option 1) or Internal LB fronted by App Gateway (for Option 2) | Internet-facing apps |

```yaml
# Example: additional IngressController for external apps (Option 1 — Public LB)
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: external
  namespace: openshift-ingress-operator
spec:
  domain: apps.example.com
  replicas: 2
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: External           # creates a Public Azure LB
  routeSelector:
    matchLabels:
      exposure: external
  nodePlacement:                 # optional: place on infra nodes if created
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/infra: ""
    tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
```

```yaml
# Example: additional IngressController for external apps (Option 2 — Internal LB behind App Gateway)
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: external
  namespace: openshift-ingress-operator
spec:
  domain: apps.example.com
  replicas: 2
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: Internal           # Internal LB — App Gateway forwards to this
  routeSelector:
    matchLabels:
      exposure: external
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/infra: ""
    tolerations:
    - key: node-role.kubernetes.io/infra
      effect: NoSchedule
```

Application teams label their Routes to select the appropriate IngressController:

```yaml
# External-facing route
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: customer-api
  labels:
    exposure: external     # picked up by 'external' IngressController
spec:
  host: api.apps.example.com
  to:
    kind: Service
    name: customer-api-svc
  tls:
    termination: reencrypt
---
# Internal-only route (no exposure label → handled by 'default' IngressController)
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: staff-portal
spec:
  host: staff.apps.internal.example.com
  to:
    kind: Service
    name: staff-portal-svc
  tls:
    termination: edge
```

### When to Use a Custom Ingress Controller

The default OpenShift Router (HAProxy-based IngressController) handles the vast majority of use cases. However, there are scenarios where deploying a **custom ingress controller** (NGINX, Traefik, Kong, etc.) alongside or instead of the default router is warranted:

| Scenario | Why Custom Ingress | Recommended Controller |
|----------|-------------------|----------------------|
| **gRPC / HTTP/2 full support** | Default HAProxy router has limited gRPC streaming support; custom controllers provide native gRPC load balancing and header-based routing | NGINX Ingress, Envoy (via Gateway API) |
| **Advanced traffic management** | Canary releases with weighted traffic splitting (e.g., 90/10), A/B testing by header/cookie, circuit breaking, retry policies | Traefik, NGINX Ingress, Istio Gateway |
| **API Gateway features** | Rate limiting per API key, OAuth2/JWT validation at the ingress level, request/response transformation, API versioning | Kong Ingress, APISIX |
| **Multi-tenant isolation** | Dedicated ingress per tenant with independent TLS, rate limits, and WAF policies — beyond what routeSelector offers | NGINX Ingress (one instance per tenant namespace) |
| **Kubernetes Gateway API** | Organization wants to adopt the newer Gateway API standard instead of OpenShift Routes or Ingress resources | Envoy Gateway, Istio, Traefik |
| **TCP/UDP passthrough** | Non-HTTP protocols (databases, MQTT, custom TCP) that need L4 load balancing directly into the cluster | NGINX Ingress (TCP/UDP ConfigMap), MetalLB (bare-metal only — not applicable to ARO) |
| **Mutual TLS (mTLS) at ingress** | Client certificate authentication required at the edge (e.g., B2B API, mutual authentication compliance) | NGINX Ingress, Istio IngressGateway |

**When NOT to use a custom ingress controller:**

- Standard HTTP/HTTPS routing with path/host-based rules → default Router handles this
- TLS termination (edge, re-encrypt, passthrough) → default Router supports all modes
- Internal-only services → default Router with Internal LB is sufficient
- Basic rate limiting → use Azure Front Door or Application Gateway WAF instead
- If the only reason is "familiarity with NGINX" → the default Router works the same way via Routes

**Deployment considerations for custom ingress on ARO:**

- Custom ingress controllers run as regular pods on worker (or infra) nodes
- They create their own Azure Load Balancer (Internal or External) — on a private cluster, use Internal LB
- ARO's default Router remains active and manages OpenShift console and OAuth routes — **do not disable it**
- Resource overhead: each custom ingress controller consumes CPU/memory; avoid deploying multiple controllers unless justified
- If using both the default Router and a custom controller, clearly partition which domains/routes each handles to avoid conflicts

---

## 3. Access Control & Identity

### Authentication

| Method | Description | Recommendation |
|--------|-------------|----------------|
| **Microsoft Entra ID (Azure AD)** | OIDC integration with Entra ID | **Primary recommendation** — SSO, MFA, Conditional Access |
| OpenShift built-in (htpasswd) | Local user/password store | **Break-glass only** — emergency admin access |
| LDAP | Direct LDAP/AD bind | Alternative if Entra ID OIDC is not feasible |
| kubeadmin | Default cluster admin account | **Disable after Entra ID is configured** — or restrict and store credentials securely |

### Authorization (RBAC)

| Level | Mechanism | Notes |
|-------|-----------|-------|
| Cluster RBAC | OpenShift ClusterRoles & ClusterRoleBindings | Map Entra ID groups to OpenShift roles |
| Project/Namespace RBAC | OpenShift Roles & RoleBindings | Per-project access control |
| Azure RBAC | Azure role assignments on ARO resource | Controls who can manage the ARO resource in Azure (not in-cluster access) |

### Recommended RBAC Design

| Role | Entra ID Group | OpenShift Role | Description |
|------|---------------|----------------|-------------|
| Platform Admin | `SG-ARO-PlatformAdmin` | `cluster-admin` | Full cluster access (limited members) |
| Platform Operator | `SG-ARO-PlatformOps` | Custom `platform-operator` | Manage nodes, storage, monitoring — no app access |
| Application Admin | `SG-ARO-AppTeam-<name>` | `admin` (namespace-scoped) | Full control within assigned namespaces |
| Developer | `SG-ARO-Dev-<name>` | `edit` (namespace-scoped) | Deploy and manage apps in assigned namespaces |
| Viewer | `SG-ARO-Viewer` | `view` (namespace-scoped) | Read-only access for audit/compliance |

### Break-Glass Account

- Create a dedicated `break-glass` htpasswd user with `cluster-admin` role
- Store credentials in Azure Key Vault with access auditing enabled
- Use only when Entra ID is unavailable
- Monitor usage via OpenShift audit logs — alert on any break-glass login

### Service Accounts & Workload Identity

- Use OpenShift service accounts for pod-to-pod and pod-to-API communication
- **Azure Workload Identity** for pods that need to access Azure services (Key Vault, Storage, SQL, etc.) without storing credentials:
  - Federated identity credential: links a Kubernetes service account to an Azure Managed Identity
  - Pod mounts a projected service account token → exchanges it for an Azure AD token via OIDC
  - Eliminates stored secrets for Azure service access — critical for enterprise security posture
  - Configure per application namespace: one Managed Identity per application team
- Use **User-Assigned Managed Identities** (not system-assigned) for better lifecycle management

---

## 4. Scalability & High Availability

### Multi-AZ Deployment

- Deploy ARO across **3 Availability Zones** (where supported) for both control plane and worker nodes
- Control plane nodes are automatically distributed across AZs by ARO
- Worker nodes: specify `--worker-count` and ensure MachineSet per AZ for even distribution

### Node Sizing & Types

| Node Type | Suggested VM Size | Count | Notes |
|-----------|------------------|-------|-------|
| Control plane | Standard_D8s_v3 (8 vCPU, 32 GiB) | 3 | Managed by ARO — not configurable post-creation. SRE will resize if overutilized — keep 2x vCPU quota available |
| Worker (general) | Standard_D16s_v5 (16 vCPU, 64 GiB) | 6-18 | Application workloads. Size based on enterprise reference (16 vCPU, 64 GB per node) |
| Worker (infra) | Standard_D8s_v5 (8 vCPU, 32 GiB) | 3 | **Not created by default** — must create post-install via new MachineSets. Hosts router, monitoring, registry. Label as `node-role.kubernetes.io/infra` to avoid OCP subscription costs |
| Worker (infra-logging) | Standard_E8s_v5 (8 vCPU, 64 GiB) | 3 | **Not created by default** — optional dedicated nodes for logging stack (Loki/EFK) if high log volume. Memory-optimized |
| Worker (GPU) | Standard_NC series | As needed | For AI/ML workloads |

> **Reference sizing from enterprise deployment:**
> - Non-Prod: ~230 vCPU, ~456 GB memory → 18 worker nodes (D16, 16 vCPU, 64 GB) + 3 infra + 3 infra-logging
> - Prod: ~125 vCPU, ~403 GB memory → 12 worker nodes + dedicated DB workers + 3 infra + 3 infra-logging
> - Add 1 extra worker per AZ (3 total) as failover capacity

### Infrastructure Nodes

> **Important:** ARO does **not** create infrastructure nodes by default. All worker nodes created at provisioning time are general-purpose workers. Infrastructure nodes must be **manually created** post-installation by creating new MachineSets with the `infra` label and taints.

Infrastructure nodes run platform services and **do not count toward OpenShift subscription costs**:

| Component | Move to Infra Nodes | Notes |
|-----------|---------------------|-------|
| OpenShift Router (HAProxy) | Recommended | Ingress controller — runs on worker nodes by default |
| Prometheus / AlertManager | Recommended | Platform monitoring — runs on worker nodes by default |
| Grafana | Recommended | Dashboards |
| Loki / Elasticsearch | Recommended (or dedicated infra-logging) | Log aggregation — memory intensive |
| OpenShift Image Registry | Recommended | Internal registry — runs on worker nodes by default |

**Steps to create infrastructure nodes:**

1. Create new MachineSets (one per AZ) with the `infra` role label:
   ```yaml
   metadata:
     labels:
       node-role.kubernetes.io/infra: ""
   spec:
     taints:
     - key: node-role.kubernetes.io/infra
       effect: NoSchedule
   ```
2. Label the nodes: `oc label node <node> node-role.kubernetes.io/infra=`
3. Apply taint to prevent application pods from scheduling: `oc adm taint nodes <node> node-role.kubernetes.io/infra:NoSchedule`
4. Move platform components (router, monitoring, registry, logging) to infra nodes by updating their operator configs with `nodeSelector` and `tolerations`
5. Verify no OCP subscription cost applies — confirm with Red Hat support that nodes are correctly labelled

### Auto-Scaling

| Type | Mechanism | Notes |
|------|-----------|-------|
| **Cluster Autoscaler** | Automatically adds/removes worker nodes based on pending pods | Configure min/max per MachineSet |
| **Horizontal Pod Autoscaler (HPA)** | Scales pod replicas based on CPU/memory metrics | Per-deployment configuration |
| **Vertical Pod Autoscaler (VPA)** | Adjusts pod resource requests based on actual usage | Use in recommendation mode first |
| **KEDA (Event-Driven Autoscaling)** | Scales based on external event sources (queue length, Kafka lag, Prometheus metrics, cron schedules) | Install via OperatorHub; useful for enterprise batch processing and message-driven workloads |
| **Machine Health Check** | Automatically replaces unhealthy nodes | Configure for each MachineSet |

### Autoscaler Recommendations

```yaml
# Example: Cluster Autoscaler
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  podPriorityThreshold: -10
  resourceLimits:
    maxNodesTotal: 30
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    unneededTime: 5m
```

### Capacity Planning

- Reserve 10-20% headroom for burst workloads
- Set resource requests and limits on all workloads — autoscaler relies on pending pods
- Use `PodDisruptionBudgets` (PDB) for critical workloads during node scale-down, upgrades, or maintenance
  - Configure `minAvailable` or `maxUnavailable` to ensure service continuity
  - Avoid overly aggressive PDBs that block node drains during upgrades
- Apply `ResourceQuotas` per namespace to prevent any single team from consuming excessive cluster resources
- Apply `LimitRanges` per namespace to set default requests/limits for pods that don't specify them

### Pod Health & Self-Healing

- Configure **liveness probes** on all containers — Kubernetes restarts unresponsive pods automatically
- Configure **readiness probes** — prevents traffic from being routed to pods not yet ready to serve
- Configure **startup probes** for slow-starting applications (e.g., Java/Spring Boot) to avoid premature restarts
- ARO automatically repairs unhealthy nodes via Machine Health Checks

---

## 5. Storage Integration

### Azure Storage Options

| Storage Type | Azure Service | CSI Driver | Access Mode | Use Case |
|-------------|--------------|------------|-------------|----------|
| Block storage | Azure Managed Disks (Premium SSD, Ultra) | `disk.csi.azure.com` | RWO | Databases, stateful apps |
| File storage | Azure Files (Premium) | `file.csi.azure.com` | RWX | Shared config, CMS, logs |
| Blob storage | Azure Blob Storage | `blob.csi.azure.com` | RWX (via NFS/FUSE) | Large unstructured data, ML datasets |
| Object storage | Azure Blob (S3-compatible via MinIO) | N/A | API-based | Backups (Velero), image registry |

### StorageClass Configuration

| StorageClass | Provisioner | Reclaim Policy | Volume Binding | Notes |
|-------------|------------|----------------|----------------|-------|
| `managed-premium` (default) | `disk.csi.azure.com` | Delete | WaitForFirstConsumer | Premium SSD, recommended |
| `managed-csi-encrypted` | `disk.csi.azure.com` | Retain | WaitForFirstConsumer | With customer-managed encryption key |
| `azurefile-csi-premium` | `file.csi.azure.com` | Delete | Immediate | For RWX workloads |

### Recommendations for Regulated / Enterprise Environments

- Use **Premium SSD v2** or **Ultra Disk** for database workloads requiring high IOPS
- Enable **Customer-Managed Keys (CMK)** for disk encryption via Azure Key Vault
- Set reclaim policy to **Retain** for critical data volumes
- Use **Azure Files Premium** with private endpoints for shared storage
- For backup storage: Azure Blob with **immutable storage** for compliance
- **Private Endpoints** for all storage accounts — no public access

### Internal Image Registry

- ARO's built-in image registry uses Azure Blob Storage by default
- For regulated environments: configure to use a dedicated storage account with private endpoint and CMK encryption

---

## 6. Security

### Data Encryption

| Layer | Mechanism | Notes |
|-------|-----------|-------|
| **etcd encryption** | AES-CBC encryption at rest | Enabled by default in ARO |
| **Persistent volume encryption** | Azure Managed Disk encryption (SSE) | Default: platform-managed key. Recommend: **Customer-Managed Key (CMK)** via Key Vault |
| **Azure Files encryption** | SSE with CMK | Configure via storage account encryption settings |
| **In-transit encryption** | TLS 1.2+ for all API and ingress traffic | Default; enforce via ingress controller config |
| **Image registry** | Blob storage encryption with CMK | Configure dedicated storage account |

### Communication Encryption

| Communication Path | Encryption | Notes |
|-------------------|-----------|-------|
| Client → Ingress | TLS 1.2+ (enterprise cert) | Configure custom TLS certificate on ingress controller |
| Ingress → Pod | TLS (optional) | Enable re-encryption or passthrough routes |
| Pod → Pod | mTLS via Service Mesh (optional) | Deploy OpenShift Service Mesh for zero-trust networking |
| API client → API server | TLS 1.2+ | Custom certificate recommended |
| Node → Control plane | TLS (managed) | Handled by ARO |

### Secret Management

| Approach | Description | Recommendation |
|----------|-------------|----------------|
| OpenShift Secrets | Base64-encoded in etcd (encrypted at rest) | Acceptable for non-sensitive config |
| **Azure Key Vault CSI Provider** | Mount Key Vault secrets as volumes in pods | **Primary recommendation** — secrets never stored in etcd |
| External Secrets Operator | Sync secrets from Key Vault to OpenShift Secrets | Alternative if CSI mount is not suitable |
| Sealed Secrets | GitOps-friendly encrypted secrets | For secrets managed in Git |

### Governance & Admission Control

| Control | Implementation | Notes |
|---------|---------------|-------|
| **Azure Policy** | Azure Policy for ARO/AKS (limited preview) | Enforce Azure-level governance on cluster resources |
| **OPA Gatekeeper / ConstraintTemplates** | Install via OperatorHub | Enforce custom admission policies (e.g., deny privileged containers, enforce labels, restrict host paths) |
| **Container Image Governance** | Allowed registries policy | Only permit images from authorized registries (ACR, `registry.redhat.io`); deny pulls from Docker Hub or unapproved sources |
| **Resource label enforcement** | Gatekeeper constraint | Require cost-center and owner labels on all namespaces |
| **Namespace isolation** | Gatekeeper + Network Policies | Prevent cross-namespace resource access |

### Additional Security Controls

| Control | Implementation | Notes |
|---------|---------------|-------|
| **FIPS compliance** | `--fips` flag at cluster creation | Required for regulatory compliance; cannot be changed after creation |
| **Pod Security** | Pod Security Admission (PSA) / Security Context Constraints (SCC) | Enforce `restricted` SCC by default; only elevate for verified workloads |
| **Network Policies** | OVN-Kubernetes NetworkPolicy | Enforce micro-segmentation between namespaces; highly recommended for regulated environments |
| **Image security** | Red Hat Quay + Clair scanning, or Azure Defender for Containers | Scan all images before deployment; enforce image signing with Cosign/Sigstore |
| **Vulnerability scanning** | Microsoft Defender for Containers | Enable on the ARO cluster |
| **Compliance scanning** | OpenShift Compliance Operator | CIS benchmark profile, daily scan at 3 AM, 7-day report retention, auto-remediation disabled initially |
| **Advanced Cluster Security (ACS)** | Red Hat ACS (StackRox) | Runtime threat detection, network segmentation visibility, vulnerability management |
| **Audit logging** | OpenShift API audit logs | Forward to Azure Log Analytics for retention and alerting |
| **Confidential Containers** | OpenShift Sandboxed Containers (Kata) | GA since Nov 2025 — secure enclave isolation for sensitive workloads |
| **NSG / Private Link** | ARO-managed | Do not modify NSGs or remove Private Link — required for SRE access |

### Compliance Certifications

ARO inherits Azure compliance certifications:

| Certification | Status |
|--------------|--------|
| SOC 2 Type 2 | Yes |
| SOC 3 | Yes |
| ISO 27001 / 27017 / 27018 | Yes |
| PCI DSS | Yes (via Azure) |
| HIPAA | Yes |
| FedRAMP High | Yes |

### Break-Glass Account (Security)

- Separate from regular admin access
- Stored in Azure Key Vault with:
  - Access logging enabled
  - Alerts on secret read events
  - Rotation policy (quarterly)
- Only used when Entra ID / OIDC is down
- Documented procedure for break-glass use

---

## 7. Logging & Monitoring

### Monitoring Architecture

| Layer | Tool | Data Collected |
|-------|------|---------------|
| **Platform health** | ARO SRE (Microsoft + Red Hat Geneva) | Cluster health, node status, API availability — automatic, no user config needed |
| **Cluster metrics** | Built-in Prometheus + Grafana | CPU, memory, pod metrics, etcd, API server latency |
| **Azure-level monitoring** | Azure Monitor Container Insights | Node/pod performance, container logs, Kubernetes events |
| **Application metrics** | User Workload Monitoring (Prometheus) | Custom application metrics via ServiceMonitor |
| **Resource Health** | Azure Resource Health alerts | Cluster maintenance events, API unreachable alerts |

### Logging Architecture

| Log Source | Default Destination | Recommended Integration |
|------------|-------------------|----------------------|
| Container stdout/stderr | Cluster logging (Loki/Elasticsearch) | Forward to **Azure Log Analytics** via OpenShift Cluster Logging + Azure plugin |
| Audit logs (API server) | Local storage | Forward to **Azure Log Analytics** — critical for compliance |
| Infrastructure logs | Cluster logging | Forward to **Azure Log Analytics** |
| Security logs (OAuth, SCC violations) | Cluster logging | Forward to **Azure Sentinel** for SIEM |
| Node logs (journald) | Local node | Forward to Azure Log Analytics |

### Recommended Data Export

| Data Type | Export To | Retention | Notes |
|-----------|---------|-----------|-------|
| Audit logs | Azure Log Analytics | **365 days** (regulatory) | API audit events, authentication events |
| Container logs | Azure Log Analytics | **90 days** hot, archive to Blob | Application logs, error tracking |
| Platform metrics | Azure Monitor Metrics | **93 days** (default) | CPU, memory, network metrics |
| Security events | Azure Sentinel | **365 days** | OAuth events, policy violations, SCC violations |
| Alert history | Azure Monitor Alerts | **30 days** (default) | Extend via Action Groups + Log Analytics |

### Logging Storage Sizing (Reference)

Reference logging storage sizing:

| Component | Storage | Notes |
|-----------|---------|-------|
| Loki log storage | 3x 500 GB disks on infra-logging nodes | Adjust based on log volume |
| Loki S3/Blob backend | 1.5 TB | Long-term log storage |
| Prometheus PVC | 200 GB | Metrics retention |
| Thanos Ruler PVC | 200 GB | Multi-cluster metrics |
| Metrics retention | 90 days | Configurable |
| Log retention | 90 days (hot), archive to Blob | Regulatory: audit logs 365 days |

### Network Observability

- Enable **OVN-Kubernetes flow logging** for network traffic visibility between pods and namespaces
- Use **OpenShift Network Observability Operator** (eBPF-based) to collect flow logs without sidecar overhead
- Forward network flow data to Loki for querying and Grafana for dashboards
- Key use cases for regulated environments: detect unexpected cross-namespace traffic, identify external communication patterns, audit network policy effectiveness

### Key Alerts to Configure

| Alert | Condition | Severity |
|-------|-----------|----------|
| Node not ready | Node status != Ready for > 5 min | Critical |
| Pod crash loop | RestartCount > 5 in 10 min | High |
| etcd leader changes | > 3 leader changes in 1 hour | Critical |
| API server latency | p99 > 1s for > 5 min | High |
| PV usage | > 85% capacity | Warning |
| Certificate expiry | < 30 days to expiry | Warning |
| Break-glass login | Any htpasswd admin login | Critical |
| Cluster maintenance | Azure Resource Health signal | Info |

---

## 8. Disaster Recovery & Backup

### DR Strategy

| Scenario | Strategy | RPO | RTO |
|----------|---------|-----|-----|
| **Single AZ failure** | Multi-AZ deployment (3 AZs) | 0 | Automatic failover |
| **Full region failure** | Active-Passive in secondary region | < 1 hour | 2-4 hours |
| **Data corruption / accidental deletion** | Backup and restore | < 1 hour | 1-2 hours |
| **Cluster rebuild** | Infrastructure-as-Code (Terraform) + GitOps | < 4 hours | 4-8 hours |

### Backup Architecture

| Component | Backup Tool | Storage Target | Schedule | Retention |
|-----------|------------|---------------|----------|-----------|
| **Kubernetes resources** (deployments, configmaps, secrets) | **Velero** + Azure Blob plugin | Azure Blob (RA-GRS) with immutable storage | Every 6 hours | 30 days |
| **Persistent volumes** | Velero CSI snapshots / Azure Disk snapshots | Azure Managed Disk snapshots | Daily | 30 days |
| **etcd** | ARO managed (SRE) | Automatic | Automatic | Managed by SRE |
| **GitOps state** (desired state) | Git repository | Azure DevOps / GitHub | Every commit | Indefinite |
| **Container images** | Azure Container Registry (geo-replicated) | ACR Premium with geo-replication | Continuous | Indefinite |
| **Secrets** | Azure Key Vault (soft delete + purge protection) | Key Vault | Continuous | 90 days (soft delete) |

### DR Design — Active-Passive

```
Primary Region (e.g., Southeast Asia)     Secondary Region (e.g., East Asia)
┌─────────────────────┐                   ┌─────────────────────┐
│  ARO Cluster (Active)│                   │  ARO Cluster (Standby)│
│  - Multi-AZ          │                   │  - Minimal workers     │
│  - Full workload     │                   │  - Scale up on failover│
│                      │    Replication     │                       │
│  Azure Blob ─────────┼──── RA-GRS ──────►│  Azure Blob            │
│  ACR        ─────────┼──── Geo-rep ─────►│  ACR                   │
│  Key Vault  ─────────┼──── Backup ──────►│  Key Vault             │
└─────────────────────┘                   └─────────────────────┘
         │                                          │
         └──────── Azure Front Door / Traffic Manager ──────┘
```

### OADP (OpenShift API for Data Protection)

OADP is the built-in backup tool for OpenShift, based on Velero:

- Backs up Kubernetes resources and internal images at **namespace granularity**
- PV backup via CSI snapshots or Restic (file-level backup)
- Schedule: recommend **daily at 4 AM** during maintenance window
- Storage: Azure Blob with RA-GRS for cross-region durability
- Limitations: currently only supports Azure Managed Disk-based PVs for CSI snapshots
- For comprehensive DR beyond OADP, consider enterprise solutions: **Veeam Kasten, Trilio, Portworx PX-Backup**

### Key DR Decisions

| Decision | Options | Recommendation |
|----------|---------|----------------|
| DR topology | Active-Active / Active-Passive / Pilot Light | **Active-Passive** — cost-effective for most enterprises; Active-Active for mission-critical APIs |
| State management | Velero backup-restore / GitOps + DB replication | **GitOps for stateless** (rebuild from Git); **Velero + DB replication for stateful** |
| Failover trigger | Manual / Automated (Azure Front Door health probe) | **Manual with automated detection** — enterprises prefer controlled failover |
| DR testing | Quarterly / Bi-annually | **Quarterly** — regulatory requirement |

---

## 9. Day 2 Operations

### Cluster Lifecycle

| Activity | Responsibility | Frequency |
|----------|---------------|-----------|
| Cluster upgrades (control plane + workers) | **Customer-initiated** — upgrades the entire cluster (control plane and workers together, cannot be separated). No rollback once started. ARO manages the rolling process. | Schedule maintenance window; test in non-prod first |
| Certificate rotation | ARO SRE (automatic) | Automatic |
| Node scaling | Customer (manual or autoscaler) | As needed |
| Operator updates | Customer | Review and approve in Operator Hub |

### GitOps — Recommended for Enterprise

- Use **OpenShift GitOps (ArgoCD)** for declarative, auditable deployments
- All cluster configuration and application manifests stored in Git
- Changes require pull request review and approval
- Full audit trail for regulatory compliance

### Cluster Bootstrapping

After cluster creation, a bootstrapping process prepares the cluster for workloads:

1. **Day 0 bootstrapping** (via Terraform/IaC):
   - Identity provider (Entra ID) configuration
   - Infrastructure node MachineSets
   - Cluster Autoscaler and Machine Health Checks
   - Custom TLS certificates for ingress and API server
2. **Day 1 bootstrapping** (via GitOps/ArgoCD):
   - Install operators (Logging, Monitoring, Compliance, ACS, OADP)
   - Create namespaces with quotas and network policies
   - Deploy ingress controllers and storage classes
   - Configure Gatekeeper constraints
3. **Validation**: Run smoke tests to verify cluster health before onboarding workloads

Use GitOps to manage bootstrapping — this ensures new clusters (or DR rebuilds) reach operational state automatically.

### CI/CD Pipeline Strategy

| Pipeline | Tool | Notes |
|----------|------|-------|
| **Cluster infrastructure** | Terraform + Azure DevOps / GitHub Actions | IaC for cluster provisioning and day 0 config |
| **Cluster configuration** | OpenShift GitOps (ArgoCD) | Operators, policies, namespaces — synced from Git |
| **Application workloads** | OpenShift Pipelines (Tekton) or Azure DevOps | Build, test, scan, deploy container images |
| **Image build** | OpenShift Builds or Azure DevOps | Build from source, push to ACR |
| **Image scanning** | ACS (StackRox) or Defender for Containers | Gate deployment on scan results |

- Separate pipelines for cluster infra, cluster config, and application workloads
- Promote images across environments (dev → uat → prod) via image tags or ACR repository promotion
- Enforce pipeline gates: code review, image scan pass, compliance check

### Namespace Management

- Standard namespace naming: `<team>-<env>` (e.g., `payments-prod`, `lending-uat`)
- Resource quotas per namespace to prevent noisy neighbor issues
- Network policies per namespace for micro-segmentation
- Label standards for cost allocation and monitoring

### Change Management

| Change Type | Process | Approval |
|-------------|---------|----------|
| Cluster upgrade | Schedule maintenance window, test in non-prod first | Change Advisory Board (CAB) |
| New namespace | Request via ServiceNow / GitOps PR | Team lead + Platform Admin |
| New operator | Security review + non-prod testing | Platform Admin + Security |
| Firewall rule change | Submit to network team | Network + Security team |
| Storage class change | Impact assessment | Platform Admin |

### Maintenance Windows & Upgrade Strategy

> **Important:** ARO cluster upgrades are **customer-initiated** and upgrade the **entire cluster as a whole** — control plane and worker nodes together. You **cannot** upgrade control plane and workers separately. There is **no rollback** once an upgrade is started. This makes pre-upgrade validation critical.

- Schedule cluster upgrades during **off-peak hours** (e.g., weekends, 2-6 AM)
- **Always test upgrades in non-prod cluster first** — allow minimum 1-week soak time before upgrading prod
- Upgrade process: customer initiates via Azure CLI or portal → ARO upgrades control plane first, then rolls workers one-by-one (respecting PDBs)
- Upgrade cadence: align with OpenShift minor releases (~quarterly); apply z-stream patches within 2 weeks of release
- Node OS patches: RHCOS updates are applied as part of cluster upgrades
- Since there is no rollback, mitigate risk by:
  - Taking OADP/Velero backups immediately before upgrading
  - Reviewing OpenShift release notes and known issues for the target version
  - Verifying operator compatibility with the target OpenShift version
  - Having a DR cluster available as fallback in case the upgrade causes critical issues

### Resilience Testing

- Conduct **chaos testing** to validate cluster resilience:
  - Simulate node failures (cordon/drain random nodes)
  - Simulate AZ failure (scale down MachineSet in one AZ)
  - Simulate pod failures (kill pods, test PDB behavior)
  - Simulate network partitions (network policy changes)
- Use tools like **Kraken** (Red Hat chaos testing for OpenShift) or **Azure Chaos Studio**
- Schedule chaos tests **quarterly** alongside DR drills
- Document runbooks for each failure scenario

---

## 10. Shared Responsibility Model

| Area | Microsoft + Red Hat | Customer |
|------|-------------------|----------|
| Cluster creation & management | ✅ | — |
| Control plane & worker node management | ✅ | — |
| Platform monitoring (Geneva) | ✅ | — |
| Platform software/security updates | ✅ | — |
| Certificate rotation (platform) | ✅ | — |
| Network infrastructure (LB, NSG, Private Link) | ✅ | — |
| Identity provider configuration | — | ✅ |
| User & RBAC management | — | ✅ |
| Project & quota management | — | ✅ |
| Application lifecycle (deploy, scale, update) | — | ✅ |
| Application data & backups | — | ✅ |
| Application logging & monitoring | Shared | Shared |
| Application networking (routes, network policies) | Shared | Shared |
| Virtual networking (VNET, peering, firewall) | Shared | Shared |
| Capacity management (worker node sizing) | Shared | Shared |

**Incident management flow:** SRE first responder → incident lead → communication/coordination → resolution summary in support ticket. RCA within 7 business days, full root cause analysis within 30 business days.

---

## 11. Cost Management

### Cost Components

| Component | Billing | Notes |
|-----------|---------|-------|
| ARO infrastructure (VMs, disks, network) | Azure bill | Standard Azure VM pricing |
| OpenShift subscription | Included in ARO pricing | Per-worker-node hourly fee |
| Infrastructure nodes | No OCP subscription cost | Label correctly to qualify |
| Storage (Managed Disks, Azure Files, Blob) | Azure bill | Per-GB pricing |
| Network egress | Azure bill | Cross-region and internet egress charged |
| Azure Firewall | Azure bill | Per-hour + per-GB processing |
| ExpressRoute | Azure bill | Per-circuit + per-GB |
| Red Hat ACS / Quay (optional) | Separate Red Hat subscription | If not using built-in alternatives |

### Cost Optimization Strategies

- **Create infrastructure nodes** post-install for platform services (router, monitoring, logging) — saves OCP subscription cost; not provisioned by default
- **Right-size worker nodes** — start with reference sizing, adjust based on actual utilization
- **Cluster Autoscaler** — scale down unused capacity during off-hours
- **Azure Reserved Instances** — 1-year or 3-year RI for predictable worker node costs
- **Azure Savings Plans** — flexible compute commitment across VM families
- **MACC eligibility** — ARO spend counts toward Microsoft Azure Consumption Commitment

### Cost Monitoring & Analysis

- Use **Azure Cost Management** dashboards filtered by ARO resource group to track spend
- Use **Azure Advisor** for right-sizing recommendations on underutilized worker VMs
- Set **Azure Budgets** with alerts at 80% and 100% thresholds to prevent overspend
- Use OpenShift **namespace-level resource consumption reports** (via Prometheus) for internal chargeback
- Review cost monthly: compare actual vs. reserved capacity, identify idle resources

### Cost Tagging

Apply consistent Azure tags and OpenShift labels for cost tracking:

| Tag/Label | Example | Purpose |
|-----------|---------|---------|
| `cost-center` | `CC-1234` | Financial allocation |
| `project-id` | `PRJ-LENDING` | Project-level tracking |
| `department` | `IT-Platform` | Department attribution |
| `environment` | `prod` / `non-prod` | Environment separation |
| `owner` | `team-platform` | Ownership |

---

## Appendix A: Checklist

| # | Design Area | Decision | Status |
|---|------------|----------|--------|
| 1 | Deployment model | Private without public IP | ☐ |
| 2 | Custom domain | Custom domain with enterprise TLS | ☐ |
| 3 | VNET design | Hub-spoke with Azure Firewall | ☐ |
| 4 | Subnet sizing | /23 for control plane, /23 for workers | ☐ |
| 5 | Pod/Service CIDR | Non-overlapping with existing networks | ☐ |
| 6 | On-prem connectivity | ExpressRoute | ☐ |
| 7 | Identity provider | Microsoft Entra ID (OIDC) | ☐ |
| 8 | Break-glass account | htpasswd in Key Vault | ☐ |
| 9 | RBAC model | Entra ID groups mapped to OCP roles | ☐ |
| 10 | Availability zones | 3 AZs for control plane + workers | ☐ |
| 11 | Autoscaling | Cluster Autoscaler + HPA | ☐ |
| 12 | Storage | Premium SSD with CMK, Azure Files Premium | ☐ |
| 13 | etcd encryption | Default (enabled) | ☐ |
| 14 | FIPS compliance | Enable at creation | ☐ |
| 15 | Secret management | Azure Key Vault CSI Provider | ☐ |
| 16 | Logging | Forward to Azure Log Analytics | ☐ |
| 17 | Audit log retention | 365 days | ☐ |
| 18 | Monitoring | Azure Monitor Container Insights + built-in Prometheus | ☐ |
| 19 | DR strategy | Active-Passive in secondary region | ☐ |
| 20 | Backup | Velero to Azure Blob (RA-GRS) | ☐ |
| 21 | GitOps | OpenShift GitOps (ArgoCD) | ☐ |
| 22 | Deployment IaC | Terraform | ☐ |
| 23 | Egress control | Azure Firewall with required endpoints whitelisted | ☐ |
| 24 | Image scanning | Microsoft Defender for Containers | ☐ |
| 25 | Compliance scanning | OpenShift Compliance Operator (CIS benchmark) | ☐ |
| 26 | Subscription model | Separate subscriptions for Prod / Non-Prod | ☐ |
| 27 | Bastion / jump box | Azure Bastion or jump box VM in Hub VNET | ☐ |
| 28 | Infra nodes | Create post-install: 3x infra nodes for router/monitoring/logging (not default) | ☐ |
| 29 | Cost tagging | Azure tags + OpenShift labels for cost allocation | ☐ |
| 30 | OADP backup | Daily backup at 4 AM to Azure Blob (RA-GRS) | ☐ |
| 31 | ACS (StackRox) | Runtime threat detection and vulnerability management | ☐ |
| 32 | Custom TLS certificates | Enterprise CA for ingress and API server | ☐ |
| 33 | DNS forwarding | CoreDNS → on-prem DNS for internal domains | ☐ |
| 34 | MACC eligibility | Confirm ARO spend counts toward Azure commitment | ☐ |
| 35 | Reserved Instances | 1-year or 3-year RI for worker nodes | ☐ |
| 36 | Private Link endpoints | Dedicated subnet for all Azure PaaS private endpoints | ☐ |
| 37 | Governance (Gatekeeper) | OPA Gatekeeper policies for image sources, labels, pod security | ☐ |
| 38 | Container image governance | Allow only authorized registries (ACR, registry.redhat.io) | ☐ |
| 39 | Workload Identity | Azure Workload Identity for pod-to-Azure-service authentication | ☐ |
| 40 | KEDA | Event-driven autoscaling for message/queue workloads | ☐ |
| 41 | Cluster bootstrapping | GitOps-based bootstrapping for operators, namespaces, policies | ☐ |
| 42 | CI/CD pipelines | Separate pipelines for infra, cluster config, and app workloads | ☐ |
| 43 | Maintenance windows | Scheduled upgrade windows; non-prod first, 1-week soak | ☐ |
| 44 | Chaos / resilience testing | Quarterly chaos tests alongside DR drills | ☐ |
| 45 | Pod health probes | Liveness, readiness, and startup probes on all containers | ☐ |
| 46 | Network observability | Network Observability Operator for flow logging | ☐ |
| 47 | Azure Budgets | Cost alerts at 80% and 100% thresholds | ☐ |
| 48 | Application Gateway + WAF | WAF for external-facing applications | ☐ |
