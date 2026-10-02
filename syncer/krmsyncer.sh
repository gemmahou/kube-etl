#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# krmsyncer.sh deploys the KRMSyncer controller and a sample KRMSyncer CR into
# a destination GKE cluster.
#
# Steps:
#   1. Configure Workload Identity (GSA, IAM bindings) for the controller.
#   2. Build and push the controller image, unless --image already exists in the registry.
#   3. Create the source-cluster kubeconfig Secret on the destination cluster.
#   4. Deploy the CRD, RBAC and controller into the destination cluster.
#   5. Apply a sample KRMSyncer CR.

set -euo pipefail

# Controller deployment constants (must match config/).
readonly CONTROLLER_NAMESPACE="krmsyncer-system"
readonly CONTROLLER_KSA="krmsyncer-controller-manager"
readonly CONTROLLER_DEPLOYMENT="krmsyncer-controller-manager"
# Placeholder image in config/manager/manager.yaml; deploy_controller replaces
# it with ${IMAGE} in the rendered manifests.
readonly IMAGE_PLACEHOLDER="controller:latest"
readonly GSA_NAME="krmsyncer"
readonly SOURCE_SECRET_NAME="source-cluster"
readonly KRMSYNCER_CRD="krmsyncers.syncer.gkelabs.io"
readonly SYNC_CONFIG_NAME="kcc-resource-syncer"

# The script lives in the syncer module directory, which holds the Dockerfile
# and config/. Resolve it so the script can be run from anywhere.
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_DIR
# YAML templates with ${VAR} placeholders, rendered by render_template.
readonly TEMPLATES_DIR="${MODULE_DIR}/config/templates"

# --- Logging helpers ---------------------------------------------------------

log_info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_success() { printf '\033[1;32m[SUCCESS]\033[0m %s\n' "$*"; }
log_warn()    { printf '\033[1;33m[WARNING]\033[0m %s\n' "$*"; }
log_error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_header()  { printf '\n--- %s ---\n' "$*"; }
die()         { log_error "$*"; exit 1; }

# quiet runs a command, discarding its output. On failure, the combined output
# is printed and the script exits.
quiet() {
  local out
  if ! out="$("$@" 2>&1)"; then
    die "$* failed:"$'\n'"${out}"
  fi
}

# render_template TEMPLATE KEY=VALUE... prints TEMPLATE with each ${KEY}
# placeholder replaced by VALUE. Fails if any ${...} placeholder is left unfilled.
render_template() {
  local template="$1"
  shift
  [[ -f "${template}" ]] || die "template not found: ${template}"
  local content kv key value
  content="$(<"${template}")"
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    # Quoting the pattern and replacement makes both literal (no glob or '&' expansion).
    content="${content//"\${${key}}"/"${value}"}"
  done
  if [[ "${content}" =~ \$\{[A-Za-z_][A-Za-z0-9_]*\} ]]; then
    die "unfilled placeholder ${BASH_REMATCH[0]} in ${template}"
  fi
  printf '%s\n' "${content}"
}

usage() {
  cat <<EOF
Deploy the KRMSyncer controller and a sample KRMSyncer CR into the destination cluster.

Usage:
  $(basename "$0") --source-cluster NAME --source-location LOC \\
    --dest-cluster NAME --dest-location LOC --project PROJECT \\
    [--namespace NS] [--image IMAGE]

Flags:
      --source-cluster   Name of the source cluster (required)
      --source-location  GCP location for the source cluster, e.g. us-west1 (required)
      --dest-cluster     Name of the destination cluster (required)
      --dest-location    GCP location for the destination cluster, e.g. us-central1 (required)
      --project          Google Cloud project of both clusters (required)
  -n, --namespace        Namespace for the KRMSyncer CR and source-cluster Secret (default: ${CONTROLLER_NAMESPACE})
  -i, --image            Controller image to deploy. If it already exists in the registry it is
                         used as is; otherwise it is built and pushed.
                         (default: build and push gcr.io/<project>/krmsyncer/controller:latest)
  -h, --help             Show this help

Example:
  $(basename "$0") --source-cluster src --source-location us-west1 \\
    --dest-cluster dst --dest-location us-central1 --project my-project
EOF
}

# --- Flag parsing ------------------------------------------------------------

