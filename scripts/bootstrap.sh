#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ARGOCD_NAMESPACE="argocd"
HELM_REPO_URL="https://github.com/microservices-project-k8s-jenkins/ecommerce-charts.git"
ARGOCD_VERSION="stable"

log_info() {
    echo -e "${BLUE}$1${NC}"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi
    if ! command -v helm &> /dev/null; then
        log_warning "helm is not installed (optional)"
    fi
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    log_success "Prerequisites check passed"
}

install_argocd() {
    log_info "Installing ArgoCD..."
    kubectl create namespace $ARGOCD_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml
    log_info "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n $ARGOCD_NAMESPACE
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-application-controller -n $ARGOCD_NAMESPACE
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-repo-server -n $ARGOCD_NAMESPACE
    log_success "ArgoCD installed successfully"
}

configure_argocd() {
    log_info "Configuring ArgoCD..."
    kubectl apply -f bootstrap/argocd-config.yaml
    kubectl rollout restart deployment/argocd-server -n $ARGOCD_NAMESPACE
    kubectl rollout status deployment/argocd-server -n $ARGOCD_NAMESPACE
    log_success "ArgoCD configured"
}

create_app_of_apps() {
    log_info "Creating App of Apps..."
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: $ARGOCD_NAMESPACE
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $HELM_REPO_URL
    targetRevision: HEAD
    path: argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: $ARGOCD_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
EOF
    log_success "App of Apps created"
}

get_argocd_credentials() {
    log_info "Getting ArgoCD credentials..."
    ARGOCD_PASSWORD=$(kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    PORT_FORWARD_PID=$!
    sleep 5
    echo ""
    echo "ArgoCD Bootstrap Complete"
    echo "========================="
    echo "ArgoCD URL: https://localhost:8080"
    echo "Username: admin"
    echo "Password: $ARGOCD_PASSWORD"
    echo ""
    echo "Next steps:"
    echo "1. Access ArgoCD UI at https://localhost:8080"
    echo "2. Login with the credentials above"
    echo "3. Verify that the 'app-of-apps' application is synced"
    echo "4. Check that your applications are created"
    echo ""
}

verify_installation() {
    log_info "Verifying installation..."
    if kubectl get pods -n $ARGOCD_NAMESPACE | grep -q "Running"; then
        log_success "ArgoCD pods are running"
    else
        log_error "Some ArgoCD pods are not running"
        kubectl get pods -n $ARGOCD_NAMESPACE
        return 1
    fi
    if kubectl get application app-of-apps -n $ARGOCD_NAMESPACE &> /dev/null; then
        log_success "App of Apps created successfully"
    else
        log_warning "App of Apps not found - you may need to create it manually"
    fi
    log_success "Installation verification complete"
}

cleanup() {
    if [[ ! -z "$PORT_FORWARD_PID" ]]; then
        kill $PORT_FORWARD_PID 2>/dev/null || true
    fi
}

trap cleanup EXIT

main() {
    echo "ArgoCD Bootstrap Script"
    echo "========================"
    echo ""
    check_prerequisites
    install_argocd
    configure_argocd
    create_app_of_apps
    verify_installation
    get_argocd_credentials
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  -n, --namespace      ArgoCD namespace (default: argocd)"
    echo "  -r, --repo           Helm charts repository URL"
    echo "  -v, --version        ArgoCD version (default: stable)"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 -r https://github.com/my/repo.git"
    echo "  $0 -n argocd-system"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -n|--namespace)
            ARGOCD_NAMESPACE="$2"
            shift 2
            ;;
        -r|--repo)
            HELM_REPO_URL="$2"
            shift 2
            ;;
        -v|--version)
            ARGOCD_VERSION="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

main
