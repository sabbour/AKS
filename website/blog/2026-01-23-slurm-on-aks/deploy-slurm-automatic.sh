#!/bin/bash
set -euo pipefail

# =============================================================================
# Slurm on AKS Automatic Deployment Script
# Deploys Slurm with Slinky operator on Azure Kubernetes Service Automatic
# Uses --sku automatic with --enable-hosted-system for managed system node pools
#
# PREREQUISITES (preview feature):
# - Azure CLI version 2.77.0 or later
# - aks-preview extension version 19.0.0b15 or later
# - AKS-AutomaticHostedSystemProfilePreview feature flag registered
#
# REGION AVAILABILITY:
# australiacentral, australiaeast, australiasoutheast, brazilsouth,
# canadacentral, centralindia, centralus, chilecentral, eastasia,
# francecentral, germanywestcentral, italynorth, japanwest, koreasouth,
# mexicocentral, newzealandnorth, northeurope, polandcentral, southcentralus,
# southeastasia, southindia, spaincentral, swedencentral, switzerlandnorth,
# uksouth, westcentralus, westeurope, westus2, westus3
#
# LIMITATIONS:
# - Windows nodes aren't supported
# - Istio-based service mesh add-on isn't supported
# - Custom VNet isn't supported with managed system node pools
# =============================================================================

echo "=========================================="
echo "Slurm on AKS Automatic Deployment Script"
echo "=========================================="

# -----------------------------------------------------------------------------
# Prerequisites Check
# -----------------------------------------------------------------------------
echo "Checking prerequisites..."

# Check Azure CLI version (requires 2.77.0+)
AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0.0")
echo "  Azure CLI version: $AZ_VERSION"

# Install/update aks-preview extension
echo "  Installing/updating aks-preview extension..."
az extension add --name aks-preview --allow-preview true 2>/dev/null || \
  az extension update --name aks-preview --allow-preview true 2>/dev/null || true