SOURCE_CLUSTER=""
SOURCE_LOCATION=""
DEST_CLUSTER=""
DEST_LOCATION=""
PROJECT=""
NAMESPACE="${CONTROLLER_NAMESPACE}"
IMAGE=""

parse_flags() {
  while [[ $# -gt 0 ]]; do
    local flag="$1"
    case "${flag}" in
      -h|--help) usage; exit 0 ;;
      --*=*)
        # Support --flag=value by splitting it into --flag value.
        set -- "${flag%%=*}" "${flag#*=}" "${@:2}"
        continue
        ;;
    esac
    case "${flag}" in
      --source-cluster|--source-location|--dest-cluster|--dest-location|--project|-n|--namespace|-i|--image) ;;
      *) usage >&2; die "unknown flag: ${flag}" ;;
    esac
    [[ $# -ge 2 ]] || die "flag ${flag} requires a value"
    case "${flag}" in
      --source-cluster)     SOURCE_CLUSTER="$2" ;;
      --source-location)    SOURCE_LOCATION="$2" ;;
      --dest-cluster)       DEST_CLUSTER="$2" ;;
      --dest-location)      DEST_LOCATION="$2" ;;
      --project)            PROJECT="$2" ;;
      -n|--namespace)       NAMESPACE="$2" ;;
      -i|--image)           IMAGE="$2" ;;
    esac
    shift 2
  done

  local missing=()
  [[ -n "${SOURCE_CLUSTER}" ]]  || missing+=("--source-cluster")
  [[ -n "${SOURCE_LOCATION}" ]] || missing+=("--source-location")
  [[ -n "${DEST_CLUSTER}" ]]    || missing+=("--dest-cluster")
  [[ -n "${DEST_LOCATION}" ]]   || missing+=("--dest-location")
  [[ -n "${PROJECT}" ]]         || missing+=("--project")
  if [[ ${#missing[@]} -gt 0 ]]; then
    usage >&2
    die "required flag(s) not set: ${missing[*]}"
  fi
}

check_deps() {
  local dep
  for dep in kubectl gcloud docker; do
    command -v "${dep}" >/dev/null 2>&1 || die "dependency \"${dep}\" is required but not found; please install it"
  done
}

# --- Derived configuration ---------------------------------------------------

# complete resolves kubectl contexts and derived names.
complete() {
  [[ -f "${MODULE_DIR}/Dockerfile" && -d "${MODULE_DIR}/config/default" ]] ||
    die "${MODULE_DIR} is not the krmsyncer directory (missing Dockerfile or config/default)"

  IMAGE_FROM_FLAG="false"
  if [[ -n "${IMAGE}" ]]; then
    IMAGE_FROM_FLAG="true"
  else
    IMAGE="gcr.io/${PROJECT}/krmsyncer/controller:latest"
  fi

  # Context names created by `gcloud container clusters get-credentials`.
  SOURCE_CONTEXT="gke_${PROJECT}_${SOURCE_LOCATION}_${SOURCE_CLUSTER}"
  DEST_CONTEXT="gke_${PROJECT}_${DEST_LOCATION}_${DEST_CLUSTER}"

  GSA_EMAIL="${GSA_NAME}@${PROJECT}.iam.gserviceaccount.com"
  WI_MEMBER="serviceAccount:${PROJECT}.svc.id.goog[${CONTROLLER_NAMESPACE}/${CONTROLLER_KSA}]"
}

print_summary() {
  echo "=================================================="
  echo "          KRMSyncer Deployment Setup              "
  echo "=================================================="
  log_info "Source Cluster Context   : ${SOURCE_CONTEXT}"
  log_info "Dest Cluster Context     : ${DEST_CONTEXT}"
  log_info "GCP Project ID           : ${PROJECT}"
  log_info "Syncer CR Namespace      : ${NAMESPACE}"
  log_info "Controller Namespace     : ${CONTROLLER_NAMESPACE}"
  log_info "Controller Image         : ${IMAGE}"
  log_info "Google Service Account   : ${GSA_EMAIL}"
  log_info "Module Directory         : ${MODULE_DIR}"
  echo "=================================================="
}

# kubectl_apply applies manifests from stdin to the destination cluster.
kubectl_apply() {
  kubectl --context="${DEST_CONTEXT}" apply -f -
}

# --- Steps -------------------------------------------------------------------

configure_workload_identity() {
  log_info "Checking Workload Identity on destination cluster '${DEST_CLUSTER}'..."
  local pool
  pool="$(gcloud container clusters describe "${DEST_CLUSTER}" \
    --location "${DEST_LOCATION}" --project "${PROJECT}" \
    --format='value(workloadIdentityConfig.workloadPool)')"
  if [[ -z "${pool}" ]]; then
    die "Workload Identity is not enabled on destination cluster \"${DEST_CLUSTER}\"; enable it with:
  gcloud container clusters update ${DEST_CLUSTER} --location ${DEST_LOCATION} --project ${PROJECT} --workload-pool=${PROJECT}.svc.id.goog
(existing node pools also need --workload-metadata=GKE_METADATA)"
  fi
  log_success "Workload Identity enabled (pool: ${pool})."

  if gcloud iam service-accounts describe "${GSA_EMAIL}" --project "${PROJECT}" >/dev/null 2>&1; then
    log_info "Google Service Account ${GSA_EMAIL} already exists."
  else
    log_info "Creating Google Service Account ${GSA_EMAIL}..."
    gcloud iam service-accounts create "${GSA_NAME}" --project "${PROJECT}" \
      --display-name "KRMSyncer controller"
  fi

  log_info "Granting roles/container.viewer on project ${PROJECT} to ${GSA_EMAIL} (read access to the source cluster)..."
  quiet gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member "serviceAccount:${GSA_EMAIL}" \
    --role roles/container.viewer \
    --condition=None --quiet

  log_info "Allowing ${WI_MEMBER} to impersonate ${GSA_EMAIL}..."
  quiet gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" --project "${PROJECT}" \
    --member "${WI_MEMBER}" \
    --role roles/iam.workloadIdentityUser \
    --condition=None --quiet
  log_success "Workload Identity configured."
}

build_and_push_image() {
  # If the user passed --image and it already exists in the registry, deploy it as is.
  if [[ "${IMAGE_FROM_FLAG}" == "true" ]]; then
    log_info "Checking whether ${IMAGE} exists in the registry..."
    if docker manifest inspect "${IMAGE}" >/dev/null 2>&1; then
      log_success "Using existing controller image ${IMAGE}; skipping build."
      return
    fi
    [[ "${IMAGE}" != *@* ]] ||
      die "image ${IMAGE} not found; a digest reference can't be built, use a tag (e.g. repo:tag) instead"
    log_info "Image ${IMAGE} not found; building it."
  fi

  local go_version
  go_version="$(awk '$1 == "go" && NF == 2 { print $2 }' "${MODULE_DIR}/go.mod")"
  [[ -n "${go_version}" ]] || die "no go directive found in ${MODULE_DIR}/go.mod"

  log_info "Building controller image ${IMAGE} (Go ${go_version})..."
  docker build --platform linux/amd64 \
    --build-arg "GO_VERSION=${go_version}" -t "${IMAGE}" "${MODULE_DIR}"
  log_info "Pushing controller image ${IMAGE}..."
  docker push "${IMAGE}" ||
    die "failed to push ${IMAGE} (you may need to run: gcloud auth configure-docker ${IMAGE%%/*})"
  log_success "Controller image pushed."
}

configure_source_secret() {
  log_info "Verifying source cluster connectivity..."
  kubectl --context="${SOURCE_CONTEXT}" get --raw /version >/dev/null ||
    die "failed to connect to source cluster using context \"${SOURCE_CONTEXT}\"; run: gcloud container clusters get-credentials ${SOURCE_CLUSTER} --location ${SOURCE_LOCATION} --project ${PROJECT}"
  log_success "Verified source cluster connection successfully!"

  log_info "Verifying destination cluster connectivity..."
  kubectl --context="${DEST_CONTEXT}" get --raw /version >/dev/null ||
    die "failed to connect to destination cluster using context \"${DEST_CONTEXT}\"; run: gcloud container clusters get-credentials ${DEST_CLUSTER} --location ${DEST_LOCATION} --project ${PROJECT}"
  log_success "Verified destination cluster connection successfully!"

  log_info "Looking up endpoint for source cluster '${SOURCE_CLUSTER}'..."
  local endpoint ca_data extra
  read -r endpoint ca_data extra < <(gcloud container clusters describe "${SOURCE_CLUSTER}" \
    --location "${SOURCE_LOCATION}" --project "${PROJECT}" \
    --format='value(endpoint,masterAuth.clusterCaCertificate)') || true
  if [[ -z "${endpoint}" || -z "${ca_data}" || -n "${extra}" ]]; then
    die "unexpected endpoint/CA output for source cluster \"${SOURCE_CLUSTER}\""
  fi

  local kubeconfig
  kubeconfig="$(render_template "${TEMPLATES_DIR}/source-kubeconfig.yaml" \
    "SOURCE_ENDPOINT=${endpoint}" \
    "SOURCE_CA_DATA=${ca_data}")"

  log_info "Creating destination namespace '${NAMESPACE}' on dest cluster if not exists..."
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl_apply

  log_info "Creating Kubeconfig Secret '${SOURCE_SECRET_NAME}' in namespace '${NAMESPACE}' on dest cluster..."
  kubectl create secret generic "${SOURCE_SECRET_NAME}" -n "${NAMESPACE}" \
    --from-literal=kubeconfig="${kubeconfig}" \
    --dry-run=client -o yaml | kubectl_apply
  log_success "Secret '${SOURCE_SECRET_NAME}' successfully created in namespace '${NAMESPACE}'!"
}

deploy_controller() {
  local config_dir="${MODULE_DIR}/config/default"
  log_info "Rendering manifests from ${config_dir}..."
  local manifests
  manifests="$(kubectl kustomize "${config_dir}")"
  if [[ "${manifests}" != *"image: ${IMAGE_PLACEHOLDER}"* ]]; then
    die "could not find image \"${IMAGE_PLACEHOLDER}\" in rendered manifests; check config/manager/manager.yaml"
  fi

  log_info "Applying CRD, RBAC and controller Deployment..."
  printf '%s\n' "${manifests//"image: ${IMAGE_PLACEHOLDER}"/"image: ${IMAGE}"}" | kubectl_apply

  log_info "Annotating ServiceAccount for Workload Identity..."
  kubectl --context="${DEST_CONTEXT}" -n "${CONTROLLER_NAMESPACE}" \
    annotate serviceaccount "${CONTROLLER_KSA}" \
    "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite

  log_info "Waiting for KRMSyncer CRD to be established..."
  kubectl --context="${DEST_CONTEXT}" wait --for condition=established \
    --timeout=60s "crd/${KRMSYNCER_CRD}"

  # Restart so pods pick up the ServiceAccount annotation and any newly pushed :latest image.
  log_info "Restarting controller..."
  kubectl --context="${DEST_CONTEXT}" -n "${CONTROLLER_NAMESPACE}" \
    rollout restart deployment "${CONTROLLER_DEPLOYMENT}"
  kubectl --context="${DEST_CONTEXT}" -n "${CONTROLLER_NAMESPACE}" \
    rollout status deployment "${CONTROLLER_DEPLOYMENT}" --timeout=180s
  log_success "KRMSyncer controller is running!"
}

deploy_sync_config() {
  log_info "Deploying KRMSyncer sync configuration..."
  local manifest
  manifest="$(render_template "${TEMPLATES_DIR}/krmsyncer.yaml" \
    "SYNC_CONFIG_NAME=${SYNC_CONFIG_NAME}" \
    "NAMESPACE=${NAMESPACE}" \
    "SOURCE_SECRET_NAME=${SOURCE_SECRET_NAME}")"
  printf '%s\n' "${manifest}" | kubectl_apply
  log_success "Sample sync configuration applied successfully!"
}

# --- Main --------------------------------------------------------------------

main() {
  parse_flags "$@"
  check_deps
  complete
  print_summary

  # Workload Identity runs before the image build: new IAM bindings can take a
  # few minutes to propagate, and the build gives them time so the controller
  # doesn't hit 403 "iam.serviceAccounts.getAccessToken denied" errors on startup.
  log_header "Step 1: Configure Workload Identity"
  configure_workload_identity
  log_header "Step 2: Controller Image"
  build_and_push_image
  log_header "Step 3: Configure Remote Access Secret"
  configure_source_secret
  log_header "Step 4: Deploy KRMSyncer Controller"
  deploy_controller
  log_header "Step 5: Deploy KRMSyncer Configuration"
  deploy_sync_config

  echo
  log_info "View controller logs with:"
  log_info "  kubectl --context=${DEST_CONTEXT} -n ${CONTROLLER_NAMESPACE} logs deploy/${CONTROLLER_DEPLOYMENT} -f"
}

main "$@"
