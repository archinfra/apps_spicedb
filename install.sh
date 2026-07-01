#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="spicedb"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="spicedb"
DEFAULT_REPLICAS="2"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_SERVICE_TYPE="ClusterIP"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
NAMESPACE="${DEFAULT_NAMESPACE}"
REPLICAS="${DEFAULT_REPLICAS}"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVICE_TYPE="${DEFAULT_SERVICE_TYPE}"
NODEPORT_GRPC=""
NODEPORT_HTTP=""
SKIP_IMAGE_PREPARE=0
YES=0
DELETE_NAMESPACE=0
RUN_MIGRATION=1
DATASTORE_ENGINE="postgres"
DATASTORE_CONN_URI=""
GRPC_PRESHARED_KEY=""
IMAGE_PULL_POLICY="IfNotPresent"
LOG_LEVEL="info"
HTTP_ENABLED="true"
WORKDIR=""
IMAGE_INDEX=""

usage() {
  cat <<USAGE
Usage:
  ./spicedb-<version>-<arch>.run install [options]
  ./spicedb-<version>-<arch>.run status [options]
  ./spicedb-<version>-<arch>.run uninstall [options]
  ./spicedb-<version>-<arch>.run help

Actions:
  install      Extract payload, load/tag/push image, run datastore migration, and install SpiceDB.
  status       Show SpiceDB resources.
  uninstall    Delete SpiceDB resources. Namespace is kept unless --delete-namespace is set.
  help         Show this help.

Options:
  --registry <repo-prefix>             Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>               Registry username for docker login.
  --registry-pass <pass>               Registry password for docker login.
  --skip-image-prepare                 Skip docker load/tag/push; still render image to --registry prefix.
  -n, --namespace <namespace>          Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --replicas <n>                       Deployment replicas. Default: ${DEFAULT_REPLICAS}
  --datastore-engine <engine>          postgres, cockroachdb, mysql, spanner, or memory. Default: postgres
  --datastore-conn-uri <uri>           Remote datastore URI. Required unless --datastore-engine memory.
  --grpc-preshared-key <key>           Required client auth key for gRPC/HTTP APIs.
  --http-enabled <true|false>          Enable HTTP gateway. Default: true
  --service-type <type>                ClusterIP, NodePort, or LoadBalancer. Default: ClusterIP
  --nodeport-grpc <port>               Optional NodePort for gRPC port 50051.
  --nodeport-http <port>               Optional NodePort for HTTP port 8443.
  --image-pull-policy <policy>         IfNotPresent, Always, or Never. Default: IfNotPresent
  --log-level <level>                  trace, debug, info, warn, error. Default: info
  --wait-timeout <duration>            Wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --skip-migration                     Do not render or run spicedb datastore migrate head.
  --delete-namespace                   During uninstall, also delete namespace.
  -y, --yes                            Do not ask for confirmation.
  -h, --help                           Show this help.

Example:
  ./spicedb-1.54.0-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n spicedb \
    --datastore-engine postgres \
    --datastore-conn-uri 'postgres://postgres:password@postgres.default.svc:5432/spicedb?sslmode=disable' \
    --grpc-preshared-key 'change-me-to-a-long-random-key' \
    -y
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass|--registry-password) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --replicas) REPLICAS="${2:-}"; shift 2 ;;
    --datastore-engine) DATASTORE_ENGINE="${2:-}"; shift 2 ;;
    --datastore-conn-uri) DATASTORE_CONN_URI="${2:-}"; shift 2 ;;
    --grpc-preshared-key) GRPC_PRESHARED_KEY="${2:-}"; shift 2 ;;
    --http-enabled) HTTP_ENABLED="${2:-}"; shift 2 ;;
    --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
    --nodeport-grpc) NODEPORT_GRPC="${2:-}"; shift 2 ;;
    --nodeport-http) NODEPORT_HTTP="${2:-}"; shift 2 ;;
    --image-pull-policy) IMAGE_PULL_POLICY="${2:-}"; shift 2 ;;
    --log-level) LOG_LEVEL="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --skip-migration) RUN_MIGRATION=0; shift ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

