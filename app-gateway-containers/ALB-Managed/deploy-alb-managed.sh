#!/bin/bash

# ALB-Managed Complete Deployment Script for Application Gateway for Containers
# This consolidated script handles:
# 1. Infrastructure deployment (VNet, AKS, Managed Identity, RBAC)
# 2. ALB Controller installation via Helm
# 3. RBAC permissions setup for ALB Controller
# 4. Sample application deployment with ApplicationLoadBalancer CRD

# Default parameters
RESOURCE_GROUP_NAME="${1:-rg-aks-alb-managed-demo}"
LOCATION="${2:-westus}"
TEMPLATE_FILE="${3:-agc-aks-alb-managed-template.json}"
PARAMETERS_FILE="${4:-agc-aks-alb-managed-parameters.json}"

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

echo -e "${CYAN}========================================"
echo -e "  ALB-Managed Deployment"
echo -e "  Application Gateway for Containers"
echo -e "========================================${NC}\n"

# Step 1: Create resource group
echo -e "${GREEN}[Step 1/7] Creating resource group: $RESOURCE_GROUP_NAME${NC}"
az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create resource group!${NC}"
    exit 1
fi

# Step 2: Deploy ARM template
echo -e "\n${GREEN}[Step 2/7] Deploying ARM template (VNet, AKS, Identity, RBAC)...${NC}"
az deployment group create \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --parameters "$PARAMETERS_FILE" \
    --output none

if [ $? -ne 0 ]; then
    echo -e "${RED}ARM template deployment failed!${NC}"
    exit 1
fi

echo -e "${GREEN}ARM template deployed successfully!${NC}"

# Get outputs directly using Azure CLI queries
CLUSTER_NAME=$(az deployment group show --resource-group "$RESOURCE_GROUP_NAME" --name "$TEMPLATE_FILE" --query 'properties.outputs.clusterName.value' -o tsv 2>/dev/null)
if [ -z "$CLUSTER_NAME" ]; then
    # If template file name doesn't work, try getting the latest deployment
    CLUSTER_NAME=$(az deployment group list --resource-group "$RESOURCE_GROUP_NAME" --query '[0].properties.outputs.clusterName.value' -o tsv)
fi

APPGW_SUBNET_ID=$(az deployment group show --resource-group "$RESOURCE_GROUP_NAME" --name "$TEMPLATE_FILE" --query 'properties.outputs.appGwSubnetId.value' -o tsv 2>/dev/null)
if [ -z "$APPGW_SUBNET_ID" ]; then
    APPGW_SUBNET_ID=$(az deployment group list --resource-group "$RESOURCE_GROUP_NAME" --query '[0].properties.outputs.appGwSubnetId.value' -o tsv)
fi

IDENTITY_CLIENT_ID=$(az deployment group show --resource-group "$RESOURCE_GROUP_NAME" --name "$TEMPLATE_FILE" --query 'properties.outputs.albIdentityClientId.value' -o tsv 2>/dev/null)
if [ -z "$IDENTITY_CLIENT_ID" ]; then
    IDENTITY_CLIENT_ID=$(az deployment group list --resource-group "$RESOURCE_GROUP_NAME" --query '[0].properties.outputs.albIdentityClientId.value' -o tsv)
fi

echo -e "${CYAN}  Cluster Name: $CLUSTER_NAME${NC}"
echo -e "${CYAN}  Subnet ID: $APPGW_SUBNET_ID${NC}"
echo -e "${CYAN}  Identity Client ID: $IDENTITY_CLIENT_ID${NC}"

# Step 3: Get AKS credentials
echo -e "\n${GREEN}[Step 3/7] Getting AKS credentials...${NC}"
az aks get-credentials --resource-group "$RESOURCE_GROUP_NAME" --name "$CLUSTER_NAME" --overwrite-existing
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to get AKS credentials!${NC}"
    exit 1
fi

# Step 4: Install ALB Controller
echo -e "\n${GREEN}[Step 4/7] Installing ALB Controller via Helm...${NC}"

# Retry logic for Helm installation (handle transient network issues)
HELM_RETRIES=3
HELM_ATTEMPT=0
HELM_SUCCESS=false

