#!/usr/bin/env bash
set -euo pipefail
output=$1
index=bc803c88c244d6193b0f40bffad1124c624109513e56332b03c20d121a9546fb
amd64=ec96da9f0c6286523a1f7646ecc8991c2455fb9b32cd24d19f9d237ff17ce6cf
arm64=66d944d56370313bcf3bed9bfdee91d7f199122e76b194be460fc8661ba85711
source=e926084212ab2eb234c58840d741b3c62c35911b
token=$(curl -q -fsS 'https://ghcr.io/token?scope=repository:berriai/litellm:pull' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
for ref in "sha256:$index" "sha256:$amd64" "sha256:$arm64" v1.104.0-rc.2; do
  curl -q -fsS --retry 2 --max-time 45 --proto '=https' -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/berriai/litellm/manifests/$ref" -o "$output/${ref#sha256:}.json"
done
(
  cd "$output"
  printf '%s  %s\n' "$index" "$index.json" "$index" v1.104.0-rc.2.json \
    "$amd64" "$amd64.json" "$arm64" "$arm64.json" | sha256sum --check
)
python3 - "$output/$index.json" "$amd64" "$arm64" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as file:
    index = json.load(file)
assert index["mediaType"] == "application/vnd.oci.image.index.v1+json"
platforms = {d["platform"]["architecture"]: d["digest"]
             for d in index["manifests"] if d["platform"]["os"] == "linux"}
assert platforms == {"amd64": "sha256:" + sys.argv[2], "arm64": "sha256:" + sys.argv[3]}
PYTHON
curl -q -fsS --retry 2 --max-time 45 --proto '=https' \
  "https://raw.githubusercontent.com/BerriAI/litellm/$source/LICENSE" -o "$output/LiteLLM-LICENSE"
cmp licenses/LiteLLM-LICENSE "$output/LiteLLM-LICENSE"
printf 'upstream_version=v1.104.0-rc.2 upstream_source=%s upstream_index=sha256:%s upstream_amd64=sha256:%s upstream_arm64=sha256:%s\n' "$source" "$index" "$amd64" "$arm64"