# Check if AKS-AutomaticHostedSystemProfilePreview feature flag is registered
FEATURE_STATE=$(az feature show --namespace Microsoft.ContainerService \
  --name AKS-AutomaticHostedSystemProfilePreview \
  --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")

if [[ "$FEATURE_STATE" != "Registered" ]]; then
  echo "  Registering AKS-AutomaticHostedSystemProfilePreview feature flag..."
  az feature register --namespace Microsoft.ContainerService \
    --name AKS-AutomaticHostedSystemProfilePreview --output none
  
  echo "  Waiting for feature registration (this may take a few minutes)..."
  while [[ "$FEATURE_STATE" != "Registered" ]]; do
    sleep 30
    FEATURE_STATE=$(az feature show --namespace Microsoft.ContainerService \
      --name AKS-AutomaticHostedSystemProfilePreview \
      --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")
    echo "    Feature state: $FEATURE_STATE"
  done
  
  # Refresh the registration
  az provider register --namespace Microsoft.ContainerService --output none
fi

# Check if ManagedGPUExperiencePreview feature flag is registered
GPU_FEATURE_STATE=$(az feature show --namespace Microsoft.ContainerService \
  --name ManagedGPUExperiencePreview \
  --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")

if [[ "$GPU_FEATURE_STATE" != "Registered" ]]; then
  echo "  Registering ManagedGPUExperiencePreview feature flag..."
  az feature register --namespace Microsoft.ContainerService \
    --name ManagedGPUExperiencePreview --output none
  
  echo "  Waiting for GPU feature registration (this may take a few minutes)..."
  while [[ "$GPU_FEATURE_STATE" != "Registered" ]]; do
    sleep 30
    GPU_FEATURE_STATE=$(az feature show --namespace Microsoft.ContainerService \
      --name ManagedGPUExperiencePreview \
      --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")
    echo "    GPU Feature state: $GPU_FEATURE_STATE"
  done
  
  # Refresh the registration
  az provider register --namespace Microsoft.ContainerService --output none
fi

echo "  ✓ Prerequisites verified"
echo ""

# -----------------------------------------------------------------------------
# Configuration - Modify these variables as needed
# -----------------------------------------------------------------------------
export RESOURCE_GROUP="${RESOURCE_GROUP:-aks-slurm-rg}"
export CLUSTER_NAME="${CLUSTER_NAME:-aks-slurm-automatic}"
export LOCATION="${LOCATION:-uksouth}"

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster Name:   $CLUSTER_NAME"
echo "  Location:       $LOCATION"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Create Resource Group and AKS Automatic Cluster
# -----------------------------------------------------------------------------
echo "Step 1: Creating resource group and AKS Automatic cluster..."

az group create --name $RESOURCE_GROUP --location $LOCATION --output none

echo "  Creating AKS Automatic cluster with hosted system node pool..."

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --sku automatic \
  --enable-hosted-system \
  --output none

az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing

echo "  ✓ AKS Automatic cluster created and credentials configured"

# Verify cluster nodes
echo "  Verifying cluster nodes..."
kubectl get nodes

# -----------------------------------------------------------------------------
# Step 2: Configure Node Auto Provisioning NodePool for GPUs
# -----------------------------------------------------------------------------
echo "Step 2: Creating NAP NodePool for GPU workers..."

# GPU NodePool
kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: slurm-gpu
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: slurm-gpu
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.azure.com/sku-gpu-manufacturer
          operator: In
          values: ["nvidia"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
  limits:
    nvidia.com/gpu: 100
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 10m
---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: slurm-gpu
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 256
  tags:
    EnabledManagedGPUExperience: "true"
EOF

echo "  ✓ NAP NodePool created"
echo "  Note: AKS Managed GPU nodes automatically installs GPU drivers and device plugin"

# Enable DCGM exporter metrics scraping for Azure Monitor
echo "  Enabling DCGM exporter metrics scraping..."
kubectl apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
data:
  schema-version:
    v1
  config-version:
    ver1
  default-scrape-settings-enabled: |-
    dcgmexporter = true
metadata:
  name: ama-metrics-settings-configmap
  namespace: kube-system
EOF
echo "  ✓ DCGM exporter metrics scraping enabled"

# -----------------------------------------------------------------------------
# Step 3: Install Slinky Operator
# -----------------------------------------------------------------------------
echo "Step 3: Installing Slinky operator..."

helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --wait

helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --set 'certManager.enabled=false' \
  --namespace slinky \
  --create-namespace \
  --wait

echo "  ✓ Slinky operator installed"

# -----------------------------------------------------------------------------
# Step 4: Deploy MySQL for job accounting
# -----------------------------------------------------------------------------
echo "Step 4: Deploying MySQL in the cluster..."

# Set MySQL credentials
export MYSQL_ADMIN_USER="slurmadmin"
export MYSQL_ADMIN_PASSWORD="$(openssl rand -base64 24)"

# Save credentials
echo "$MYSQL_ADMIN_PASSWORD" > mysql-password.txt
chmod 600 mysql-password.txt
echo "  MySQL password saved to mysql-password.txt"

# Create the Slurm namespace
kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -

# Create MySQL password secret
kubectl create secret generic mysql-secret \
  --namespace slurm \
  --from-literal=mysql-root-password="$MYSQL_ADMIN_PASSWORD" \
  --from-literal=mysql-password="$MYSQL_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy MySQL
kubectl apply -n slurm -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi
  resources:
    requests:
      storage: 32Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-root-password
            - name: MYSQL_DATABASE
              value: slurm_acct_db
            - name: MYSQL_USER
              value: "$MYSQL_ADMIN_USER"
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: mysql-password
          ports:
            - containerPort: 3306
          volumeMounts:
            - name: mysql-storage
              mountPath: /var/lib/mysql
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 4Gi
      volumes:
        - name: mysql-storage
          persistentVolumeClaim:
            claimName: mysql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
  type: ClusterIP
EOF

# Wait for MySQL to be ready
echo "  Waiting for MySQL to be ready..."
kubectl wait --for=condition=Available deployment/mysql -n slurm --timeout=300s

# Set MySQL FQDN for Slurm configuration
export MYSQL_FQDN="mysql.slurm.svc.cluster.local"

echo "  MySQL host: $MYSQL_FQDN"
echo "  ✓ MySQL deployed in cluster"

# -----------------------------------------------------------------------------
# Step 5: Set up shared storage
# -----------------------------------------------------------------------------
echo "Step 5: Setting up shared storage..."

# Note: For higher performance workloads, consider using Azure Managed Lustre
# instead of Azure Files. See: https://learn.microsoft.com/azure/azure-managed-lustre/

kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -

STORAGE_ACCOUNT="slurmstorage$RANDOM"
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT \
  --query "[0].value" -o tsv)

az storage share create \
  --name slurmhome \
  --account-name $STORAGE_ACCOUNT \
  --quota 100 \
  --output none

kubectl create secret generic azure-storage-secret \
  --namespace slurm \
  --from-literal=azurestorageaccountname=$STORAGE_ACCOUNT \
  --from-literal=azurestorageaccountkey=$STORAGE_KEY \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Shared storage configured"

# -----------------------------------------------------------------------------
# Step 6: Deploy Slurm cluster
# -----------------------------------------------------------------------------
echo "Step 6: Deploying Slurm cluster..."

# Create MySQL password secret
kubectl create secret generic slurm-db-secret \
  --namespace slurm \
  --from-literal=password="$MYSQL_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Helm values file
cat <<EOF > slurm-values.yaml
clusterName: aks-slurm

# Enable accounting with MySQL
accounting:
  enabled: true
  storageConfig:
    host: "$MYSQL_FQDN"
    port: 3306
    database: slurm_acct_db
    username: "$MYSQL_ADMIN_USER"
    passwordKeyRef:
      name: slurm-db-secret
      key: password

# GPU auto-detection and DCGM integration
configFiles:
  gres.conf: |
    AutoDetect=nvidia

vendor:
  nvidia:
    dcgm:
      enabled: true

# Controller persistence and metrics
controller:
  persistence:
    storageClassName: managed-csi
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

# Worker nodesets
nodesets:
  slinky:
    enabled: true
    replicas: 2
    updateStrategy:
      type: RollingUpdate
    slurmd:
      image:
        repository: ghcr.io/slinkyproject/slurmd
        tag: 25.11-ubuntu24.04
      resources:
        limits:
          cpu: 6
          memory: 32Gi
          nvidia.com/gpu: 1
      volumeMounts:
        - name: home
          mountPath: /home
        - name: shmem
          mountPath: /dev/shm
    logfile:
      image:
        repository: docker.io/library/alpine
        tag: latest
    extraConfMap:
      Gres:
        - gpu:1
    partition:
      configMap:
        State: UP
        Default: "YES"
        MaxTime: UNLIMITED
    podSpec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: home
          azureFile:
            secretName: azure-storage-secret
            shareName: slurmhome
            readOnly: false
        - name: shmem
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi

# Login nodes for job submission
loginsets:
  slinky:
    enabled: true
    login:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          azureFile:
            secretName: azure-storage-secret
            shareName: slurmhome
            readOnly: false
    service:
      spec:
        type: LoadBalancer
EOF

# Deploy Slurm
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm \
  --values slurm-values.yaml \
  --wait --timeout 10m

echo "  ✓ Slurm cluster deployed"

# -----------------------------------------------------------------------------
# Step 7: Verify deployment
# -----------------------------------------------------------------------------
echo "Step 7: Verifying deployment..."

echo "  Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n slurm --timeout=300s || true

echo ""
echo "  Pod status:"
kubectl get pods -n slurm

# -----------------------------------------------------------------------------
# Step 8: Get connection info
# -----------------------------------------------------------------------------
echo ""
echo "Step 8: Connection information"
echo "=========================================="

# Wait for LoadBalancer IP
echo "  Waiting for login service external IP..."
for i in {1..30}; do
  SLURM_LOGIN_IP=$(kubectl get services -n slurm slurm-login-slinky \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$SLURM_LOGIN_IP" ]]; then
    break
  fi
  sleep 5
done

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Cluster type: AKS Automatic with hosted system node pool"
echo ""
echo "To connect to Slurm:"
echo "  kubectl exec -it -n slurm deployment/slurm-login-slinky -- bash"
echo ""
if [[ -n "${SLURM_LOGIN_IP:-}" ]]; then
  echo "Login service IP: $SLURM_LOGIN_IP"
fi
echo ""
echo "Once connected, verify with:"
echo "  sinfo"
echo "  sinfo -N -l"
echo ""
echo "Note: Worker pods may be pending until NAP provisions GPU nodes."
echo "      If you don't have GPU quota, scale down workers:"
echo "      kubectl scale nodeset slurm-worker-slinky --replicas=0 -n slurm"
echo ""
echo "Saved files:"
echo "  - mysql-password.txt (MySQL admin password)"
echo "  - slurm-values.yaml (Helm values)"
echo ""
