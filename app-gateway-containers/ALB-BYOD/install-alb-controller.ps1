# Install ALB Controller for Application Gateway for Containers
# Official Microsoft Documentation: https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller

param(
    [string]$ResourceGroup = "rg-aks-agc-demo",
    [string]$ClusterName = "aks-agc-demo",
    [string]$IdentityName = "azure-alb-identity"
)

Write-Host "Installing ALB Controller for Application Gateway for Containers..." -ForegroundColor Green
Write-Host "Using official Microsoft installation method" -ForegroundColor Cyan

# Step 1: Register required resource providers
Write-Host "`n1. Registering Azure resource providers..." -ForegroundColor Yellow
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

# Step 2: Install Azure CLI ALB extension
Write-Host "`n2. Installing Azure CLI ALB extension..." -ForegroundColor Yellow
az extension add --name alb 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ALB extension already installed or failed to install" -ForegroundColor Yellow
}

# Step 3: Get AKS credentials
Write-Host "`n3. Getting AKS credentials..." -ForegroundColor Yellow
az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing

# Step 4: Enable OIDC issuer and workload identity on AKS
Write-Host "`n4. Enabling OIDC issuer and workload identity..." -ForegroundColor Yellow
az aks update `
    --resource-group $ResourceGroup `
    --name $ClusterName `
    --enable-oidc-issuer `
    --enable-workload-identity `
    --no-wait

Write-Host "Waiting for AKS update to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# Step 5: Create managed identity for ALB controller
Write-Host "`n5. Creating user-assigned managed identity for ALB Controller..." -ForegroundColor Yellow

$mcResourceGroup = az aks show --resource-group $ResourceGroup --name $ClusterName --query "nodeResourceGroup" -o tsv
$mcResourceGroupId = az group show --name $mcResourceGroup --query id -o tsv

Write-Host "Creating identity $IdentityName in resource group $ResourceGroup" -ForegroundColor Cyan
az identity create --resource-group $ResourceGroup --name $IdentityName

$principalId = az identity show -g $ResourceGroup -n $IdentityName --query principalId -o tsv

Write-Host "Waiting 60 seconds to allow for replication of the identity..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# Step 6: Assign Reader role to the managed identity
Write-Host "`n6. Assigning Reader role to managed identity..." -ForegroundColor Yellow
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --scope $mcResourceGroupId `
    --role "acdd72a7-3385-48ef-bd42-f606fba81ae7"  # Reader role

# Step 7: Set up federation with AKS OIDC issuer
Write-Host "`n7. Setting up federated identity credential..." -ForegroundColor Yellow
$aksOidcIssuer = az aks show -n $ClusterName -g $ResourceGroup --query "oidcIssuerProfile.issuerUrl" -o tsv

Write-Host "OIDC Issuer URL: $aksOidcIssuer" -ForegroundColor Cyan

az identity federated-credential create `
    --name "azure-alb-identity" `
    --identity-name $IdentityName `
    --resource-group $ResourceGroup `
    --issuer $aksOidcIssuer `
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# Step 8: Install ALB Controller using Helm
Write-Host "`n8. Installing ALB Controller via Helm..." -ForegroundColor Yellow

$helmNamespace = "default"
$controllerNamespace = "azure-alb-system"
$clientId = az identity show -g $ResourceGroup -n $IdentityName --query clientId -o tsv

Write-Host "Client ID: $clientId" -ForegroundColor Cyan
Write-Host "Helm Namespace: $helmNamespace" -ForegroundColor Cyan
Write-Host "Controller Namespace: $controllerNamespace" -ForegroundColor Cyan

helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
    --version 1.8.12 `
    --set albController.namespace=$controllerNamespace `
    --set albController.podIdentity.clientID=$clientId

# Step 9: Wait for ALB controller to be ready
Write-Host "`n9. Waiting for ALB controller pods to be ready..." -ForegroundColor Yellow
Write-Host "This may take a few minutes..." -ForegroundColor Cyan
kubectl wait --for=condition=ready pod -l app=alb-controller -n azure-alb-system --timeout=300s

# Step 10: Verify installation
Write-Host "`n10. Verifying ALB Controller installation..." -ForegroundColor Yellow

Write-Host "`nALB Controller Pods:" -ForegroundColor Cyan
kubectl get pods -n azure-alb-system

Write-Host "`nGatewayClass:" -ForegroundColor Cyan
kubectl get gatewayclass azure-alb-external

Write-Host "`n✅ ALB Controller installation complete!" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Deploy using Gateway API (recommended): kubectl apply -f sample-app-gateway-api.yaml" -ForegroundColor White
Write-Host "  2. Check Gateway status: kubectl get gateway -n demo" -ForegroundColor White
Write-Host "  3. Check HTTPRoute: kubectl get httproute -n demo" -ForegroundColor White
Write-Host "  4. Get the external IP: kubectl get gateway gateway-demo -n demo" -ForegroundColor White
