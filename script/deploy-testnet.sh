#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${1:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

: "${RPC_URL:?Set RPC_URL or provide a .env file.}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY or provide a .env file.}"
: "${TOKEN0:?Set TOKEN0 in the environment.}"
: "${TOKEN1:?Set TOKEN1 in the environment.}"
: "${ORACLE_TARGET:?Set ORACLE_TARGET in the environment.}"

forge script script/Deploy.s.sol:DeployScript \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
