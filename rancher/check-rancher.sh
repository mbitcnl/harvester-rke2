#!/bin/bash
# Script om de status van Rancher te controleren nadat de installatie is gestart

# Configuratie
KUBECONFIG="../rke2-direct.yaml"
RANCHER_IP="10.10.11.52"
NAMESPACE="cattle-system"

# Exporteer KUBECONFIG
export KUBECONFIG=$KUBECONFIG

echo "==== Rancher Status Checker ===="
echo "Dit script controleert de status van de Rancher installatie"
echo

# Controleer of pods bestaan
echo "Controleren of Rancher pods bestaan..."
if ! kubectl get pods -n $NAMESPACE 2>/dev/null | grep -q "rancher"; then
  echo "Nog geen Rancher pods gevonden. De installatie kan nog bezig zijn."
  echo "Probeer het later opnieuw. De installatie kan tot 10-15 minuten duren."
  exit 1
fi

# Toon pod status
echo "Rancher pod status:"
kubectl get pods -n $NAMESPACE -l app=rancher -o wide

# Controleer service
echo
echo "Rancher service status:"
kubectl get svc -n $NAMESPACE -l app=rancher

# Controleer of LoadBalancer IP is toegewezen
LOADBALANCER_IP=$(kubectl get svc -n $NAMESPACE rancher -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$LOADBALANCER_IP" ]; then
  echo
  echo "LoadBalancer IP is nog niet toegewezen. MetalLB kan nog bezig zijn."
else
  echo
  echo "LoadBalancer IP toegewezen: $LOADBALANCER_IP"
  
  # Controleer of de service bereikbaar is
  echo "Controleren of Rancher UI bereikbaar is (kan nog niet beschikbaar zijn)..."
  if curl -k -s -o /dev/null -w "%{http_code}" https://$LOADBALANCER_IP:8443 2>/dev/null | grep -q "200\|302\|301"; then
    echo "Rancher UI is bereikbaar! Je kunt inloggen op:"
    echo "  https://$LOADBALANCER_IP:8443"
  else
    echo "Rancher UI is nog niet bereikbaar op https://$LOADBALANCER_IP:8443"
    echo "Dit is normaal als de installatie nog bezig is."
  fi
fi

echo
echo "Rancher bootstrap status:"
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null || echo "Bootstrap secret nog niet aangemaakt."

echo
echo "==== Controleer later opnieuw voor volledige beschikbaarheid ===="
echo "Rancher kan tot 15 minuten nodig hebben om volledig beschikbaar te zijn."
echo "Controleer nogmaals met dit script over enkele minuten."
echo "Wanneer beschikbaar, log in op https://$RANCHER_IP:8443" 