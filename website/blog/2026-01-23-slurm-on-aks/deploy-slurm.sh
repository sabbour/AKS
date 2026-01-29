#!/bin/bash
set -euo pipefail

# =============================================================================
# Slurm on AKS Deployment Script
# Deploys Slurm with Slinky operator on Azure Kubernetes Service
# =============================================================================

echo "=========================================="
echo "Slurm on AKS Deployment Script"
echo "=========================================="

# -----------------------------------------------------------------------------
# Configuration - Modify these variables as needed
# -----------------------------------------------------------------------------
export RESOURCE_GROUP="${RESOURCE_GROUP:-aks-slurm-rg}"
export CLUSTER_NAME="${CLUSTER_NAME:-aks-slurm-cluster}"
export LOCATION="${LOCATION:-swedencentral}"
export VNET_NAME="${VNET_NAME:-aks-slurm-vnet}"

echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster Name:   $CLUSTER_NAME"
echo "  Location:       $LOCATION"
echo "  VNet Name:      $VNET_NAME"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Create Resource Group and VNet
# -----------------------------------------------------------------------------
echo "Step 1: Creating resource group and virtual network..."

az group create --name $RESOURCE_GROUP --location $LOCATION --output none

az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefix 10.0.0.0/8 \
  --subnet-name aks-subnet \
  --subnet-prefix 10.240.0.0/16 \
  --output none

AKS_SUBNET_ID=$(az network vnet subnet show \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name aks-subnet \
  --query id -o tsv)

echo "  ✓ Resource group and VNet created"

echo "  Creating AKS cluster with Node Auto Provisioning..."

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --node-provisioning-mode Auto \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --vnet-subnet-id $AKS_SUBNET_ID \
  --output none

az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing

echo "  ✓ AKS cluster created and credentials configured"

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
EOF

echo "  ✓ NAP NodePools created"

# Install NVIDIA device plugin for GPU discovery
echo "  Installing NVIDIA device plugin..."
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/main/deployments/static/nvidia-device-plugin.yml
echo "  ✓ NVIDIA device plugin installed"

# -----------------------------------------------------------------------------
# Step 3: Install cert-manager
# -----------------------------------------------------------------------------
echo "Step 3: Installing cert-manager..."

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --set 'crds.enabled=true' \
  --namespace cert-manager \
  --create-namespace \
  --wait

echo "  ✓ cert-manager installed"

# -----------------------------------------------------------------------------
# Step 4: Install Slinky Operator
# -----------------------------------------------------------------------------
echo "Step 4: Installing Slinky operator..."

helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --wait

helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace slinky \
  --create-namespace \
  --wait

echo "  ✓ Slinky operator installed"

# -----------------------------------------------------------------------------
# Step 5: Deploy MySQL for job accounting
# -----------------------------------------------------------------------------
echo "Step 5: Deploying MySQL in the cluster..."

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
# Step 6: Set up shared storage
# -----------------------------------------------------------------------------
echo "Step 6: Setting up shared storage..."

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
# Step 7: Deploy Slurm cluster
# -----------------------------------------------------------------------------
echo "Step 7: Deploying Slurm cluster..."

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
# Step 8: Verify deployment
# -----------------------------------------------------------------------------
echo "Step 8: Verifying deployment..."

echo "  Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n slurm --timeout=300s || true

echo ""
echo "  Pod status:"
kubectl get pods -n slurm

# -----------------------------------------------------------------------------
# Step 9: Get connection info
# -----------------------------------------------------------------------------
echo ""
echo "Step 9: Connection information"
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
