#!/bin/sh

set -eu

CREDENTIALS_DIR="${MINIO_CREDENTIALS_DIR:-/credentials}"
ACCESS_KEY_FILE="${MINIO_ROOT_USER_FILE:-$CREDENTIALS_DIR/access_key}"
SECRET_KEY_FILE="${MINIO_ROOT_PASSWORD_FILE:-$CREDENTIALS_DIR/secret_key}"

mkdir -p "$CREDENTIALS_DIR"

generate_secret() {
  target="$1"
  bytes="$2"

  if [ -s "$target" ]; then
    return
  fi

  temporary="${target}.tmp.$$"
  umask 077
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n' >"$temporary"
  chmod 0444 "$temporary"
  mv "$temporary" "$target"
}

# MinIO requires at least three characters for the access key and eight for the
# secret key. Generate substantially longer values and retain them in a named
# Docker volume so restarts and upgrades keep the same storage credentials.
generate_secret "$ACCESS_KEY_FILE" 16
generate_secret "$SECRET_KEY_FILE" 32
