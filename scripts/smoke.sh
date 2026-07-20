#!/usr/bin/env bash
set -euo pipefail

mode="${1:-all}"
container="${HERMES_CONTAINER_NAME:-hermes-docker}"

docker exec "${container}" hermes-smoke-check "${mode}"