while [ $HELM_ATTEMPT -lt $HELM_RETRIES ] && [ "$HELM_SUCCESS" = false ]; do
    HELM_ATTEMPT=$((HELM_ATTEMPT + 1))
    if [ $HELM_ATTEMPT -gt 1 ]; then
        echo -e "${YELLOW}Retry attempt $HELM_ATTEMPT of $HELM_RETRIES...${NC}"
        sleep 10
    fi
    
    helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
        --version 1.8.12 \
        --set albController.namespace=azure-alb-system \
        --set albController.podIdentity.clientID="$IDENTITY_CLIENT_ID" \
        --create-namespace \
        --namespace azure-alb-system
    
    if [ $? -eq 0 ]; then
        HELM_SUCCESS=true
        echo -e "${GREEN}ALB Controller installed successfully!${NC}"
    elif [ $HELM_ATTEMPT -lt $HELM_RETRIES ]; then
        echo -e "${YELLOW}Installation failed, retrying...${NC}"
    fi
done

if [ "$HELM_SUCCESS" = false ]; then
    echo -e "${RED}Failed to install ALB Controller after $HELM_RETRIES attempts!${NC}"
    exit 1
fi

echo -e "${YELLOW}Waiting for ALB Controller pods to start...${NC}"
sleep 45

echo -e "${CYAN}Verifying ALB Controller installation...${NC}"
kubectl get pods -n azure-alb-system
kubectl get gatewayclass

# Step 5: Setup RBAC permissions
echo -e "\n${GREEN}[Step 5/7] Setting up RBAC permissions...${NC}"
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP_NAME" --name "azure-alb-identity" --query principalId -o tsv)
NODE_RESOURCE_GROUP="MC_${RESOURCE_GROUP_NAME}_${CLUSTER_NAME}_${LOCATION}"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo -e "${CYAN}  Assigning Reader role on node resource group...${NC}"
az role assignment create --assignee "$IDENTITY_PRINCIPAL_ID" --role "Reader" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$NODE_RESOURCE_GROUP" 2>/dev/null

echo -e "${CYAN}  Assigning Contributor role on node resource group...${NC}"
az role assignment create --assignee "$IDENTITY_PRINCIPAL_ID" --role "Contributor" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$NODE_RESOURCE_GROUP" 2>/dev/null

echo -e "${GREEN}RBAC permissions configured.${NC}"

# Step 6: Deploy sample application
echo -e "\n${GREEN}[Step 6/7] Deploying sample application...${NC}"
sed "s|<SUBNET_ID>|$APPGW_SUBNET_ID|g" sample-app-alb-managed.yaml > sample-app-alb-managed-configured.yaml

kubectl apply -f sample-app-alb-managed-configured.yaml

echo -e "${YELLOW}Waiting for application pods to start...${NC}"
sleep 20
kubectl get pods -n demo

# Step 7: Wait for traffic controller and configure permissions
echo -e "\n${GREEN}[Step 7/7] Waiting for ALB Controller to create traffic controller...${NC}"
echo -e "${YELLOW}This may take 5-10 minutes. The ALB Controller will:${NC}"
echo -e "${GRAY}  1. Read the ApplicationLoadBalancer CRD${NC}"
echo -e "${GRAY}  2. Create a traffic controller with auto-generated name (e.g., alb-xyz123)${NC}"
echo -e "${GRAY}  3. Create frontend and association${NC}"
echo -e "${GRAY}  4. Update the Gateway with external address${NC}\n"

MAX_RETRIES=20
RETRY_COUNT=0
TRAFFIC_CONTROLLER_ID=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    sleep 30
    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    echo -e "${CYAN}[$RETRY_COUNT/$MAX_RETRIES] Checking for traffic controller...${NC}"
    
    # Get the full ApplicationLoadBalancer status and extract traffic controller ID
    DEPLOYMENT_MESSAGE=$(kubectl get applicationloadbalancer alb-demo -n demo -o jsonpath='{.status.conditions[?(@.type=="Deployment")].message}' 2>/dev/null)
    
    if [[ "$DEPLOYMENT_MESSAGE" =~ alb-id=(.+) ]]; then
        TRAFFIC_CONTROLLER_ID="${BASH_REMATCH[1]}"
        echo -e "${GREEN}Traffic controller created: $TRAFFIC_CONTROLLER_ID${NC}"
        break
    fi
