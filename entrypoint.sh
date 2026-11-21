#!/bin/sh
# Start LiteLLM only with every required secret present.
#
# Each input is read from <NAME>_FILE when set (Docker secret files, mounted
# Kubernetes Secret keys) or else from <NAME>. The upstream image would start
# without a database (reporting ready) and without a master key (unauthenticated),
# so a missing input, or a credential encryption key equal to the master key,
# stops the container before LiteLLM starts. Values are never printed.
set -eu

load() {
  name="$1"
  file_var="${name}_FILE"
  eval "file=\${$file_var:-}"
  if [ -n "$file" ]; then
    if [ ! -r "$file" ]; then
      echo "flowai-litellm-gateway: $file_var names an unreadable file" >&2
      exit 64
    fi
    value="$(cat "$file")"
  else
    eval "value=\${$name:-}"
  fi
  if [ -z "$value" ]; then
    echo "flowai-litellm-gateway: required input $name is missing" >&2
    exit 64
  fi
  export "$name=$value"
  unset "$file_var"
}

load LITELLM_MASTER_KEY
load LITELLM_SALT_KEY
load DATABASE_URL

case "$LITELLM_MASTER_KEY" in
  sk-*) ;;
  *) echo "flowai-litellm-gateway: LITELLM_MASTER_KEY must start with sk-" >&2; exit 64 ;;
esac
if [ "$LITELLM_MASTER_KEY" = "$LITELLM_SALT_KEY" ]; then
  echo "flowai-litellm-gateway: the credential encryption key must differ from the master key" >&2
  exit 64
fi

export STORE_MODEL_IN_DB=True
exec litellm --config /etc/flowai-litellm/litellm.yaml --port "${LITELLM_PORT:-4000}" "$@"
