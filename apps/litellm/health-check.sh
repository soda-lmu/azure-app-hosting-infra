#!/usr/bin/env bash
# Checks the LiteLLM started by docker-compose.yml (localhost:4000): waits until it answers and is
# connected to its database. Used by CI (litellm-ci.yml) and by mise run test:litellm.
# --models: also sends one small request to every model in config.yaml (LiteLLM's /health). Needs a
# real AZURE_API_KEY in .env and costs a few tokens.
# On failure, prints the end of LiteLLM's logs (CI prints all of them in a separate step).
set -euo pipefail
cd "$(dirname "$0")"
URL=http://localhost:4000
MASTER_KEY=sk-local-test # as in docker-compose.yml

fail() { # prefix: an annotation in GitHub Actions
  echo "${GITHUB_ACTIONS:+::error::}$1" >&2
  [[ ${2:-} == logs && -z ${GITHUB_ACTIONS:-} ]] && docker compose logs --tail 100 litellm >&2
  exit 1
}

healthy=
SECONDS=0
while (( SECONDS < 180 )); do # up to 3 minutes
  if curl -sf -m 5 "$URL/health/liveliness" > /dev/null &&
     curl -sf -m 5 "$URL/health/readiness" | jq -e '.db == "connected"' > /dev/null; then
    healthy=1; break
  fi
  sleep 2
done
[[ -n $healthy ]] || fail "LiteLLM did not become healthy within 3 minutes" logs
echo "LiteLLM is healthy (database connected)"

if [[ ${1:-} == --models ]]; then
  result=$(curl -sf -m 300 "$URL/health" -H "Authorization: Bearer $MASTER_KEY") ||
    fail "Model check failed (/health)" logs
  jq -r '.healthy_endpoints[]? | "  ok      \(.model)"' <<< "$result"
  jq -r '.unhealthy_endpoints[]? | "  FAILED  \(.model): \(.error // "" | tostring | split("\n")[0] | .[:200])"' <<< "$result"
  [[ $(jq '.unhealthy_count' <<< "$result") == 0 ]] || fail "Some models failed"
fi
