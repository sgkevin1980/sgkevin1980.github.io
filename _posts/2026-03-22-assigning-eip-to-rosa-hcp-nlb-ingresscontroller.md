---
layout: default
title: "Assigning AWS Elastic IP (EIP) to ROSA HCP NLB IngressController"
date: 2026-03-22
---

# Assigning AWS Elastic IP (EIP) to ROSA HCP NLB IngressController

This guide demonstrates how to assign pre-allocated AWS Elastic IPs to a ROSA HCP NLB (Network Load Balancer) IngressController for static IP whitelisting use cases. Two approaches are covered:

- **Option A**: Create a new IngressController with EIP (Recommended)
- **Option B**: Assign EIP to the default IngressController

## Prerequisites

- A ROSA HCP cluster with **OCP 4.17+** (required for the `eipAllocations` field in IngressController)
- **Public subnets** in the VPC (EIP requires an External/internet-facing NLB)
- Pre-allocated EIPs — one per AZ/subnet the NLB spans
- `oc`, `aws`, `rosa` CLIs logged in

## Set Up Environment Variables

```bash
export CLUSTER_NAME=<your-cluster-name>
export CLUSTER_DOMAIN=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.dns.base_domain')
export REGION=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.region.id')
```

## Step 1: Allocate EIPs

Allocate one EIP per AZ. For a single-AZ cluster, only 1 EIP is needed. For a multi-AZ cluster (3 AZs), allocate 3 EIPs.

```bash
aws ec2 allocate-address --domain vpc --region $REGION \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Purpose,Value=ROSA-NLB-EIP}]'
```

Note the `AllocationId` (e.g. `eipalloc-0123456789abcdef0`) and `PublicIp` from the output. Set the allocation ID as an environment variable:

```bash
export EIP_ALLOC_ID=<your-eip-allocation-id>
```

For multi-AZ clusters, allocate additional EIPs and note all allocation IDs.

---

## Option A: Create a NEW IngressController with EIP (Recommended)

This approach creates a separate IngressController dedicated to EIP-backed routes, with no disruption to existing traffic.

### Create the IngressController

1. Set the custom ingress domain. This must be a subdomain of your cluster's apps domain or a custom domain you own.

    ```bash
    export INGRESS_NAME=eip-ingress
    export INGRESS_DOMAIN=eip.apps.rosa.$CLUSTER_NAME.$CLUSTER_DOMAIN
    ```

