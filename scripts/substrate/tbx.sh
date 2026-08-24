#!/usr/bin/env bash
# =============================================================================
# substrate/tbx.sh — talos-box (`tbx`) backend: real Talos VMs.
#
# substrate_preflight, substrate_create and substrate_destroy arrive in the
# next task; this file currently provides only render_tbx_cluster_file(),
# which projects the TBX_* pins in scripts/versions.env into the cluster yaml
# `tbx up -f` reads. Source me from create-cluster.sh / destroy-cluster.sh;
# do not run me.
# =============================================================================
set -euo pipefail

# render_tbx_cluster_file() — write ${TBX_CLUSTER_FILE} from
# scripts/substrate/cloudbox.tbx.yaml.tmpl, substituting the __TOKEN__
# placeholders with the TBX_* pins (and TALOS_VERSION / CLUSTER_NAME /
# CLOUDBOX_DOMAIN) from scripts/versions.env. The cluster yaml is a
# projection of those pins, never hand-edited and never checked in — see
# check 10 in scripts/check-consistency.sh.
render_tbx_cluster_file() {
  local tmpl="${SCRIPT_DIR}/substrate/cloudbox.tbx.yaml.tmpl"
  mkdir -p "$(dirname "${TBX_CLUSTER_FILE}")"
  # Worker vCPUs scale with the host, floored at the pin (versions.env:86):
  # max(TBX_WORKER_CPUS, NCPU-2), leaving 2 cores for the host and the
  # controlplane VM. Mirrors the same host-scaling idea as docker.sh's
  # NODE_CPUS, but floored instead of raised to the host count — the tbx
  # daemon (not the kernel) enforces the cap talos-box assigns the VM.
  local ncpu workers_cpus
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
  workers_cpus="$(awk -v n="${ncpu}" -v floor="${TBX_WORKER_CPUS}" \
    'BEGIN { c = int(n) - 2; if (c < floor) c = floor; printf "%d", c }')"
  sed \
    -e "s|__TALOS_VERSION__|${TALOS_VERSION}|g" \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__CLOUDBOX_DOMAIN__|${CLOUDBOX_DOMAIN}|g" \
    -e "s|__TBX_CP_MEMORY__|${TBX_CP_MEMORY}|g" \
    -e "s|__TBX_CP_CPUS__|${TBX_CP_CPUS}|g" \
    -e "s|__TBX_WORKER_MEMORY__|${TBX_WORKER_MEMORY}|g" \
    -e "s|__TBX_WORKER_CPUS__|${workers_cpus}|g" \
    -e "s|__TBX_DISK_SIZE__|${TBX_DISK_SIZE}|g" \
    "${tmpl}" > "${TBX_CLUSTER_FILE}"
}