[[ -n "${REGISTRY}" ]] || die "--registry cannot be empty"
[[ -n "${NAMESPACE}" ]] || die "--namespace cannot be empty"
[[ "${REPLICAS}" =~ ^[0-9]+$ ]] || die "--replicas must be a positive integer"
[[ "${REPLICAS}" -ge 1 ]] || die "--replicas must be >= 1"
case "${SERVICE_TYPE}" in ClusterIP|NodePort|LoadBalancer) ;; *) die "--service-type must be ClusterIP, NodePort, or LoadBalancer" ;; esac
case "${DATASTORE_ENGINE}" in postgres|cockroachdb|mysql|spanner|memory) ;; *) die "unsupported --datastore-engine: ${DATASTORE_ENGINE}" ;; esac
case "${HTTP_ENABLED}" in true|false) ;; *) die "--http-enabled must be true or false" ;; esac
if [[ -n "${NODEPORT_GRPC}" && "${SERVICE_TYPE}" != "NodePort" ]]; then die "--nodeport-grpc requires --service-type NodePort"; fi
if [[ -n "${NODEPORT_HTTP}" && "${SERVICE_TYPE}" != "NodePort" ]]; then die "--nodeport-http requires --service-type NodePort"; fi
if [[ "${ACTION}" == "install" ]]; then
  [[ -n "${GRPC_PRESHARED_KEY}" ]] || die "--grpc-preshared-key is required"
  if [[ "${DATASTORE_ENGINE}" != "memory" ]]; then
    [[ -n "${DATASTORE_CONN_URI}" ]] || die "--datastore-conn-uri is required unless --datastore-engine memory"
  fi
fi
if [[ "${DATASTORE_ENGINE}" == "memory" ]]; then
  RUN_MIGRATION=0
