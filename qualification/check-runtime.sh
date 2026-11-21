#!/usr/bin/env bash
# Exercise the packaged FlowAI wrapper against a disposable PostgreSQL dependency.
set -euo pipefail
image=$1
tmp=$(mktemp -d)
prefix=flowai-litellm-$(basename "$tmp" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
network=$prefix-net
db=$prefix-db
gateway=$prefix-gateway
missing=$prefix-missing
cleanup() {
  local result=$?
  trap - EXIT
  podman rm -f -v --ignore "$gateway" "$db" "$missing" >/dev/null || result=1
  if podman network exists "$network"; then
    podman network rm "$network" >/dev/null || result=1
  fi
  for resource in "$gateway" "$db" "$missing"; do
    if podman container exists "$resource"; then result=1; fi
  done
  if podman network exists "$network"; then result=1; fi
  rm -rf -- "$tmp"
  if [[ "$result" == 0 ]]; then printf 'owned gateway, fixture and network absent\n'; fi
  exit "$result"
}
trap cleanup EXIT

status=0
podman run --name "$missing" --network none "$image" > "$tmp/missing.log" 2>&1 || status=$?
[[ "$status" == 64 ]]
grep -Fxq 'flowai-litellm-gateway: required input LITELLM_MASTER_KEY is missing' "$tmp/missing.log"
printf 'missing input rejected with exit 64\n'
umask 077
python3 - "$tmp" "$db" <<'PYTHON'
import pathlib
import secrets
import sys

directory = pathlib.Path(sys.argv[1])
password, master, salt = (secrets.token_hex(24) for _ in range(3))
(directory / "postgres.env").write_text(
    f"POSTGRES_USER=flowai\nPOSTGRES_PASSWORD={password}\nPOSTGRES_DB=flowai\n"
)
(directory / "gateway.env").write_text(
    f"DATABASE_URL=postgresql://flowai:{password}@{sys.argv[2]}:5432/flowai\n"
    f"LITELLM_MASTER_KEY=sk-{master}\nLITELLM_SALT_KEY={salt}\n"
    "LITELLM_LOCAL_MODEL_COST_MAP=true\n"
)
PYTHON
podman network create --internal "$network" >/dev/null
podman run -d --name "$db" --network "$network" --env-file "$tmp/postgres.env" \
  docker.io/library/postgres@sha256:a85daf0dbd5e79586e850e3fe4b21b796799828ad015ce2166aeb98cc24da61c \
  >/dev/null
timeout 60 bash -c 'until podman exec "$1" pg_isready -h 127.0.0.1 -U flowai -d flowai >/dev/null 2>&1; do sleep 1; done' _ "$db"

start() {
  podman run -d --name "$gateway" --network "$network" --env-file "$tmp/gateway.env" "$image" >/dev/null
}
probe() {
  for ((attempt = 0; attempt < 100; attempt++)); do
    if podman exec -i "$gateway" python -B - "$1" > "$tmp/probe.log" 2>&1 <<'PYTHON'
import json
import os
import sys
import urllib.request

assert (os.getuid(), os.getgid()) == (65532, 65532)
headers = {"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
           "Content-Type": "application/json"}


def request(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("http://127.0.0.1:4000" + path, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.load(response)


assert request("/health/readiness")["db"] == "connected"
alias = "flowai-package-qualification"
if sys.argv[1] == "create":
    request("/model/new", {
        "model_name": alias,
        "litellm_params": {"model": "openai/flowai-package-qualification"},
        "model_info": {"flowai_model_id": 42},
    })
else:
    models = request("/model/info")["data"]
    assert any(model["model_name"] == alias and model["model_info"]["flowai_model_id"] == 42
               for model in models)
PYTHON
    then return 0; fi
    if [[ "$(podman inspect --format '{{.State.Running}}' "$gateway")" != true ]]; then break; fi
    sleep 2
  done
  printf 'Packaged gateway did not pass the %s probe.\n' "$1" >&2
  return 1
}
start
probe create
printf 'nonroot startup, database-backed readiness and FlowAI model write passed\n'
podman rm -f -v "$gateway" >/dev/null
start
probe read
printf 'FlowAI model metadata survived gateway recreation\n'
