#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CMD="${1:-up}"

case "$CMD" in
  up)
    docker compose up --build -d
    docker compose ps
    echo
    echo "App:     http://localhost:8080/"
    echo "Metrics: http://localhost:8080/metrics"
    ;;
  down)
    docker compose down
    ;;
  logs)
    docker compose logs -f app
    ;;
  restart)
    docker compose restart app
    ;;
  rebuild)
    docker compose up --build -d --force-recreate
    ;;
  *)
    echo "usage: $0 {up|down|logs|restart|rebuild}" >&2
    exit 1
    ;;
esac