fi

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "payload missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/spicedb.yaml.tmpl" ]] || die "payload missing manifests/spicedb.yaml.tmpl"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} SpiceDB in namespace '${NAMESPACE}'."
  if [[ "${ACTION}" == "install" ]]; then
    echo "datastore-engine=${DATASTORE_ENGINE}, replicas=${REPLICAS}, http-enabled=${HTTP_ENABLED}, run-migration=${RUN_MIGRATION}"
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_image() {
  local default_ref="$1"
  local suffix
  if [[ "${default_ref}" == sealos.hub:5000/kube4/* ]]; then
    suffix="${default_ref#sealos.hub:5000/kube4/}"
  else
    suffix="${default_ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

image_ref_by_name() {
  local wanted="$1"
  awk -F'|' -v name="${wanted}" 'NR > 1 && $1 == name { print $4; exit }' "${IMAGE_INDEX}"
}

target_ref_by_name() {
  local wanted="$1" default_ref
  default_ref="$(image_ref_by_name "${wanted}")"
  [[ -n "${default_ref}" ]] || die "image not found in index: ${wanted}"
  retarget_image "${default_ref}"
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "1" ]] && { info "skip image prepare"; return 0; }
  need docker

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "both --registry-user and --registry-pass are required for docker login"
    local login_host="${REGISTRY%%/*}"
    info "docker login ${login_host}"
    printf '%s' "${REGISTRY_PASS}" | docker login "${login_host}" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name load_ref default_ref platform pull dockerfile; do
    [[ -n "${name}" ]] || continue
    local tar_path="${WORKDIR}/images/${tar_name}"
    local target_ref
    [[ -f "${tar_path}" ]] || die "image tar not found: ${tar_path}"
    target_ref="$(retarget_image "${default_ref}")"
    info "docker load ${tar_name}"
    docker load -i "${tar_path}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    docker push "${target_ref}"
  done
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

render_manifest() {
  local spicedb_image rendered grpc_key_b64 datastore_uri_b64 nodeport_grpc_line nodeport_http_line
  spicedb_image="$(target_ref_by_name spicedb)"
  rendered="${WORKDIR}/rendered-spicedb.yaml"
  grpc_key_b64="$(b64 "${GRPC_PRESHARED_KEY}")"
  datastore_uri_b64="$(b64 "${DATASTORE_CONN_URI}")"
  nodeport_grpc_line=""
  nodeport_http_line=""

  if [[ -n "${NODEPORT_GRPC}" ]]; then nodeport_grpc_line="    nodePort: ${NODEPORT_GRPC}"; fi
  if [[ -n "${NODEPORT_HTTP}" ]]; then nodeport_http_line="    nodePort: ${NODEPORT_HTTP}"; fi

  awk \
    -v ns="${NAMESPACE}" \
    -v image="${spicedb_image}" \
    -v image_pull_policy="${IMAGE_PULL_POLICY}" \
    -v replicas="${REPLICAS}" \
    -v datastore_engine="${DATASTORE_ENGINE}" \
    -v datastore_uri_b64="${datastore_uri_b64}" \
    -v grpc_key_b64="${grpc_key_b64}" \
    -v http_enabled="${HTTP_ENABLED}" \
    -v service_type="${SERVICE_TYPE}" \
    -v log_level="${LOG_LEVEL}" \
    -v run_migration="${RUN_MIGRATION}" \
    -v nodeport_grpc_line="${nodeport_grpc_line}" \
    -v nodeport_http_line="${nodeport_http_line}" \
    '
      /__MIGRATION_JOB_START__/ { if (run_migration != "1") skip=1; next }
      /__MIGRATION_JOB_END__/ { skip=0; next }
      skip == 1 { next }
      /__NODEPORT_GRPC_LINE__/ { if (nodeport_grpc_line != "") print nodeport_grpc_line; next }
      /__NODEPORT_HTTP_LINE__/ { if (nodeport_http_line != "") print nodeport_http_line; next }
      {
        gsub(/__NAMESPACE__/, ns)
        gsub(/__SPICEDB_IMAGE__/, image)
        gsub(/__IMAGE_PULL_POLICY__/, image_pull_policy)
        gsub(/__REPLICAS__/, replicas)
        gsub(/__DATASTORE_ENGINE__/, datastore_engine)
        gsub(/__DATASTORE_CONN_URI_B64__/, datastore_uri_b64)
        gsub(/__GRPC_PRESHARED_KEY_B64__/, grpc_key_b64)
        gsub(/__HTTP_ENABLED__/, http_enabled)
        gsub(/__SERVICE_TYPE__/, service_type)
        gsub(/__LOG_LEVEL__/, log_level)
        print
      }
    ' "${WORKDIR}/manifests/spicedb.yaml.tmpl" > "${rendered}"

  printf '%s\n' "${rendered}"
}

install_app() {
  need kubectl
  need base64
  extract_payload
  confirm
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  if [[ "${RUN_MIGRATION}" == "1" ]]; then
    info "delete previous migration job if present"
    kubectl delete job spicedb-migrate -n "${NAMESPACE}" --ignore-not-found=true || true
  fi
  info "kubectl apply -f rendered manifest"
  kubectl apply -f "${rendered}"
  if [[ "${RUN_MIGRATION}" == "1" ]]; then
    info "waiting for spicedb-migrate job"
    kubectl wait --for=condition=Complete job/spicedb-migrate -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  fi
  info "waiting for deployment/spicedb"
  kubectl rollout status deployment/spicedb -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  status_app
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,deploy,job,secret -n "${NAMESPACE}" -l app.kubernetes.io/name=spicedb || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered
  rendered="$(render_manifest)"
  info "kubectl delete -f rendered manifest"
  kubectl delete -f "${rendered}" --ignore-not-found=true || true
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "delete namespace ${NAMESPACE}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true || true
  else
    info "namespace kept: ${NAMESPACE}"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
