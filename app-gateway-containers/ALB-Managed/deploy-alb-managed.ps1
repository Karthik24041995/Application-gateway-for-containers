# ALB-Managed Complete Deployment Script for Application Gateway for Containers
# This consolidated script handles:
# 1. Infrastructure deployment (VNet, AKS, Managed Identity, RBAC)
# 2. ALB Controller installation via Helm
# 3. RBAC permissions setup for ALB Controller
# 4. Sample application deployment with ApplicationLoadBalancer CRD

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-aks-alb-managed-demo",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westus",
    
    [Parameter(Mandatory=$false)]
    [string]$TemplateFile = "agc-aks-alb-managed-template.json",
    
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = "agc-aks-alb-managed-parameters.json"
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ALB-Managed Deployment" -ForegroundColor Cyan
Write-Host "  Application Gateway for Containers" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Create resource group
Write-Host "[Step 1/7] Creating resource group: $ResourceGroupName" -ForegroundColor Green
az group create --name $ResourceGroupName --location $Location
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to create resource group!" -ForegroundColor Red
    exit 1
}

# Step 2: Deploy ARM template
Write-Host "`n[Step 2/7] Deploying ARM template (VNet, AKS, Identity, RBAC)..." -ForegroundColor Green
$deployment = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFile `
    --parameters $ParametersFile `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Host "ARM template deployment failed!" -ForegroundColor Red
    exit 1
}

Write-Host "ARM template deployed successfully!" -ForegroundColor Green

# Get outputs
$clusterName = $deployment.properties.outputs.clusterName.value
$appGwSubnetId = $deployment.properties.outputs.appGwSubnetId.value
$identityClientId = $deployment.properties.outputs.albIdentityClientId.value

Write-Host "  Cluster Name: $clusterName" -ForegroundColor Cyan
Write-Host "  Subnet ID: $appGwSubnetId" -ForegroundColor Cyan
Write-Host "  Identity Client ID: $identityClientId" -ForegroundColor Cyan

# Step 3: Get AKS credentials
Write-Host "`n[Step 3/7] Getting AKS credentials..." -ForegroundColor Green
az aks get-credentials --resource-group $ResourceGroupName --name $clusterName --overwrite-existing
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to get AKS credentials!" -ForegroundColor Red
    exit 1
}

# Step 4: Install ALB Controller
Write-Host "`n[Step 4/7] Installing ALB Controller via Helm..." -ForegroundColor Green

# Retry logic for Helm installation (handle transient network issues)
$helmRetries = 3
$helmAttempt = 0
$helmSuccess = $false

