#!/usr/bin/env bash
# setup-k3s.sh — Install and configure k3s on a VPS for AxiomNode
set -euo pipefail

NAMESPACE_DEV="axiomnode-dev"
NAMESPACE_STG="axiomnode-stg"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.35"
LOCAL_PATH_PROVISIONER_MANIFEST_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

echo "=== AxiomNode k3s Setup ==="

# 1. Install k3s (if not already installed)
if ! command -v k3s &>/dev/null; then
  echo "[1/7] Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable servicelb \
    --disable local-storage
  echo "k3s installed successfully."
else
  echo "[1/7] k3s already installed, skipping."
fi

# 2. Wait for k3s to be ready
echo "[2/7] Waiting for k3s to be ready..."
sleep 10
k3s kubectl wait --for=condition=Ready node --all --timeout=120s

# 3. Set up kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "[3/7] KUBECONFIG set to $KUBECONFIG"

# 4. Install local-path provisioner if no default storage class is set
echo "[4/7] Ensuring default storage class..."
DEFAULT_SC=$(k3s kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' || true)
if [[ -z "$DEFAULT_SC" ]]; then
  k3s kubectl apply -f "$LOCAL_PATH_PROVISIONER_MANIFEST_URL"
  k3s kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
  echo "Default storage class set to local-path."
else
  echo "Default storage class already set: $DEFAULT_SC"
fi

# 5. Install Sealed Secrets controller
echo "[5/7] Installing Sealed Secrets controller..."
k3s kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml

# 6. Create namespaces
echo "[6/7] Creating namespaces..."
k3s kubectl create namespace "$NAMESPACE_DEV" --dry-run=client -o yaml | k3s kubectl apply -f -
k3s kubectl create namespace "$NAMESPACE_STG" --dry-run=client -o yaml | k3s kubectl apply -f -

# 7. Apply base configuration
echo "[7/7] Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Create secrets:  ./seal-secrets.sh dev"
echo "  2. Deploy dev:      k3s kubectl apply -k kubernetes/overlays/dev/"
echo "  3. Deploy stg:      k3s kubectl apply -k kubernetes/overlays/stg/"
echo ""
echo "Traefik dashboard: http://<VPS_IP>:9000/dashboard/"
