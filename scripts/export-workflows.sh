#!/usr/bin/env bash
# bbss-systeem / scripts / export-workflows.sh
# Draait op server 1. Exporteert alle n8n-workflows, haalt de vastgezette testgegevens
# (pinData) eruit, geeft elk bestand de naam van de workflow, en pakt alles in.
# Gebruik:  bash export-workflows.sh [naam-van-de-n8n-container]
# Uitvoer:  /tmp/bbss-workflows.tar.gz
# Vereist:  docker en jq op de server.

set -euo pipefail
CONTAINER="${1:-$(docker ps --format '{{.Names}}' | grep -m1 n8n)}"
WERK="$(mktemp -d)"
trap 'rm -rf "$WERK"' EXIT

docker exec "$CONTAINER" sh -c 'rm -rf /tmp/wf && mkdir -p /tmp/wf && n8n export:workflow --all --separate --output=/tmp/wf/' >/dev/null
docker cp "$CONTAINER:/tmp/wf/." "$WERK/ruw"
docker exec "$CONTAINER" rm -rf /tmp/wf

mkdir -p "$WERK/schoon"
for f in "$WERK"/ruw/*.json; do
  naam="$(jq -r '.name' "$f" | tr -c 'A-Za-z0-9_-' '_' | sed 's/_*$//')"
  # Geen echte telefoonnummers in git: testgegevens eruit.
  jq 'del(.pinData)' "$f" > "$WERK/schoon/${naam}.json"
done

# Controle: geen 06-nummers meer in de bestanden.
if grep -RqE '\+316[0-9]{8}' "$WERK/schoon"; then
  echo "LET OP: er staan nog 06-nummers in een workflow. Controleer voordat je commit:" >&2
  grep -RlE '\+316[0-9]{8}' "$WERK/schoon" >&2
fi

tar -czf /tmp/bbss-workflows.tar.gz -C "$WERK/schoon" .
echo "Klaar: /tmp/bbss-workflows.tar.gz ($(ls "$WERK/schoon" | wc -l) workflows)"
