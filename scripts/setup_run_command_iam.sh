#!/usr/bin/env bash
set -euo pipefail

OCI_BIN="${OCI_BIN:-oci}"
INSTANCE_ID="${OCI_INSTANCE_ID:-}"
TENANCY_ID="${OCI_TENANCY_ID:-$(awk -F= '/^tenancy=/{print $2}' "${HOME}/.oci/config")}"
DG_NAME="${OCI_RUN_COMMAND_DG_NAME:-openclaw-run-command-dg}"
POLICY_NAME="${OCI_RUN_COMMAND_POLICY_NAME:-openclaw-run-command-policy}"

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "OCI_INSTANCE_ID is required" >&2
  exit 1
fi

if [[ ! -x "$(command -v "${OCI_BIN}")" ]]; then
  echo "OCI CLI not found: ${OCI_BIN}" >&2
  exit 1
fi

MATCHING_RULE="ALL {instance.id = '${INSTANCE_ID}'}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

dg_json="${tmpdir}/dynamic-groups.json"
policy_json="${tmpdir}/policies.json"
statements_json="${tmpdir}/statements.json"

"${OCI_BIN}" iam dynamic-group list --all --compartment-id "${TENANCY_ID}" > "${dg_json}"
"${OCI_BIN}" iam policy list --all --compartment-id "${TENANCY_ID}" > "${policy_json}"

EXISTING_DG_ID="$(python3 - "${dg_json}" "${DG_NAME}" <<'PY'
import json
import sys

path, target = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for item in data.get("data", []):
    if item.get("name") == target:
        print(item["id"])
        break
PY
)"

if [[ -z "${EXISTING_DG_ID}" ]]; then
  "${OCI_BIN}" iam dynamic-group create \
    --compartment-id "${TENANCY_ID}" \
    --name "${DG_NAME}" \
    --description "Allows the OpenClaw instance to use OCI Run Command" \
    --matching-rule "${MATCHING_RULE}" \
    --wait-for-state ACTIVE >/dev/null
else
  "${OCI_BIN}" iam dynamic-group update \
    --dynamic-group-id "${EXISTING_DG_ID}" \
    --description "Allows the OpenClaw instance to use OCI Run Command" \
    --matching-rule "${MATCHING_RULE}" \
    --force \
    --wait-for-state ACTIVE >/dev/null
fi

python3 - "${DG_NAME}" > "${statements_json}" <<'PY'
import json
import sys

name = sys.argv[1]
statements = [
    f"Allow dynamic-group {name} to manage instance-family in tenancy",
    f"Allow dynamic-group {name} to use instance-agent-command-family in tenancy",
    f"Allow dynamic-group {name} to use instance-agent-command-execution-family in tenancy where request.instance.id = target.instance.id",
]
print(json.dumps(statements))
PY

EXISTING_POLICY_ID="$(python3 - "${policy_json}" "${POLICY_NAME}" <<'PY'
import json
import sys

path, target = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for item in data.get("data", []):
    if item.get("name") == target:
        print(item["id"])
        break
PY
)"

if [[ -z "${EXISTING_POLICY_ID}" ]]; then
  "${OCI_BIN}" iam policy create \
    --compartment-id "${TENANCY_ID}" \
    --name "${POLICY_NAME}" \
    --description "Policies for OCI Run Command on the OpenClaw instance" \
    --statements "file://${statements_json}" \
    --wait-for-state ACTIVE >/dev/null
else
  "${OCI_BIN}" iam policy update \
    --policy-id "${EXISTING_POLICY_ID}" \
    --description "Policies for OCI Run Command on the OpenClaw instance" \
    --statements "file://${statements_json}" \
    --force \
    --wait-for-state ACTIVE >/dev/null
fi

echo "Run Command IAM is ready for instance ${INSTANCE_ID}"

