#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building shared internal libraries (idp-shared-libs:latest)"
docker build -f Dockerfile.shared-libs -t idp-shared-libs:latest ..

echo "==> Building service images"
docker compose build "$@"
