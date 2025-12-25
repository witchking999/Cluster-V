#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:-}"
HEAD_IP="${HEAD_IP:-192.168.128.111}"
NFS_SERVER="${NFS_SERVER:-$HEAD_IP}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Try git to locate repo root, fallback to script relative path.
REPO_ROOT="${REPO_ROOT:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || cd "${SCRIPT_DIR}/../.." && pwd)}"
EXTRA_API_KEYS_JSON="${EXTRA_API_KEYS_JSON:-[]}"
# Baseline keys we always prompt for (placeholders exist in envrc).
DEFAULT_API_KEYS=(LLAMA_CLOUD_API_KEY OPENAI_API_KEY ABLY_API_KEY NVIDIA_API_KEY MISTRAL_API_KEY NV_NIM_KEY HF_TOKEN VIBE_API_KEY)

if [[ -z "${ROLE}" ]]; then
  echo "ROLE must be set to head or worker." >&2
  exit 1
fi

echo "🏗️  Bootstrap starting for role: ${ROLE}"
echo "📂 Repo root: ${REPO_ROOT}"

# Request sudo once up front so later steps don't surprise the user.
if ! sudo -n true 2>/dev/null; then
  echo "🔑 Sudo access required to install dependencies; you will be prompted."
  sudo -v
fi

echo "📦 Installing prerequisites (ansible, direnv, python3, jq)..."
sudo apt-get update -y
sudo apt-get install -y ansible direnv python3 python3-pip jq iproute2

# Ensure direnv is wired into the user's shell.
if ! grep -q 'direnv hook bash' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'eval "$(direnv hook bash)"' >> "${HOME}/.bashrc"
fi

# Create a local env file for user-provided secrets and allow direnv.
# Ensure direnv-controlled file exists (.envrc). If only envrc template exists, copy it.
ENVRC_PATH="${REPO_ROOT}/.envrc"
if [[ ! -f "${ENVRC_PATH}" ]]; then
  if [[ -f "${REPO_ROOT}/envrc" ]]; then
    cp "${REPO_ROOT}/envrc" "${ENVRC_PATH}"
  else
    touch "${ENVRC_PATH}"
  }
fi

# Collect keys to prompt: defaults + extra list from terraform var.
if command -v jq >/dev/null 2>&1; then
  mapfile -t EXTRA_KEYS < <(echo "${EXTRA_API_KEYS_JSON}" | jq -r '.[]?' 2>/dev/null || true)
else
  # Fallback: split on commas if provided as plain string.
  IFS=',' read -r -a EXTRA_KEYS <<<"${EXTRA_API_KEYS_JSON:-}"
fi

PROMPT_KEYS=("${DEFAULT_API_KEYS[@]}" "${EXTRA_KEYS[@]}")
if [[ ${#PROMPT_KEYS[@]} -gt 0 ]]; then
  echo "🔐 Enter values for API keys (stored in ${ENVRC_PATH}, leave blank to skip):"
  for key in "${PROMPT_KEYS[@]}"; do
    # Avoid duplicate prompts for repeated keys.
    if grep -q "^export ${key}=" "${ENVRC_PATH}"; then
      continue
    fi
    read -r -s -p "  ${key}: " value || true
    echo
    if [[ -n "${value}" ]]; then
      echo "export ${key}=${value}" >> "${ENVRC_PATH}"
    fi
  done
fi

# Allow direnv if present, but don't fail bootstrap if not.
if command -v direnv >/dev/null 2>&1; then
  direnv allow "${REPO_ROOT}" || true
fi

PRIMARY_IP="$(hostname -I | awk '{print $1}')"
INVENTORY_DIR="$(mktemp -d)"
INVENTORY_FILE="${INVENTORY_DIR}/inventory"

case "${ROLE}" in
  head)
    cat > "${INVENTORY_FILE}" <<EOF
[lan-client-server]
localhost ansible_connection=local head_node_ip=${HEAD_IP} nfs_server=${NFS_SERVER} nomad_server_ips=${HEAD_IP}
EOF
    LIMIT_GROUP="lan-client-server"
    ;;
  worker)
    cat > "${INVENTORY_FILE}" <<EOF
[lan-client]
localhost ansible_connection=local ansible_host=${PRIMARY_IP} head_node_ip=${HEAD_IP} nfs_server=${NFS_SERVER} nomad_server_ips=${HEAD_IP}
EOF
    LIMIT_GROUP="lan-client"
    ;;
  *)
    echo "Unsupported ROLE: ${ROLE}. Use head or worker." >&2
    exit 1
    ;;
esac

echo "📡 Using inventory:"
cat "${INVENTORY_FILE}"

pushd "${REPO_ROOT}" >/dev/null

echo "🤖 Running Ansible playbook for ${ROLE}..."
ansible-playbook \
  -i "${INVENTORY_FILE}" \
  --connection=local \
  --limit "${LIMIT_GROUP}" \
  --extra-vars "head_node_ip=${HEAD_IP} nfs_server=${NFS_SERVER} nomad_server_ips=${HEAD_IP}" \
  ansible/playbook.yml

popd >/dev/null

echo "✅ Bootstrap complete."