done

if [ -z "$TRAFFIC_CONTROLLER_ID" ]; then
    echo -e "\n${YELLOW}Polling timeout reached. Attempting one final check...${NC}"
    
    # Final attempt to get traffic controller ID
    DEPLOYMENT_MESSAGE=$(kubectl get applicationloadbalancer alb-demo -n demo -o jsonpath='{.status.conditions[?(@.type=="Deployment")].message}' 2>/dev/null)
    if [[ "$DEPLOYMENT_MESSAGE" =~ alb-id=(.+) ]]; then
        TRAFFIC_CONTROLLER_ID="${BASH_REMATCH[1]}"
        echo -e "${GREEN}Traffic controller found: $TRAFFIC_CONTROLLER_ID${NC}"
    fi
fi

if [ -n "$TRAFFIC_CONTROLLER_ID" ]; then
    echo -e "\n${CYAN}Configuring traffic controller permissions and Gateway annotations...${NC}"
    
    # Assign AppGw for Containers Configuration Manager role
    echo -e "${CYAN}  Assigning AppGw Configuration Manager role...${NC}"
    az role assignment create --assignee "$IDENTITY_PRINCIPAL_ID" --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" --scope "$TRAFFIC_CONTROLLER_ID" --output json 2>/dev/null >/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  ✓ Role assigned successfully${NC}"
    else
        echo -e "${YELLOW}  ! Role may already exist${NC}"
    fi
    
    # Add annotations to Gateway
    echo -e "${CYAN}  Adding Gateway annotations...${NC}"
    kubectl annotate gateway gateway-demo -n demo alb.networking.azure.io/alb-namespace=demo alb.networking.azure.io/alb-name=alb-demo --overwrite 2>/dev/null >/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  ✓ Annotations added successfully${NC}"
    else
        echo -e "${YELLOW}  ! Failed to add annotations${NC}"
    fi
    
    echo -e "\n${YELLOW}Waiting for ALB Controller to reconcile (60 seconds)...${NC}"
    sleep 60
else
    echo -e "\n${YELLOW}Warning: Traffic controller not found.${NC}"
    echo -e "${YELLOW}The ALB Controller may still be creating it. Check status with:${NC}"
    echo -e "${WHITE}  kubectl get applicationloadbalancer alb-demo -n demo -o yaml${NC}"
fi

# Final status check
echo -e "\n${CYAN}========================================"
echo -e "  Deployment Summary"
echo -e "========================================${NC}\n"

echo -e "${GREEN}Gateway Status:${NC}"
kubectl get gateway -n demo

echo -e "\n${GREEN}ApplicationLoadBalancer Status:${NC}"
kubectl get applicationloadbalancer -n demo

echo -e "\n${GREEN}Application Pods:${NC}"
kubectl get pods -n demo

GATEWAY_ADDRESS=$(kubectl get gateway gateway-demo -n demo -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)

if [ -n "$GATEWAY_ADDRESS" ]; then
    echo -e "\n${GREEN}========================================"
    echo -e "  SUCCESS!"
    echo -e "========================================${NC}"
    echo -e "\n${YELLOW}External URL: http://$GATEWAY_ADDRESS${NC}"
    echo -e "\n${CYAN}Test the application:${NC}"
    echo -e "${WHITE}  curl http://$GATEWAY_ADDRESS${NC}"
else
    echo -e "\n${YELLOW}Gateway address not yet available. Wait a few more minutes and check:${NC}"
    echo -e "${WHITE}  kubectl get gateway gateway-demo -n demo${NC}"
fi

echo -e "\n${CYAN}Key Features of ALB-Managed Deployment:${NC}"
echo -e "${WHITE}  ✓ Traffic controller auto-created by ALB Controller${NC}"
echo -e "${WHITE}  ✓ Auto-generated resource names (e.g., alb-xyz123)${NC}"
echo -e "${WHITE}  ✓ Gateway references ApplicationLoadBalancer via annotations${NC}"
echo -e "${WHITE}  ✓ ALB Controller manages Azure resource lifecycle${NC}"