while ($helmAttempt -lt $helmRetries -and -not $helmSuccess) {
    $helmAttempt++
    if ($helmAttempt -gt 1) {
        Write-Host "Retry attempt $helmAttempt of $helmRetries..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    
    helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
        --version 1.8.12 `
        --set albController.namespace=azure-alb-system `
        --set albController.podIdentity.clientID=$identityClientId `
        --create-namespace `
        --namespace azure-alb-system
    
    if ($LASTEXITCODE -eq 0) {
        $helmSuccess = $true
        Write-Host "ALB Controller installed successfully!" -ForegroundColor Green
    } elseif ($helmAttempt -lt $helmRetries) {
        Write-Host "Installation failed, retrying..." -ForegroundColor Yellow
    }
}

if (-not $helmSuccess) {
    Write-Host "Failed to install ALB Controller after $helmRetries attempts!" -ForegroundColor Red
    exit 1
}

Write-Host "Waiting for ALB Controller pods to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 45

Write-Host "Verifying ALB Controller installation..." -ForegroundColor Cyan
kubectl get pods -n azure-alb-system
kubectl get gatewayclass

# Step 5: Setup RBAC permissions
Write-Host "`n[Step 5/7] Setting up RBAC permissions..." -ForegroundColor Green
$identityPrincipalId = az identity show --resource-group $ResourceGroupName --name "azure-alb-identity" --query principalId -o tsv
$nodeResourceGroup = "MC_${ResourceGroupName}_${clusterName}_${Location}"

Write-Host "  Assigning Reader role on node resource group..." -ForegroundColor Cyan
az role assignment create --assignee $identityPrincipalId --role "Reader" --scope "/subscriptions/$((az account show --query id -o tsv))/resourcegroups/$nodeResourceGroup" 2>$null

Write-Host "  Assigning Contributor role on node resource group..." -ForegroundColor Cyan
az role assignment create --assignee $identityPrincipalId --role "Contributor" --scope "/subscriptions/$((az account show --query id -o tsv))/resourcegroups/$nodeResourceGroup" 2>$null

Write-Host "RBAC permissions configured." -ForegroundColor Green

# Step 6: Deploy sample application
Write-Host "`n[Step 6/7] Deploying sample application..." -ForegroundColor Green
$yamlContent = Get-Content "sample-app-alb-managed.yaml" -Raw
$yamlContent = $yamlContent -replace '<SUBNET_ID>', $appGwSubnetId
$yamlContent | Set-Content "sample-app-alb-managed-configured.yaml"

kubectl apply -f sample-app-alb-managed-configured.yaml

Write-Host "Waiting for application pods to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 20
kubectl get pods -n demo

# Step 7: Wait for traffic controller and configure permissions
Write-Host "`n[Step 7/7] Waiting for ALB Controller to create traffic controller..." -ForegroundColor Green
Write-Host "This may take 5-10 minutes. The ALB Controller will:" -ForegroundColor Yellow
Write-Host "  1. Read the ApplicationLoadBalancer CRD" -ForegroundColor Gray
Write-Host "  2. Create a traffic controller with auto-generated name (e.g., alb-xyz123)" -ForegroundColor Gray
Write-Host "  3. Create frontend and association" -ForegroundColor Gray
Write-Host "  4. Update the Gateway with external address`n" -ForegroundColor Gray

$maxRetries = 20
$retryCount = 0
$trafficControllerId = $null

while ($retryCount -lt $maxRetries) {
    Start-Sleep -Seconds 30
    $retryCount++
    
    Write-Host "[$retryCount/$maxRetries] Checking for traffic controller..." -ForegroundColor Cyan
    
    # Get the full ApplicationLoadBalancer status and extract traffic controller ID
    $albStatusJson = kubectl get applicationloadbalancer alb-demo -n demo -o json 2>$null | ConvertFrom-Json
    
    if ($albStatusJson.status.conditions) {
        $deploymentCondition = $albStatusJson.status.conditions | Where-Object { $_.type -eq "Deployment" }
        if ($deploymentCondition -and $deploymentCondition.message -match "alb-id=(.+)") {
            $trafficControllerId = $Matches[1]
            Write-Host "Traffic controller created: $trafficControllerId" -ForegroundColor Green
            break
        }
    }
}

if ($null -eq $trafficControllerId) {
    Write-Host "`nPolling timeout reached. Attempting one final check..." -ForegroundColor Yellow
    
    # Final attempt to get traffic controller ID
    $albStatusJson = kubectl get applicationloadbalancer alb-demo -n demo -o json 2>$null | ConvertFrom-Json
    if ($albStatusJson.status.conditions) {
        $deploymentCondition = $albStatusJson.status.conditions | Where-Object { $_.type -eq "Deployment" }
        if ($deploymentCondition -and $deploymentCondition.message -match "alb-id=(.+)") {
            $trafficControllerId = $Matches[1]
            Write-Host "Traffic controller found: $trafficControllerId" -ForegroundColor Green
        }
    }
}

if ($null -ne $trafficControllerId) {
    Write-Host "`nConfiguring traffic controller permissions and Gateway annotations..." -ForegroundColor Cyan
    
    # Assign AppGw for Containers Configuration Manager role
    Write-Host "  Assigning AppGw Configuration Manager role..." -ForegroundColor Cyan
    az role assignment create --assignee $identityPrincipalId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" --scope $trafficControllerId --output json 2>$null | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Role assigned successfully" -ForegroundColor Green
    } else {
        Write-Host "  ! Role may already exist" -ForegroundColor Yellow
    }
    
    # Add annotations to Gateway
    Write-Host "  Adding Gateway annotations..." -ForegroundColor Cyan
    kubectl annotate gateway gateway-demo -n demo alb.networking.azure.io/alb-namespace=demo alb.networking.azure.io/alb-name=alb-demo --overwrite 2>$null | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Annotations added successfully" -ForegroundColor Green
    } else {
        Write-Host "  ! Failed to add annotations" -ForegroundColor Yellow
    }
    
    Write-Host "`nWaiting for ALB Controller to reconcile (60 seconds)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
} else {
    Write-Host "`nWarning: Traffic controller not found." -ForegroundColor Yellow
    Write-Host "The ALB Controller may still be creating it. Check status with:" -ForegroundColor Yellow
    Write-Host "  kubectl get applicationloadbalancer alb-demo -n demo -o yaml" -ForegroundColor White
}

# Final status check
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Gateway Status:" -ForegroundColor Green
kubectl get gateway -n demo

Write-Host "`nApplicationLoadBalancer Status:" -ForegroundColor Green
kubectl get applicationloadbalancer -n demo

Write-Host "`nApplication Pods:" -ForegroundColor Green
kubectl get pods -n demo

$gatewayAddress = kubectl get gateway gateway-demo -n demo -o jsonpath='{.status.addresses[0].value}' 2>$null

if ($gatewayAddress) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  SUCCESS!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nExternal URL: http://$gatewayAddress" -ForegroundColor Yellow
    Write-Host "`nTest the application:" -ForegroundColor Cyan
    Write-Host "  curl http://$gatewayAddress" -ForegroundColor White
} else {
    Write-Host "`nGateway address not yet available. Wait a few more minutes and check:" -ForegroundColor Yellow
    Write-Host "  kubectl get gateway gateway-demo -n demo" -ForegroundColor White
}

Write-Host "`nKey Features of ALB-Managed Deployment:" -ForegroundColor Cyan
Write-Host "  ✓ Traffic controller auto-created by ALB Controller" -ForegroundColor White
Write-Host "  ✓ Auto-generated resource names (e.g., alb-xyz123)" -ForegroundColor White
Write-Host "  ✓ Gateway references ApplicationLoadBalancer via annotations" -ForegroundColor White
Write-Host "  ✓ ALB Controller manages Azure resource lifecycle" -ForegroundColor White
