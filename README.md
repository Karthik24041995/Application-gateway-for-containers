# Application Gateway for Containers with AKS - ARM Template

This ARM template deploys Application Gateway for Containers (AGC) with Azure Kubernetes Service (AKS) as the backend.

## Architecture

```
Internet → Public IP → Application Gateway for Containers
                              ↓
                         VNet (10.0.0.0/16)
                              ↓
                    ┌─────────┴──────────┐
                    ↓                    ↓
           AGC Subnet (10.0.2.0/24)  AKS Subnet (10.0.1.0/24)
                                          ↓
                                    AKS Cluster
                                    (Backend Pods)
```

## Components Deployed

### Network Resources
- **Virtual Network** (10.0.0.0/16)
  - AKS Subnet (10.0.1.0/24)
  - Application Gateway Subnet (10.0.2.0/24) with delegation to `Microsoft.ServiceNetworking/trafficControllers`
- **Public IP** (Standard SKU)

### Compute Resources
- **AKS Cluster**
  - Azure CNI networking
  - System node pool (3 nodes, auto-scaling 1-5)
  - User-assigned managed identity
  - Azure Key Vault integration

### Application Gateway for Containers
- **Traffic Controller** (Microsoft.ServiceNetworking)
- **Frontend** configuration
- **Association** with AKS subnet

### Identity & Access
- **User-Assigned Managed Identities** (2)
  - AKS cluster identity
  - Application Gateway identity
- **RBAC Role Assignments**
  - Network Contributor roles

## Prerequisites

- Azure CLI installed
- Azure subscription with permissions
- Resource group created

## Deployment Steps

### 1. Create Resource Group

```powershell
az group create `
  --name rg-aks-agc-demo `
  --location "West US 2"
```

### 2. Deploy ARM Template

```powershell
az deployment group create `
  --resource-group rg-aks-agc-demo `
  --template-file agc-aks-template.json `
  --parameters agc-aks-parameters.json
```

### 3. Get AKS Credentials

```powershell
az aks get-credentials `
  --resource-group rg-aks-agc-demo `
  --name aks-agc-demo
```

### 4. Verify Deployment

```powershell
kubectl get nodes
kubectl get ns
```

## Install ALB Controller (Application Load Balancer)

### 1. Enable ALB on AKS

```powershell
az aks approuting enable `
  --resource-group rg-aks-agc-demo `
  --name aks-agc-demo
```

### 2. Install ALB Controller via Helm

```powershell
# Add Helm repo
helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

# Get Application Gateway details
$appGwId = az deployment group show `
  --resource-group rg-aks-agc-demo `
  --name agc-aks-template `
  --query properties.outputs.applicationGatewayResourceId.value `
  --output tsv

# Install controller
helm install alb-controller application-gateway-kubernetes-ingress/ingress-azure `
  --namespace kube-system `
  --set appgw.applicationGatewayID=$appGwId `
  --set armAuth.type=workloadIdentity `
  --set rbac.enabled=true
```

## Deploy Sample Application

### 1. Create Sample App with AGC Ingress

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  annotations:
    kubernetes.azure.com/use-application-gateway-for-containers: "true"
spec:
  ingressClassName: azure-application-gateway
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
```

### 2. Apply Configuration

```powershell
kubectl apply -f sample-app.yaml
```

### 3. Get Public IP

```powershell
kubectl get ingress nginx-ingress
```

## Key Features

✅ **Application Gateway for Containers** - Modern, container-optimized load balancer
✅ **Azure CNI Networking** - Advanced networking for AKS
✅ **Managed Identities** - Secure authentication without credentials
✅ **Auto-scaling** - AKS nodes scale automatically (1-5 nodes)
✅ **Subnet Delegation** - Dedicated subnet for Application Gateway
✅ **RBAC Integration** - Proper role assignments for security
✅ **Public IP** - Standard SKU for production workloads

## Networking Details

| Component | Subnet | Address Range |
|-----------|--------|---------------|
| AKS Nodes | subnet-aks | 10.0.1.0/24 |
| App Gateway | subnet-appgw | 10.0.2.0/24 |
| Kubernetes Services | Service CIDR | 10.2.0.0/16 |

## Outputs

The template provides these outputs:
- AKS cluster name and resource ID
- Application Gateway name and resource ID
- Public IP address
- Managed identity client IDs
- VNet name

## Verify Application Gateway Configuration

```powershell
# Check Traffic Controller
az network traffic-controller show `
  --name appgw-containers `
  --resource-group rg-aks-agc-demo

# Check Frontend
az network traffic-controller frontend list `
  --traffic-controller-name appgw-containers `
  --resource-group rg-aks-agc-demo

# Check Association
az network traffic-controller association list `
  --traffic-controller-name appgw-containers `
  --resource-group rg-aks-agc-demo
```

## Troubleshooting

### Check ALB Controller Logs
```powershell
kubectl logs -n kube-system -l app=alb-controller
```

### Verify Ingress Status
```powershell
kubectl describe ingress nginx-ingress
```

### Check Application Gateway Status
```powershell
az network traffic-controller show `
  --name appgw-containers `
  --resource-group rg-aks-agc-demo `
  --query provisioningState
```

## Clean Up

```powershell
az group delete --name rg-aks-agc-demo --yes --no-wait
```

## Cost Considerations

- **AKS**: ~$0.10/hour per node (3 nodes = ~$216/month)
- **Application Gateway for Containers**: ~$0.40/hour (~$288/month)
- **Public IP**: ~$3.65/month
- **Total Estimated**: ~$508/month

## References

- [Application Gateway for Containers Documentation](https://learn.microsoft.com/azure/application-gateway/for-containers/)
- [AKS Networking](https://learn.microsoft.com/azure/aks/concepts-network)
- [ARM Template Reference](https://learn.microsoft.com/azure/templates/)
