#!/bin/bash -eu

# Check if docker is installed
if ! command -v docker &> /dev/null
then
    echo "docker could not be found. Please, install it and try again"
    exit
fi

mkdir -p ~/.local/bin

# Check if kind is installed
if ! command -v kind &> /dev/null
then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
    chmod +x ./kind
    mv ./kind ~/.local/bin/
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null
then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x ./kubectl
    mv ./kubectl ~/.local/bin/
fi

# Check if helm is installed
if ! command -v helm &> /dev/null
then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Check if helm-diff plugin needed by helmfile is installed
if ! grep "^diff\\s" <(helm plugin list) &> /dev/null
then
    helm plugin install https://github.com/databus23/helm-diff
fi

# Check if helmfile is installed
if ! command -v helmfile &> /dev/null
then
    curl -Lo ./helmfile https://github.com/roboll/helmfile/releases/download/v0.142.0/helmfile_linux_amd64
    chmod +x ./helmfile
    mv ./helmfile ~/.local/bin/
fi

# create registry container unless it already exists
running="$(docker inspect -f '{{.State.Running}}' "kind-registry" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:5000:5000" --name "kind-registry" \
    registry:2
fi

# Create cluster container unless it already exists
running="$(docker inspect -f '{{.State.Running}}' "kind-control-plane" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  host_ip=`hostname -I | awk '{print $1}'`
  cat <<EOF | kind create cluster --image kindest/node:v1.22.0 --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
networking:
  apiServerAddress: "${host_ip}"
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
    endpoint = ["http://kind-registry:5000"]
EOF
fi

# connect the registry to the cluster network
# (the network may already be connected)
docker network connect "kind" "kind-registry" || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Install nginx as ingress controler
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# Install helmfile with other installs
helmfile apply
