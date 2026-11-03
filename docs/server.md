# Inrichting van de servers

Dit document beschrijft hoe server 1 (Coolify) is ingericht, zodat hij na een crash opnieuw te bouwen is met alleen dit document, de back-ups en de wachtwoordmanager. Ontwerp: bestand 19 in `docs/designs/bbss-pro-technisch-systeem.md`.

Waarden die in de wachtwoordmanager staan, worden hier alleen bij naam genoemd. Vul de open plekken (`…`) in zodra ze bekend zijn.

## Stand

| Onderdeel | Waarde | Datum |
| --- | --- | --- |
| n8n-image (vastgezet) | `n8nio/n8n:…` (lokaal getest: `2.46.4`) | … |
| Draait n8n Code-nodes in een task runner? | Lokaal in 2.46.4: ja, interne modus (de variabelen van de n8n-container komen dan vanzelf bij de runner). Op de server: … | 2026-11-03 |
| Test Code-node (crypto, HMAC, `$env`) | Lokaal geslaagd op 2.46.4. Op de server: … | 2026-11-03 |
| Postgres | `postgres:16` | … |
| Publieke URL van n8n (`WEBHOOK_URL`) | `https://…` | … |
| S3-opslag voor back-ups | … (bijvoorbeeld Hetzner Object Storage, EU) | … |
| Twilio STOP/START zelf afgehandeld voor NL-nummers? Uitgezet? | … | … |
| Twilio-saldowaarschuwing per e-mail ingesteld, drempel | … | … |
| Alarm op de hoofdaccount neemt fouten van subaccounts mee? | ja / nee | … |
| Regelgevingspakket hoofdaccount bruikbaar in subaccounts? | ja / nee | … |
| Gekozen Nederlandse stem voor `<Say>` | … | … |

## Server 1 (Coolify)

### 1. Postgres

1. Een Postgres 16-dienst in Coolify, **niet** publiek bereikbaar (alleen het interne netwerk).
2. Eén Postgres-server met twee databases: `n8n` (voor n8n zelf) en `bbss`.
3. Rollen en database aanmaken, als superuser:

   ```sh
   psql -U postgres -v admin_ww='<uit wachtwoordmanager>' -v app_ww='<uit wachtwoordmanager>' -f db/000_rollen.sql
   ```

4. Schema en functies, als `bbss_admin`:

   ```sh
   psql -U bbss_admin -d bbss -f db/001_schema.sql
   psql -U bbss_admin -d bbss -f db/002_functies.sql
   ```

5. n8n maakt in de Postgres-credential verbinding als `bbss_app` met de database `bbss`.

Lokaal testen vóór het uitrollen: `bash db/tests/run_tests.sh` (vraagt Docker; maakt een wegwerpdatabase).

### 2. n8n

**Variabelen** (in Coolify, bij de n8n-dienst):

| Variabele | Waarde | Waarom |
| --- | --- | --- |
| `WEBHOOK_URL` | `https://<n8n-domein>/` | De publieke URL; nodig voor de handtekeningcontrole (https, geen poort) |
| `GENERIC_TIMEZONE` | `Europe/Amsterdam` | Anders draaien alle cron-tijden in UTC |
| `EXECUTIONS_DATA_PRUNE` | `true` | n8n wist oude uitvoeringen zelf |
| `EXECUTIONS_DATA_MAX_AGE` | `720` | In uren: 30 dagen |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `filesystem` | Bijlagen buiten de database |
| `NODE_FUNCTION_ALLOW_BUILTIN` | `crypto` | Voor de Code-nodes (S01, W00, W05, W13) |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `false` | Code-nodes moeten de sleutels hieronder kunnen lezen. Bewust risico: zie ontwerp, risicotabel |
| `N8N_PAYLOAD_SIZE_MAX` | `16` | Standaard; gewone verzoeken |
| `N8N_FORMDATA_FILE_SIZE_MAX` | `10` | Uploads van W13 in MiB. Naam controleren voor de vastgezette versie |
| `N8N_ENCRYPTION_KEY` | uit wachtwoordmanager | Versleutelt de credentials van n8n |

Draait de vastgezette versie Code-nodes in een **task runner**, zet dan `NODE_FUNCTION_ALLOW_BUILTIN` en de BBSS-variabelen hieronder ook op de runner. In n8n 2.46.4 is de interne modus nog de standaard; die geeft de variabelen van de n8n-container vanzelf door (lokaal getest). n8n meldt dat de interne modus verdwijnt; bij de overstap naar een externe runner horen deze variabelen dus ook op de runner-container.

De test van de Code-node kan ook zonder de editor, met de CLI in de n8n-container:

```sh
n8n import:workflow --input=codenode_test.json
N8N_RUNNERS_BROKER_PORT=5690 n8n execute --id=<workflow-id> --rawOutput
```

(De aparte brokerpoort is nodig omdat de draaiende n8n poort 5679 al gebruikt.)

**Variabelen voor BBSS** (ook bij de n8n-dienst):

| Variabele | Inhoud |
| --- | --- |
| `BBSS_TOKEN_SLEUTEL` | 64 hex-tekens, gemaakt met `openssl rand -hex 32`. Versleutelt de Twilio-tokens en Turnstile-sleutels |
| `TWILIO_HOOFD_AUTH_TOKEN` | Het auth-token van de Twilio-hoofdaccount (ook als n8n-credential) |
| `BBSS_TESTNUMMER` | Het BBSS-testnummer in E.164 |
| `TWILIO_SALDO_DREMPEL` | Ongeveer 7 dagen verbruik, in de valuta van het Twilio-account |
| `USD_EUR_KOERS` | Bijvoorbeeld `0.92`. Euro = USD × koers |
| `TURNSTILE_SECRET_BBSS` | Geheime Turnstile-sleutel van het formulier op bbss.pro |
| `BBSS_MELDADRES` | E-mailadres van BBSS voor de samenvatting en het formulier op bbss.pro |

