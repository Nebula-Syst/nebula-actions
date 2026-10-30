#!/usr/bin/env bash
# Smoke test opcional para los PRs de Docker de Dependabot.
#
# Cópialo a docker/smoke.sh del repo y ajusta las variables. nebula-actions lo
# ejecuta (desde la raíz del repo) después de compilar todos los Dockerfile:
# construye la imagen de producción, la arranca y comprueba que responde.
#
#   · Si la imagen tiene HEALTHCHECK, espera a que esté "healthy".
#   · Si no, espera a que responda HTTP en $PORT$URL_PATH.
#   · Si el contenedor se para, falla y enseña sus logs.
set -euo pipefail

DOCKERFILE="${DOCKERFILE:-docker/prod/Dockerfile.prod}"
PORT="${PORT:-3000}"          # puerto que expone la app dentro del contenedor
URL_PATH="${URL_PATH:-/}"
TIMEOUT="${TIMEOUT:-60}"      # segundos
# Variables mínimas para que la app arranque (sin secretos reales), p. ej.:
# RUN_ARGS=(-e NODE_ENV=production -e DATABASE_URL=postgres://...)
RUN_ARGS=()

name="smoke-$$"
docker build -f "$DOCKERFILE" -t "$name" .
docker run -d --name "$name" -p "127.0.0.1:$PORT:$PORT" "${RUN_ARGS[@]}" "$name" >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 $((TIMEOUT / 2))); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
    echo "::error::El contenedor se ha parado"
    docker logs "$name" || true
    exit 1
  fi
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
  case "$health" in
    healthy) echo "OK: healthy"; exit 0 ;;
    none) curl -fsS -o /dev/null "http://127.0.0.1:$PORT$URL_PATH" && { echo "OK: responde en $URL_PATH"; exit 0; } ;;
  esac
  sleep 2
done

echo "::error::No arrancó en ${TIMEOUT}s (health=$health)"
docker logs "$name" || true
exit 1