1. Create the IngressController manifest.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: operator.openshift.io/v1
    kind: IngressController
    metadata:
      name: $INGRESS_NAME
      namespace: openshift-ingress-operator
    spec:
      domain: $INGRESS_DOMAIN
      replicas: 1
      endpointPublishingStrategy:
        type: LoadBalancerService
        loadBalancer:
          scope: External
          providerParameters:
            type: AWS
            aws:
              type: NLB
              networkLoadBalancer:
                eipAllocations:
                  - $EIP_ALLOC_ID
      routeSelector:
        matchLabels:
          ingress: $INGRESS_NAME
    EOF
    ```

    > **Note:** The `routeSelector` ensures only routes with the label `ingress: <ingress-name>` are served by this IngressController. For multi-AZ clusters, list all EIP allocation IDs under `eipAllocations`.

### Verify

1. Confirm the IngressController is admitted.

    ```bash
    oc describe ingresscontroller $INGRESS_NAME -n openshift-ingress-operator | grep Admitted
    ```

    You should see: `Normal  Admitted  ...  ingresscontroller passed validation`

1. Check the router pods are running.

    ```bash
    oc get pods -n openshift-ingress | grep $INGRESS_NAME
    ```

1. Verify the router service has the EIP annotation.

    ```bash
    oc get svc router-$INGRESS_NAME -n openshift-ingress -o yaml | grep eip-allocations
    ```

    You should see: `service.beta.kubernetes.io/aws-load-balancer-eip-allocations: <your-eip-allocation-id>`

1. Confirm the NLB resolves to your EIP.

    ```bash
    NLB_HOSTNAME=$(oc get svc router-$INGRESS_NAME -n openshift-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    dig +short $NLB_HOSTNAME
    ```

    The output should show your EIP's public IP address.

1. Confirm the EIP is associated with the NLB's network interface.

    ```bash
    aws ec2 describe-addresses --allocation-ids $EIP_ALLOC_ID --region $REGION \
      --query 'Addresses[0].{PublicIp:PublicIp,AssociationId:AssociationId,NetworkInterfaceId:NetworkInterfaceId}' \
      --output table
    ```

### Deploy a Sample App

1. Create a test project and deploy a sample application.

    ```bash
    oc new-project eip-demo
    oc create deployment hello-openshift --image=docker.io/openshift/hello-openshift:latest
    oc expose deployment hello-openshift --port=8080
    ```

1. Create a route with a label matching the IngressController's `routeSelector`.

    ```bash
    oc create route edge --service=hello-openshift hello-eip \
      --hostname hello-eip.$INGRESS_DOMAIN
    oc label route hello-eip ingress=$INGRESS_NAME
    ```

1. Verify the route is admitted by the EIP-backed router.

    ```bash
    oc get route hello-eip -n eip-demo -o jsonpath='{.status.ingress[*].routerName}'
    ```

    You should see `eip-ingress` (or both `default eip-ingress`).

1. Test the application via the EIP.

    ```bash
    EIP_PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC_ID \
      --region $REGION --query 'Addresses[0].PublicIp' --output text)

    curl -sk --resolve hello-eip.$INGRESS_DOMAIN:443:$EIP_PUBLIC_IP \
      https://hello-eip.$INGRESS_DOMAIN
    ```

    You should see: `Hello OpenShift!`

### Optional: Add Custom Domain with Route53

If you own a custom domain managed in Route53, you can create a wildcard alias record pointing to the EIP-backed NLB.

1. Set your custom domain variables.

    ```bash
    export CUSTOM_DOMAIN=<your-custom-domain>        # e.g. eip.example.com
    export HOSTED_ZONE_ID=<your-route53-zone-id>      # e.g. Z0123456789ABCDEFGHIJ
    ```

1. Get the NLB details.

    ```bash
    NLB_HOSTNAME=$(oc get svc router-$INGRESS_NAME -n openshift-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    NLB_NAME=$(echo $NLB_HOSTNAME | sed 's/-.*//')
    NLB_REGION=$(echo $NLB_HOSTNAME | cut -d "." -f 3)
    NLB_HOSTED_ZONE=$(aws elbv2 describe-load-balancers --name $NLB_NAME --region $NLB_REGION \
      --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
    ```

1. Create the Route53 wildcard alias record.

    ```bash
    cat <<EOF > /tmp/add_alias_record.json
    {
      "Comment": "Alias record for EIP NLB",
      "Changes": [{
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "*.$CUSTOM_DOMAIN",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "$NLB_HOSTED_ZONE",
            "DNSName": "$NLB_HOSTNAME",
            "EvaluateTargetHealth": false
          }
        }
      }]
    }
    EOF

    aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch file:///tmp/add_alias_record.json
    ```

1. Create a route using the custom domain.

    ```bash
    oc create route edge --service=hello-openshift hello-custom \
      --hostname hello.$CUSTOM_DOMAIN -n eip-demo
    oc label route hello-custom ingress=$INGRESS_NAME -n eip-demo
    ```

1. Test the custom domain.

    ```bash
    curl -sk https://hello.$CUSTOM_DOMAIN
    ```

    You should see: `Hello OpenShift!`

1. Verify DNS resolves to the EIP.

    ```bash
    dig +short hello.$CUSTOM_DOMAIN
    ```

---

## Option B: Assign EIP to the DEFAULT IngressController

> **Warning**: This causes the Ingress Operator to **recreate the NLB**, resulting in temporary DNS disruption. The default IngressController on ROSA HCP is managed by HyperShift (`hypershift.openshift.io/managed: "true"`) — modifications may be reverted by SRE or during cluster upgrades.

### Patch the Default IngressController

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p "{
  \"spec\": {
    \"endpointPublishingStrategy\": {
      \"loadBalancer\": {
        \"providerParameters\": {
          \"aws\": {
            \"networkLoadBalancer\": {
              \"eipAllocations\": [\"$EIP_ALLOC_ID\"]
            },
            \"type\": \"NLB\"
          },
          \"type\": \"AWS\"
        },
        \"scope\": \"External\"
      },
      \"type\": \"LoadBalancerService\"
    }
  }
}"
```

