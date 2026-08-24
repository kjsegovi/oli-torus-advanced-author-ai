#!/bin/sh

set -eu

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ACCESS_KEY="${AWS_S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-${MINIO_ROOT_USER:-}}}"
MINIO_SECRET_KEY="${AWS_S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-${MINIO_ROOT_PASSWORD:-}}}"
SIMULATION_BUCKET="${GENERATED_SIMULATION_BUCKET_NAME:-torus-simulations}"
READINESS_HASH="d9183cccabe3a6daf616864543f35a0441d6892b5252d3e8c3d61ee8256cf944"
READINESS_KEY="generated-simulations/storage-v2/readiness/sha256/${READINESS_HASH}/index.html"

if [ -z "$MINIO_ACCESS_KEY" ]; then
  MINIO_ACCESS_KEY="$(cat "${MINIO_ROOT_USER_FILE:-/credentials/access_key}")"
fi

if [ -z "$MINIO_SECRET_KEY" ]; then
  MINIO_SECRET_KEY="$(cat "${MINIO_ROOT_PASSWORD_FILE:-/credentials/secret_key}")"
fi

case "$SIMULATION_BUCKET" in
  ''|*[!a-z0-9.-]*|.*|*.)
    echo "GENERATED_SIMULATION_BUCKET_NAME is not a valid MinIO bucket name" >&2
    exit 1
    ;;
esac

until mc alias set localminio "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"; do
  echo "Waiting for MinIO..."
  sleep 2
done

mc mb --ignore-existing "localminio/$SIMULATION_BUCKET"

printf '%s\n' \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"*\"]},\"Action\":[\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::$SIMULATION_BUCKET/generated-simulations/*\"]}]}" \
  >/tmp/generated_simulation_read_policy.json

mc anonymous set-json /tmp/generated_simulation_read_policy.json "localminio/$SIMULATION_BUCKET"
mc cp --attr "Content-Type=text/html;Cache-Control=public, max-age=31536000, immutable" \
  /config/generated_simulation_readiness.html \
  "localminio/$SIMULATION_BUCKET/$READINESS_KEY"
