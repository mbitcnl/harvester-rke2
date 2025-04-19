#!/bin/bash
# Script om de Rancher installatie te debuggen door logs te bekijken

# Configuratie
KUBECONFIG="../rke2-direct.yaml"
NAMESPACE="cattle-system"
CERT_MANAGER_NS="cert-manager"

# Exporteer KUBECONFIG
export KUBECONFIG=$KUBECONFIG

echo "==== Rancher Debug Tool ===="
echo "Dit script verzamelt debug informatie over de Rancher installatie"
echo

# Check Kubernetes connectie
echo "Controleren van Kubernetes verbinding..."
if ! kubectl get nodes &>/dev/null; then
  echo "FOUT: Kan geen verbinding maken met Kubernetes API server!"
  echo "Controleer of je kubeconfig correct is: $KUBECONFIG"
  exit 1
fi

# Check namespaces
echo "Controleren van namespaces..."
kubectl get namespaces | grep -E "cattle-system|cert-manager|kube-system"

# Check Cattle-System resources
echo -e "\nControleren van resources in cattle-system namespace..."
echo "Pods:"
kubectl get pods -n $NAMESPACE

echo -e "\nServices:"
kubectl get svc -n $NAMESPACE

echo -e "\nDeployments:"
kubectl get deploy -n $NAMESPACE

echo -e "\nIngresses:"
kubectl get ingress -n $NAMESPACE

echo -e "\nSecrets:"
kubectl get secrets -n $NAMESPACE | grep -v "token"

# Check Cert-Manager resources
echo -e "\nControleren van cert-manager resources..."
echo "Pods:"
kubectl get pods -n $CERT_MANAGER_NS

echo -e "\nCertificates:"
kubectl get certificates --all-namespaces

echo -e "\nCertificate requests:"
kubectl get certificaterequests --all-namespaces

echo -e "\nIssuers & ClusterIssuers:"
kubectl get issuers --all-namespaces
kubectl get clusterissuers --all-namespaces

# Check MetalLB resources
echo -e "\nControleren van MetalLB resources..."
kubectl get pods -n metallb-system

# Check logs
echo -e "\n==== Rancher Logs ===="
# Vind de rancher pods
RANCHER_PODS=$(kubectl get pods -n $NAMESPACE -l app=rancher -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$RANCHER_PODS" ]; then
  echo "Geen Rancher pods gevonden!"
else
  for pod in $RANCHER_PODS; do
    echo -e "\nLogs van $pod:"
    kubectl logs -n $NAMESPACE $pod --tail=50
    
    # Container status
    echo -e "\nStatus van containers in $pod:"
    kubectl describe pod -n $NAMESPACE $pod | grep -A 10 "Containers:"
  done
fi

# Check Cert-Manager logs
echo -e "\n==== Cert-Manager Logs ===="
CERT_MANAGER_POD=$(kubectl get pods -n $CERT_MANAGER_NS -l app=cert-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$CERT_MANAGER_POD" ]; then
  echo -e "\nLogs van cert-manager controller:"
  kubectl logs -n $CERT_MANAGER_NS $CERT_MANAGER_POD --tail=30
fi

# Check voor bekende problemen
echo -e "\n==== Bekende Problemen Controle ===="

echo "1. Controleren van MetalLB configuratie..."
if ! kubectl get configmap -n metallb-system config &>/dev/null; then
  echo "WAARSCHUWING: Geen MetalLB configmap gevonden! LoadBalancer IP toewijzing werkt mogelijk niet."
fi

echo "2. Controleren van Rancher rollout status..."
kubectl rollout status deployment -n $NAMESPACE rancher --timeout=5s 2>/dev/null || echo "Rancher deployment is nog niet gereed"

echo "3. Controleren van endpoints..."
echo "Rancher service endpoints:"
kubectl get endpoints -n $NAMESPACE rancher

echo -e "\n==== Debug Tips ===="
echo "1. Als pods in CrashLoopBackOff zijn, bekijk dan de logs met: kubectl logs -n $NAMESPACE [pod-name]"
echo "2. Als er certificaatproblemen zijn, controleer de cert-manager logs"
echo "3. Als LoadBalancer IP niet wordt toegewezen, controleer of MetalLB correct is geconfigureerd"
echo "4. Rancher installeert vele custom resources - het kan tijd nodig hebben (10-15 min)"
echo 
echo "Voor handmatige installatie zonder Terraform, probeer:"
echo "helm install rancher rancher-latest/rancher \\"
echo "  --namespace cattle-system \\"
echo "  --set hostname=rancher.dc1.mademy.nl \\"
echo "  --set bootstrapPassword=<wachtwoord> \\"
echo "  --set tls=external \\"
echo "  --set ingress.enabled=false \\"
echo "  --set service.type=LoadBalancer" 