**Buiten de server bewaren** (wachtwoordmanager): `BBSS_TOKEN_SLEUTEL` en `N8N_ENCRYPTION_KEY`. Zonder die twee is een back-up niet terug te zetten.

**Credentials in n8n** (niet in de export; bij een nieuwe server opnieuw aanmaken):

- Postgres (`bbss_app`, database `bbss`)
- Twilio-hoofdaccount (Account SID en auth-token)
- Brevo (API-sleutel)
- Pushover (app-token en gebruikerssleutel)
- Basisauthenticatie voor de interne formulieren (W00, W08 "losse test")

**Versie vastzetten.** Kies bij bouwstap 1 de actuele stabiele versie en zet die in de tabel "Stand". Een nieuwe versie gaat pas live na een test van S01 (crypto en variabelen in de Code-node) en W06 (HTML-antwoord) op een tijdelijke tweede n8n-container.

**Bouwstap 1, test van de Code-node op de vastgezette versie.** Maak in n8n een tijdelijke workflow met één Code-node met deze inhoud, en voer hem uit:

```js
const crypto = require('crypto');
const sleutel = $env.BBSS_TOKEN_SLEUTEL;
if (!/^[0-9a-f]{64}$/i.test(sleutel || '')) throw new Error('BBSS_TOKEN_SLEUTEL niet leesbaar of geen 64 hex-tekens');
const iv = crypto.randomBytes(12);
const c = crypto.createCipheriv('aes-256-gcm', Buffer.from(sleutel, 'hex'), iv);
const enc = Buffer.concat([c.update('test', 'utf8'), c.final()]);
const d = crypto.createDecipheriv('aes-256-gcm', Buffer.from(sleutel, 'hex'), iv);
d.setAuthTag(c.getAuthTag());
const terug = Buffer.concat([d.update(enc), d.final()]).toString('utf8');
return [{ json: { crypto_werkt: terug === 'test', hoofdtoken_leesbaar: !!$env.TWILIO_HOOFD_AUTH_TOKEN } }];
```

Verwacht: `crypto_werkt: true` en `hoofdtoken_leesbaar: true`. Verwijder de workflow daarna.

### 3. Afscherming

- De n8n-editor alleen via **Cloudflare Access** (gratis voor één gebruiker), inloggen met het e-mailadres van BBSS.
- Publiek alleen `/webhook/*`.
- SSH alleen met een sleutel, op poort 22, met fail2ban. De firewall laat 22, 80 en 443 door.

### 4. Back-up

- Dagelijkse Coolify-back-up van de databases `n8n` en `bbss` naar S3-compatibele opslag in de EU, 30 dagen bewaard.
- Elk kwartaal: een terugzetting testen op een lege database, en daarna `bash db/tests/run_tests.sh`-achtige controles (tellen of de tabellen gevuld zijn).
- Na een terugzetting: W08 met de hand starten (zie `storingen.md`).

### 5. Gezondheid

- Een n8n-webhook `/webhook/health` die `SELECT 1` uitvoert op `bbss`, en pas aan het eind antwoordt ("When Last Node Finishes").
- UptimeRobot controleert elke 5 minuten `/webhook/health` en bbss.pro, met meldingen via de UptimeRobot-app. Nagaan of het gratis plan zakelijk gebruik toestaat.

### 6. Updates

- n8n en Postgres één keer per maand; beveiligingsupdates van n8n binnen 7 dagen.
- Vóór elke update een handmatige back-up.

### 7. Workflows in git

n8n is het origineel van de workflows. Na elke wijziging:

```sh
# op de server
bash scripts/export-workflows.sh          # maakt /tmp/bbss-workflows.tar.gz
# lokaal (Windows, Git Bash)
scp <server>:/tmp/bbss-workflows.tar.gz . && tar -xzf bbss-workflows.tar.gz -C n8n/workflows/
git add n8n/workflows && git commit -m "Workflows bijgewerkt"
```

Bij een nieuwe server: `n8n import:workflow --separate --input=<map>` en daarna de credentials opnieuw aanmaken.

## Twilio-hoofdaccount

- Geen automatisch opwaarderen (besluit 2026-11-03).
- Saldowaarschuwing van Twilio zelf per e-mail aan BBSS, op dezelfde drempel als `TWILIO_SALDO_DREMPEL`.
- Het BBSS-testnummer: een Nederlands nummer in de hoofdaccount, met een eigen regelgevingspakket op naam van BBSS. Vóór bouwstap 3.
- Geo-permissies voor spraak en SMS naar Nederland aan (hoofdaccount, en per subaccount als die niet erven).

## Brevo

- Domein bbss.pro geverifieerd met SPF, DKIM en DMARC (eerst `p=none`, na een maand zonder problemen `p=quarantine`).
- Afzender `meldingen@bbss.pro`.
- Vóór W13: nagaan dat Brevo 10 MB aan bijlagen en `.mp3`-bijlagen accepteert.

## Server 2 (WordPress)

Pas bij de eerste WordPress-klant. Zie het ontwerp, bestand 19.
