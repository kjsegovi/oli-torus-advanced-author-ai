#!/bin/sh

set -eu

HA_PROXY_MODE="${HA_PROXY_MODE:-minio}"
TORUS_BACKEND_HOST="${TORUS_BACKEND_HOST:-host.docker.internal}"
TORUS_BACKEND_PORT="${TORUS_BACKEND_PORT:-${HTTP_PORT:-8080}}"
RENDERED_CONFIG="${RENDERED_CONFIG:-/tmp/haproxy.cfg}"
TLS_CERT_BUNDLE="${TLS_CERT_BUNDLE:-/certs/combined.pem}"

prepare_tls_bundle() {
  if [ -f "$TLS_CERT_BUNDLE" ]; then
    return
  fi

  TLS_CERT_FILE="${TLS_CERT_FILE:-/certs/tls.crt}"
  TLS_KEY_FILE="${TLS_KEY_FILE:-/certs/tls.key}"

  if [ ! -f "$TLS_CERT_FILE" ] || [ ! -f "$TLS_KEY_FILE" ]; then
    echo "Missing HAProxy TLS certificate or key" >&2
    exit 1
  fi

  TLS_CERT_BUNDLE="/tmp/combined.pem"
  cat "$TLS_KEY_FILE" "$TLS_CERT_FILE" >"$TLS_CERT_BUNDLE"
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_minio() {
  MINIO_API_HOST="${MINIO_API_HOST:-host.docker.internal}"
  MINIO_API_PORT="${MINIO_API_PORT:-${AWS_S3_PORT:-9000}}"
  LEGACY_MEDIA_BUCKET="${LEGACY_MEDIA_BUCKET:-${S3_MEDIA_BUCKET_NAME:-torus-media-dev}}"
  SIMULATION_BUCKET="${GENERATED_SIMULATION_BUCKET_NAME:-torus-simulations}"
  SIMULATION_ORIGIN="${GENERATED_SIMULATION_ORIGIN:-}"
  SIMULATION_HOST="${SIMULATION_HOST:-}"
  SIMULATION_BASE_PATH="${SIMULATION_BASE_PATH:-}"

  if [ -n "$SIMULATION_ORIGIN" ]; then
    origin_authority="${SIMULATION_ORIGIN#*://}"
    origin_host_port="${origin_authority%%/*}"

    # The explicit origin is the upgrade-compatible canonical setting.
    SIMULATION_HOST="${origin_host_port%%:*}"

    if [ "$origin_authority" != "$origin_host_port" ]; then
      SIMULATION_BASE_PATH="/${origin_authority#*/}"
      SIMULATION_BASE_PATH="${SIMULATION_BASE_PATH%/}"
    else
      SIMULATION_BASE_PATH=""
    fi
  fi

  SIMULATION_HOST="${SIMULATION_HOST:-generated-simulations.${HOST:-localhost}}"
  FRAME_ANCESTORS="${GENERATED_SIMULATION_FRAME_ANCESTORS:-${SCHEME:-https}://${HOST:-localhost}}"
  FRAME_ANCESTORS="$(printf '%s' "$FRAME_ANCESTORS" | tr ',' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"

  case "$SIMULATION_HOST$LEGACY_MEDIA_BUCKET$SIMULATION_BUCKET" in
    *[!A-Za-z0-9._-]*) echo "Invalid simulation host or bucket name" >&2; exit 1 ;;
  esac

  case "$SIMULATION_BASE_PATH" in
    *[!A-Za-z0-9/_-]*) echo "Invalid simulation origin path" >&2; exit 1 ;;
  esac

  case "$FRAME_ANCESTORS" in
    *';'*|*'"'*) echo "Invalid generated simulation frame ancestors" >&2; exit 1 ;;
  esac

  prepare_tls_bundle

  sed \
    -e "s|__TORUS_BACKEND_HOST__|$(escape_sed "$TORUS_BACKEND_HOST")|g" \
    -e "s|__TORUS_BACKEND_PORT__|$(escape_sed "$TORUS_BACKEND_PORT")|g" \
    -e "s|__MINIO_API_HOST__|$(escape_sed "$MINIO_API_HOST")|g" \
    -e "s|__MINIO_API_PORT__|$(escape_sed "$MINIO_API_PORT")|g" \
    -e "s|__LEGACY_MEDIA_BUCKET__|$(escape_sed "$LEGACY_MEDIA_BUCKET")|g" \
    -e "s|__SIMULATION_BUCKET__|$(escape_sed "$SIMULATION_BUCKET")|g" \
    -e "s|__SIMULATION_HOST__|$(escape_sed "$SIMULATION_HOST")|g" \
    -e "s|__SIMULATION_BASE_PATH__|$(escape_sed "$SIMULATION_BASE_PATH")|g" \
    -e "s|__FRAME_ANCESTORS__|$(escape_sed "$FRAME_ANCESTORS")|g" \
    -e "s|__TLS_CERT_BUNDLE__|$(escape_sed "$TLS_CERT_BUNDLE")|g" \
    /usr/local/etc/haproxy/haproxy.minio.cfg.template >"$RENDERED_CONFIG"
}

render_origin() {
  : "${MEDIA_ORIGIN_HOST:?MEDIA_ORIGIN_HOST is required when HA_PROXY_MODE=s3}"

  MEDIA_ORIGIN_PORT="${MEDIA_ORIGIN_PORT:-80}"

  prepare_tls_bundle

  sed \
    -e "s/__TORUS_BACKEND_HOST__/${TORUS_BACKEND_HOST}/g" \
    -e "s/__TORUS_BACKEND_PORT__/${TORUS_BACKEND_PORT}/g" \
    -e "s/__MEDIA_ORIGIN_HOST__/${MEDIA_ORIGIN_HOST}/g" \
    -e "s/__MEDIA_ORIGIN_PORT__/${MEDIA_ORIGIN_PORT}/g" \
    -e "s|__TLS_CERT_BUNDLE__|$(escape_sed "$TLS_CERT_BUNDLE")|g" \
    /usr/local/etc/haproxy/haproxy.origin.cfg.template >"$RENDERED_CONFIG"
}

case "$HA_PROXY_MODE" in
  minio)
    render_minio
    ;;

  s3 | origin)
    render_origin
    ;;

  *)
    echo "Unsupported HA_PROXY_MODE: $HA_PROXY_MODE" >&2
    echo "Expected one of: minio, s3, origin" >&2
    exit 1
    ;;
esac

if [ "${HA_PROXY_CHECK_CONFIG:-false}" = "true" ]; then
  exec haproxy -c -f "$RENDERED_CONFIG"
fi

exec haproxy -W -db -f "$RENDERED_CONFIG"
