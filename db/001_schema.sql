-- bbss-systeem / db / 001_schema.sql
-- Het schema voor het belvangnet en de reviewmodule (ontwerp: bestand 1).
-- Uitvoeren als bbss_admin in de database bbss:  psql -U bbss_admin -d bbss -f 001_schema.sql
--
-- Regels:
--   * keuzelijsten zijn CHECK-constraints, geen enum-types (een waarde toevoegen = één ALTER);
--   * tijden zijn timestamptz, telefoonnummers tekst in E.164;
--   * een klant wordt nooit gewist, alleen leeggemaakt (zie klant_afmelden.sql).
--   * Niet in fase 1: de tabellen `koppelingen` (bouwstap 6) en `ai_gesprekken` (fase 2).

BEGIN;

-- ---------------------------------------------------------------------------
-- klanten
-- ---------------------------------------------------------------------------
CREATE TABLE klanten (
    id                     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                   text        NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]+$'),
    -- Alleen de GSM-7-basisset: geen LF/CR, geen uitbreidingstabel (€ [ ] { } | ~ ^ \),
    -- want die tellen als 2 tekens. Het '-' staat bewust aan het eind van de lijst.
    bedrijfsnaam           varchar(43) NOT NULL
        CHECK (bedrijfsnaam ~ '^[@£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&''()*+,./0-9:;<=>?¡A-ZÄÖÑÜ§¿a-zäöñüà-]+$'),
    domein                 text        NOT NULL CHECK (domein ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
    abonnement             text        NOT NULL CHECK (abonnement IN ('sms','ai')),
    status                 text        NOT NULL CHECK (status IN ('proef','actief','opgezegd')),
    twilio_subaccount_sid  text        NOT NULL UNIQUE CHECK (twilio_subaccount_sid ~ '^AC[0-9a-f]{32}$'),
    twilio_nummer          text        NOT NULL UNIQUE CHECK (twilio_nummer ~ '^\+[1-9][0-9]{6,14}$'),
    twilio_auth_token_enc  bytea,      -- iv(12) ‖ tag(16) ‖ versleutelde tekst; leeg na afmelden
    twilio_ophang_url      text        NOT NULL,
    vakman_mobiel          text,       -- leeg na afmelden
    vakman_email           text,       -- leeg na afmelden
    review_bron            text        NOT NULL DEFAULT 'formulier',
    formulier_token_hash   text        CHECK (formulier_token_hash ~ '^[0-9a-f]{64}$'),  -- SHA-256 in hex
    turnstile_secret_enc   bytea,
    maandprijs_cent        int         NOT NULL CHECK (maandprijs_cent >= 0),
    laatste_oproep_op      timestamptz,
    aangemaakt_op          timestamptz NOT NULL DEFAULT now(),
    opgezegd_op            timestamptz,
    -- De review-SMS (§5) is 108 tekens plus naam plus '<domein>/review'. Samen ≤ 160.
    CONSTRAINT review_sms_past_in_1_segment
        CHECK (char_length(bedrijfsnaam) + char_length(domein) + 7 <= 52)
);

-- ---------------------------------------------------------------------------
-- maandtellers (geen persoonsgegevens; 24 maanden bewaard)
-- ---------------------------------------------------------------------------
CREATE TABLE maandtellers (
    klant_id            uuid    NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    maand               char(7) NOT NULL CHECK (maand ~ '^[0-9]{4}-[0-9]{2}$'),
    oproepen            int     NOT NULL DEFAULT 0,
    voicemails          int     NOT NULL DEFAULT 0,
    sms_terugbel        int     NOT NULL DEFAULT 0,
    sms_review          int     NOT NULL DEFAULT 0,
    sms_segmenten       int     NOT NULL DEFAULT 0,
    belminuten          int     NOT NULL DEFAULT 0,
    ai_gesprekken       int     NOT NULL DEFAULT 0,
    ai_minuten          int     NOT NULL DEFAULT 0,
    fallbacks           int     NOT NULL DEFAULT 0,
    kosten_twilio_cent  int     NOT NULL DEFAULT 0,
    gewaarschuwd_80     boolean NOT NULL DEFAULT false,
    gewaarschuwd_100    boolean NOT NULL DEFAULT false,
    PRIMARY KEY (klant_id, maand)
);

-- ---------------------------------------------------------------------------
-- oproepen (90 dagen)
-- ---------------------------------------------------------------------------
CREATE TABLE oproepen (
    call_sid            text        PRIMARY KEY,
    klant_id            uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    van_nummer          text,       -- leeg zolang W02 nog niet klaar is
    start               timestamptz,
    duur_sec            int,
    uitkomst            text CHECK (uitkomst IN ('sms','voicemail','ai','plafond','vast_nummer',
                                                 'afgemeld','binnen_24u','test','fallback')),
    email_verstuurd_op  timestamptz,
    aangemaakt_op       timestamptz NOT NULL DEFAULT now()  -- voor de bewaartermijn
);
CREATE INDEX oproepen_klant_start ON oproepen (klant_id, start);
CREATE INDEX oproepen_aangemaakt  ON oproepen (aangemaakt_op);

