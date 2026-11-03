#!/usr/bin/env bash
# bbss-systeem / db / tests / run_tests.sh
# Draait de tests van bouwstap 1 op een wegwerp-Postgres 16 in Docker.
# Gebruik (vanuit de map bbss-systeem):  bash db/tests/run_tests.sh
# Na afloop wordt de container verwijderd. Er worden geen echte gegevens gebruikt.

set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash op Windows: paden niet omzetten

NAAM=bbss-test-pg
KLANT=11111111-1111-1111-1111-111111111111
DB_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"   # pwd -W: Windows-pad onder Git Bash
FOUT=0

opruimen() { docker rm -f "$NAAM" >/dev/null 2>&1 || true; }
trap opruimen EXIT
opruimen

echo "== Postgres 16 starten"
docker run -d --name "$NAAM" -e POSTGRES_PASSWORD=test -e TZ=Europe/Amsterdam postgres:16 >/dev/null
for i in $(seq 1 60); do
  docker exec "$NAAM" pg_isready -U postgres -h localhost >/dev/null 2>&1 && break
  sleep 1
done
docker cp "$DB_DIR/." "$NAAM:/db"

als() {  # als <rol> <psql-argumenten...>
  local rol=$1; shift
  local ww=test
  docker exec -e PGPASSWORD=$ww "$NAAM" psql -X -q -v ON_ERROR_STOP=1 -h localhost -U "$rol" "$@"
}

echo "== 000_rollen.sql (postgres)"
docker exec -e PGPASSWORD=test "$NAAM" psql -X -q -v ON_ERROR_STOP=1 -h localhost -U postgres \
  -v admin_ww=test -v app_ww=test -f /db/000_rollen.sql
echo "== 001_schema.sql en 002_functies.sql (bbss_admin)"
als bbss_admin -d bbss -f /db/001_schema.sql
als bbss_admin -d bbss -f /db/002_functies.sql

echo "== Tests na elkaar (bbss_admin)"
als bbss_admin -d bbss -f /db/tests/test_volgorde.sql

echo "== Rechten van bbss_app"
als bbss_app -d bbss -f /db/tests/test_rechten_app.sql

WERK=$(mktemp -d)
parallel() {  # parallel <aantal> <sql>  -> één uitkomst per regel
  local n=$1 sql=$2 pids=() i
  for i in $(seq 1 "$n"); do
    ( als bbss_app -d bbss -At -c "$sql" > "$WERK/par_$i.txt" ) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 1 "$n"); do cat "$WERK/par_$i.txt"; rm -f "$WERK/par_$i.txt"; done
}

controleer() {  # controleer <naam> <verwacht> <werkelijk>
  if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FOUT $1: verwacht '$2', kreeg '$3'"; FOUT=1; fi
}

echo "== Gelijktijdig: teller op 39, 5 keer tegelijk tel_sms terugbel"
als bbss_admin -d bbss -c "UPDATE maandtellers SET sms_terugbel = 39, sms_review = 0
  WHERE klant_id = '$KLANT' AND maand = huidige_maand();" >/dev/null
UIT=$(parallel 5 "SELECT tel_sms('$KLANT', huidige_maand(), 'terugbel')")
controleer "precies 1 keer true" 1 "$(grep -c '^t$' <<<"$UIT" || true)"
controleer "teller staat op 40" 40 "$(als bbss_admin -d bbss -At -c "SELECT sms_terugbel FROM maandtellers WHERE klant_id='$KLANT' AND maand=huidige_maand()")"

echo "== Gelijktijdig: 5 keer tegelijk reserveer_terugbel_sms voor hetzelfde nummer"
als bbss_admin -d bbss -c "UPDATE maandtellers SET sms_terugbel = 0, sms_review = 0
  WHERE klant_id = '$KLANT' AND maand = huidige_maand();" >/dev/null
UIT=$(parallel 5 "SELECT uitkomst FROM reserveer_terugbel_sms('$KLANT', '+31699999999', 'CApar')")
controleer "precies 1 keer ok" 1 "$(grep -c '^ok$' <<<"$UIT" || true)"
controleer "4 keer binnen_24u" 4 "$(grep -c '^binnen_24u$' <<<"$UIT" || true)"
controleer "precies 1 rij gereserveerd" 1 "$(als bbss_admin -d bbss -At -c "SELECT count(*) FROM sms_log WHERE naar_nummer='+31699999999' AND status='gereserveerd'")"
controleer "teller staat op 1" 1 "$(als bbss_admin -d bbss -At -c "SELECT sms_terugbel FROM maandtellers WHERE klant_id='$KLANT' AND maand=huidige_maand()")"

echo "== Gelijktijdig: 2 keer tegelijk reserveer_review_sms voor dezelfde opdracht"
OPDR=$(als bbss_admin -d bbss -At -c "INSERT INTO review_opdrachten (klant_id, bron, bron_ref, mobiel, verstuur_na)
  VALUES ('$KLANT', 'formulier', 'par', '+31698765432', now() - interval '1 minute') RETURNING id" | head -n1)
UIT=$(parallel 2 "SELECT uitkomst FROM reserveer_review_sms($OPDR)")
controleer "precies 1 keer ok" 1 "$(grep -c '^ok$' <<<"$UIT" || true)"
controleer "precies 1 keer bezig" 1 "$(grep -c '^bezig$' <<<"$UIT" || true)"

echo "== klant_afmelden.sql"
als bbss_admin -d bbss -c "UPDATE klanten SET status = 'opgezegd', opgezegd_op = now() WHERE id = '$KLANT'" >/dev/null
als bbss_admin -d bbss -v slug=testklant -f /db/klant_afmelden.sql >/dev/null
controleer "geen oproepen meer" 0 "$(als bbss_admin -d bbss -At -c "SELECT count(*) FROM oproepen WHERE klant_id='$KLANT'")"
controleer "geen sms_log meer" 0 "$(als bbss_admin -d bbss -At -c "SELECT count(*) FROM sms_log WHERE klant_id='$KLANT'")"
controleer "contactgegevens leeg" "t" "$(als bbss_admin -d bbss -At -c "SELECT vakman_mobiel IS NULL AND twilio_auth_token_enc IS NULL FROM klanten WHERE id='$KLANT'")"
controleer "maandtellers blijven" "t" "$(als bbss_admin -d bbss -At -c "SELECT count(*) > 0 FROM maandtellers WHERE klant_id='$KLANT'")"

echo
if [ "$FOUT" = 0 ]; then echo "ALLE TESTS VAN BOUWSTAP 1 (DATABASE) GESLAAGD"; else echo "ER ZIJN FOUTEN"; exit 1; fi