### Verify

1. Check the annotation on the `router-default` service.

    ```bash
    oc get svc router-default -n openshift-ingress -o yaml | grep eip-allocations
    ```

1. Note that the NLB hostname will change because a new NLB is created.

    ```bash
    oc get svc router-default -n openshift-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    ```

1. Verify DNS resolves to the EIP.

    ```bash
    NLB_HOSTNAME=$(oc get svc router-default -n openshift-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    dig +short $NLB_HOSTNAME
    ```

1. Verify the OpenShift console is accessible via the EIP.

    ```bash
    EIP_PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC_ID \
      --region $REGION --query 'Addresses[0].PublicIp' --output text)
    CONSOLE_HOSTNAME=console-openshift-console.apps.rosa.$CLUSTER_NAME.$CLUSTER_DOMAIN

    curl -sk --resolve $CONSOLE_HOSTNAME:443:$EIP_PUBLIC_IP \
      https://$CONSOLE_HOSTNAME | head -3
    ```

### Revert (Remove EIP from Default)

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=json \
  -p '[{"op": "remove", "path": "/spec/endpointPublishingStrategy/loadBalancer/providerParameters/aws/networkLoadBalancer/eipAllocations"}]'
```

> **Note**: Reverting also recreates the NLB, causing another DNS disruption.

---

## Comparison

| | Option A (New IngressController) | Option B (Default IngressController) |
|---|---|---|
| **Works?** | Yes | Yes |
| **Disruption** | None to existing traffic | NLB recreated, DNS disruption |
| **Supported?** | Yes (OCP 4.17+) | Not officially (HyperShift-managed) |
| **Custom Domain?** | Yes, via Route53 wildcard alias | N/A (uses default apps domain) |
| **Recommendation** | Preferred for production | Use with caution |

## How It Works

1. The `eipAllocations` field in the IngressController spec (OCP 4.17+) is translated by the Ingress Operator to the `service.beta.kubernetes.io/aws-load-balancer-eip-allocations` annotation on the router service.
2. The AWS cloud provider creates the NLB with the specified EIP attached.
3. The NLB's public IP becomes the static EIP, suitable for IP whitelisting.

```
Client → Custom Domain (DNS)
       → EIP (static IP)
       → NLB (with EIP attached)
       → Router pod
       → Application Service
       → Application response
```

## Important Notes

- The `eipAllocations` field requires **OCP 4.17+**. Clusters on 4.16 or earlier must upgrade first.
- The number of EIPs must match the number of subnets/AZs the NLB spans (e.g. 3 AZs = 3 EIPs).
- EIP requires **External** scope NLB with **public subnets**. It does NOT work with Internal NLBs or private-only subnets.
- The `rosa edit ingress` CLI does NOT have an EIP option — you must use `oc` to create or modify IngressController CRs directly.

## Cleanup

1. Delete the test project.

    ```bash
    oc delete project eip-demo
    ```

1. Delete the custom IngressController (Option A).

    ```bash
    oc delete ingresscontroller $INGRESS_NAME -n openshift-ingress-operator
    ```

1. Release the EIP.

    ```bash
    aws ec2 release-address --allocation-id $EIP_ALLOC_ID --region $REGION
    ```

1. If you created a Route53 record, delete it.

    ```bash
    # Change "CREATE" to "DELETE" in the JSON file and re-run
    sed -i '' 's/CREATE/DELETE/' /tmp/add_alias_record.json
    aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch file:///tmp/add_alias_record.json
    ```