-- ---------------------------------------------------------------------------
-- sms_in: binnengekomen berichten, zonder tekst (90 dagen)
-- ---------------------------------------------------------------------------
CREATE TABLE sms_in (
    message_sid   text        PRIMARY KEY,
    klant_id      uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    ontvangen_op  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sms_in_ontvangen ON sms_in (ontvangen_op);

-- ---------------------------------------------------------------------------
-- review_opdrachten (verstuurd: 30 dagen na versturen; anders 30 dagen na aanmaken)
-- ---------------------------------------------------------------------------
CREATE TABLE review_opdrachten (
    id             bigserial   PRIMARY KEY,
    klant_id       uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    bron           text        NOT NULL,
    bron_ref       text        NOT NULL,
    naam           text,
    mobiel         text        NOT NULL CHECK (mobiel ~ '^\+316[0-9]{8}$'),
    verstuur_na    timestamptz NOT NULL,
    status         text        NOT NULL DEFAULT 'gepland'
        CHECK (status IN ('gepland','verzenden','verstuurd_sms','uitgesteld','afgemeld','overgeslagen','mislukt')),
    aangemaakt_op  timestamptz NOT NULL DEFAULT now(),
    verstuurd_op   timestamptz,
    UNIQUE (klant_id, bron, bron_ref)
);
CREATE INDEX review_status_verstuur ON review_opdrachten (status, verstuur_na);
CREATE INDEX review_klant_mobiel    ON review_opdrachten (klant_id, mobiel, verstuurd_op);

-- ---------------------------------------------------------------------------
-- sms_log (90 dagen)
-- ---------------------------------------------------------------------------
CREATE TABLE sms_log (
    id             bigserial   PRIMARY KEY,
    klant_id       uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    soort          text        NOT NULL CHECK (soort IN ('terugbel','review')),
    naar_nummer    text        NOT NULL,
    call_sid       text,       -- bij een terugbel-SMS
    opdracht_id    bigint      REFERENCES review_opdrachten(id) ON DELETE SET NULL,  -- bij een review-SMS
    message_sid    text        UNIQUE,  -- leeg zolang niet verstuurd
    segmenten      int,
    status         text        NOT NULL CHECK (status IN ('gereserveerd','verstuurd','mislukt')),
    aangemaakt_op  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT terugbel_heeft_call_sid CHECK (soort <> 'terugbel' OR call_sid IS NOT NULL)
);
CREATE INDEX sms_log_24u    ON sms_log (klant_id, naar_nummer, soort, aangemaakt_op);
CREATE INDEX sms_log_status ON sms_log (status, aangemaakt_op);

-- ---------------------------------------------------------------------------
-- voicemails (30 dagen). Bewust géén foreign key naar oproepen:
-- de opname komt vaak eerder binnen dan de oproep, en bij een storing is er geen oproeprij.
-- ---------------------------------------------------------------------------
CREATE TABLE voicemails (
    recording_sid  text        PRIMARY KEY,
    call_sid       text        NOT NULL,
    klant_id       uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    duur_sec       int,
    ontvangen_op   timestamptz NOT NULL DEFAULT now(),
    gemaild        boolean     NOT NULL DEFAULT false
);
CREATE INDEX voicemails_call     ON voicemails (call_sid);
CREATE INDEX voicemails_ongemaild ON voicemails (gemaild, ontvangen_op) WHERE NOT gemaild;

-- ---------------------------------------------------------------------------
-- afmeldingen (zolang de overeenkomst loopt)
-- ---------------------------------------------------------------------------
CREATE TABLE afmeldingen (
    klant_id  uuid        NOT NULL REFERENCES klanten(id) ON DELETE RESTRICT,
    mobiel    text        NOT NULL,
    op        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (klant_id, mobiel)
);

-- ---------------------------------------------------------------------------
-- gebeurtenissen (90 dagen). klant_id mag leeg zijn (onbekend account, systeemgebeurtenis).
-- De soorten staan in de tabel in het ontwerp (bestand 1).
-- ---------------------------------------------------------------------------
CREATE TABLE gebeurtenissen (
    id        bigserial   PRIMARY KEY,
    tijd      timestamptz NOT NULL DEFAULT now(),
    klant_id  uuid        REFERENCES klanten(id) ON DELETE RESTRICT,
    soort     text        NOT NULL CHECK (soort IN (
                  'fallback','geweigerd','test_geslaagd','test_mislukt','afmelding','aanmelding',
                  'review_zonder_06','koppeling_fout','review_mislukt','review_vervallen',
                  'formulier_limiet','sms_onbezorgd','drempel_100','mail_mislukt','workflow_fout',
                  'controle_klaar','push_verstuurd')),
    reden     text
);
CREATE INDEX gebeurtenissen_soort_tijd ON gebeurtenissen (soort, tijd);
CREATE INDEX gebeurtenissen_klant_tijd ON gebeurtenissen (klant_id, tijd);
CREATE INDEX gebeurtenissen_push       ON gebeurtenissen (reden, tijd) WHERE soort = 'push_verstuurd';

-- ---------------------------------------------------------------------------
-- Rechten voor n8n (rol bbss_app)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO bbss_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO bbss_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO bbss_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT                  ON SEQUENCES TO bbss_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE                        ON FUNCTIONS TO bbss_app;

COMMIT;
