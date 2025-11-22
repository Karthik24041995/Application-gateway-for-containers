# ALB-Managed Deployment for Application Gateway for Containers

This folder contains an **ALB-Managed** deployment approach where the ALB Controller automatically creates and manages the Azure Application Gateway for Containers resources.

## 🎯 What is ALB-Managed Deployment?

In ALB-Managed deployment:
- You provide a **subnet ID** with proper delegation
- ALB Controller **automatically creates** the traffic controller, frontend, and association
- Resources get **auto-generated names** (e.g., `alb-xyz123`)
- Gateway **does NOT require** `alb-id` or `alb-frontend` annotations
- ALB Controller **manages the lifecycle** of Azure resources

## 🔄 Comparison: BYO vs ALB-Managed

| Aspect | BYO Deployment | ALB-Managed Deployment |
|--------|---------------|------------------------|
| Traffic Controller | Pre-created via ARM template | Created by ALB Controller |
| Frontend | Pre-created via ARM template | Created by ALB Controller |
| Association | Pre-created via ARM template | Created by ALB Controller |
| Gateway Annotations | Required (`alb-id`, `alb-frontend`) | Not required |
| Resource Names | User-defined | Auto-generated (e.g., `alb-abc123`) |
| Kubernetes CRD | Not used | ApplicationLoadBalancer CRD |
| Use Case | Full control, predictable names | Quick setup, auto-management |

## 📁 Files in this Solution

### ARM Template
- **agc-aks-alb-managed-template.json** - Infrastructure template (VNet, AKS, managed identity, ALB Controller installation)
- **agc-aks-alb-managed-parameters.json** - Deployment parameters

### Kubernetes Resources
- **sample-app-alb-managed.yaml** - ApplicationLoadBalancer CRD, Gateway, HTTPRoute, nginx deployment

### Deployment Script
- **deploy-alb-managed.ps1** - Automated deployment script

## 🚀 Quick Start

### Prerequisites
- Azure CLI installed and authenticated
- kubectl installed
- Appropriate Azure permissions (Contributor on subscription or resource group)

### Step 1: Deploy Infrastructure and ALB Controller

```powershell
# Run the deployment script
.\deploy-alb-managed.ps1
```

Or manually:

```powershell
# Create resource group
az group create --name rg-aks-alb-managed-demo --location westus

# Deploy ARM template
az deployment group create `
    --resource-group rg-aks-alb-managed-demo `
    --template-file agc-aks-alb-managed-template.json `
    --parameters agc-aks-alb-managed-parameters.json
```

### Step 2: Deploy Sample Application

```powershell
# Get AKS credentials
az aks get-credentials --resource-group rg-aks-alb-managed-demo --name aks-alb-managed-demo --overwrite-existing

# Update sample-app-alb-managed.yaml with your subnet ID from ARM output
# Replace <SUBNET_ID> with the appGwSubnetId output value

# Deploy application
kubectl apply -f sample-app-alb-managed.yaml
```

### Step 3: Verify Deployment

```powershell
# Check ALB Controller pods
kubectl get pods -n azure-alb-system

# Check ApplicationLoadBalancer CRD
kubectl get applicationloadbalancer -n demo

# Check Gateway (wait for ADDRESS to appear, may take 5-10 minutes)
kubectl get gateway -n demo

# Check auto-created traffic controller
az network traffic-controller list --resource-group MC_rg-aks-alb-managed-demo_aks-alb-managed-demo_westus
```

### Step 4: Test Application

```powershell
# Get external address
$GATEWAY_ADDRESS = kubectl get gateway gateway-demo -n demo -o jsonpath='{.status.addresses[0].value}'

# Test application
curl http://$GATEWAY_ADDRESS
```

## 🔍 Key Components

### 1. ApplicationLoadBalancer CRD

```yaml
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-demo
  namespace: demo
spec:
  associations:
  - "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
```

The ALB Controller:
- Reads this CRD
- Creates a traffic controller in the node resource group
- Creates a frontend with auto-generated name
- Creates an association to the specified subnet

### 2. Gateway (No Annotations Required)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway-demo
  namespace: demo
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http
    port: 80
    protocol: HTTP
```

Notice: **No annotations** needed! ALB Controller automatically links the Gateway to the ApplicationLoadBalancer in the same namespace.

## 📊 What Gets Created

### In ARM Template:
- Virtual Network with subnets
- AKS cluster with OIDC and workload identity
- Managed identity for ALB Controller
- Federated credential for workload identity
- RBAC role assignments
- Deployment script to install ALB Controller

### By ALB Controller:
- Traffic Controller (auto-named, e.g., `alb-abc123`)
- Frontend (auto-named)
- Association (links traffic controller to subnet)

### In Kubernetes:
- Namespace: `demo`
- ApplicationLoadBalancer CRD
- Gateway
- HTTPRoute
- Nginx Deployment (3 replicas)
- Nginx Service

## 🔧 Troubleshooting

### Gateway stuck in "Pending" or "Unknown"

```powershell
# Check ApplicationLoadBalancer status
kubectl describe applicationloadbalancer alb-demo -n demo

# Check ALB Controller logs
kubectl logs -l app.kubernetes.io/name=alb-controller -n azure-alb-system -f

# Verify subnet delegation
az network vnet subnet show --resource-group rg-aks-alb-managed-demo --vnet-name aks-alb-managed-demo-vnet --name appgw-subnet --query delegations
```

### No traffic controller created

Check that:
1. ALB Controller is running
2. ApplicationLoadBalancer CRD is applied
3. Subnet ID is correct and subnet has delegation to `Microsoft.ServiceNetworking/trafficControllers`
4. Managed identity has Contributor permissions on resource group

### Find auto-created resources

```powershell
# List traffic controllers in node resource group
$NODE_RG = "MC_rg-aks-alb-managed-demo_aks-alb-managed-demo_westus"
az network traffic-controller list --resource-group $NODE_RG

# List frontends
az network traffic-controller frontend list --traffic-controller-name <auto-generated-name> --resource-group $NODE_RG

# List associations
az network traffic-controller association list --traffic-controller-name <auto-generated-name> --resource-group $NODE_RG
```

## 🧹 Cleanup

```powershell
# Delete the resource group
az group delete --name rg-aks-alb-managed-demo --yes --no-wait
```

The ALB Controller will automatically clean up the traffic controller, frontend, and association when the ApplicationLoadBalancer CRD is deleted or when the resource group is deleted.

## 📚 Additional Resources

- [Application Gateway for Containers Documentation](https://learn.microsoft.com/azure/application-gateway/for-containers/overview)
- [ALB Controller Installation](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)

## ✅ Success Criteria

Your deployment is successful when:
1. ✅ ALB Controller pods are running (2/2)
2. ✅ ApplicationLoadBalancer CRD shows "Accepted" or "Programmed"
3. ✅ Gateway shows ADDRESS with external FQDN
4. ✅ Traffic controller exists in node resource group with auto-generated name
5. ✅ curl to Gateway address returns nginx welcome page
