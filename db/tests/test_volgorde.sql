-- bbss-systeem / db / tests / test_volgorde.sql
-- Tests voor bouwstap 1 die na elkaar draaien. Een mislukte ASSERT stopt het script.
-- Draai als bbss_admin op een lege testdatabase, na 000, 001 en 002.

\set ON_ERROR_STOP on
\pset footer off

-- Hulpfuncties (alleen voor deze sessie)
CREATE FUNCTION pg_temp.moet_falen(p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN others THEN
        RETURN;
    END;
    RAISE EXCEPTION 'Had moeten falen, maar lukte: %', p_sql;
END $$;

CREATE FUNCTION pg_temp.klant_sql(p_naam text, p_domein text) RETURNS text LANGUAGE sql AS $$
    SELECT format(
      'INSERT INTO klanten (slug, bedrijfsnaam, domein, abonnement, status, twilio_subaccount_sid, '
      'twilio_nummer, twilio_ophang_url, maandprijs_cent) VALUES (%L, %L, %L, ''sms'', ''proef'', %L, %L, ''https://x'', 3500)',
      'k' || substr(md5(random()::text), 1, 10), p_naam, p_domein,
      'AC' || md5(random()::text), '+3197' || lpad((floor(random() * 1e8))::bigint::text, 8, '0'));
$$;

-- De vaste testklant
INSERT INTO klanten (id, slug, bedrijfsnaam, domein, abonnement, status, twilio_subaccount_sid,
                     twilio_nummer, twilio_ophang_url, maandprijs_cent)
VALUES ('11111111-1111-1111-1111-111111111111', 'testklant', 'Jansen Dak', 'jansendak.nl', 'sms', 'proef',
        'AC' || repeat('a', 32), '+3197010000001', 'https://handler.twilio.com/twiml/EH1', 3500);

\echo '== normaliseer_06'
DO $$ BEGIN
    ASSERT normaliseer_06('06 12 34 56 78')    = '+31612345678', '06 met spaties';
    ASSERT normaliseer_06('06-12345678')       = '+31612345678', '06 met streepje';
    ASSERT normaliseer_06('+31 6 1234 5678')   = '+31612345678', '+31 6';
    ASSERT normaliseer_06('0031612345678')     = '+31612345678', '0031';
    ASSERT normaliseer_06('+31 (0)6 12345678') = '+31612345678', '+31 (0)6';
    ASSERT normaliseer_06('31612345678')       = '+31612345678', '316 zonder plus';
    ASSERT normaliseer_06('020 123 4567') IS NULL, 'vast nummer';
    ASSERT normaliseer_06('0612345')      IS NULL, 'te kort';
    ASSERT normaliseer_06(NULL)           IS NULL, 'leeg';
END $$;
\echo 'OK'

\echo '== bedrijfsnaam en domein (GSM-7, lengte, 52 tekens)'
\o /dev/null
SELECT pg_temp.moet_falen(pg_temp.klant_sql('Bouw € Co', 'bouw.nl'));
SELECT pg_temp.moet_falen(pg_temp.klant_sql('Bouw [Co]', 'bouw.nl'));
SELECT pg_temp.moet_falen(pg_temp.klant_sql('Daniëls Dak', 'dak.nl'));
SELECT pg_temp.moet_falen(pg_temp.klant_sql(repeat('a', 44), 'a.nl'));                 -- 44 tekens
SELECT pg_temp.moet_falen(pg_temp.klant_sql(repeat('a', 34), 'jansendak.nl'));         -- 34+12+7 = 53
DO $$ BEGIN EXECUTE pg_temp.klant_sql(repeat('a', 33), 'jansendak.nl'); END $$;        -- 33+12+7 = 52
DO $$ BEGIN EXECUTE pg_temp.klant_sql('Café & Bouw-Öle', 'cafe.nl'); END $$;           -- é, &, -, Ö toegestaan
SELECT pg_temp.moet_falen(pg_temp.klant_sql('Bouw', 'Bouw.NL'));                       -- hoofdletters in domein
\o
\echo 'OK'

\echo '== eerste_werkdag_volgende_maand'
DO $$ BEGIN
    -- 1 december 2026 is een dinsdag; 10:00 CET = 09:00 UTC
    ASSERT eerste_werkdag_volgende_maand('2026-11-15 12:00+01') = '2026-12-01 09:00+00', 'december';
    -- 1 augustus 2026 is een zaterdag; dus maandag 3 augustus 10:00 CEST = 08:00 UTC
    ASSERT eerste_werkdag_volgende_maand('2026-07-10 12:00+02') = '2026-08-03 08:00+00', 'augustus';
END $$;
\echo 'OK'

\echo '== tel_sms review: teller op 29, 2 keer aanroepen, precies 1 keer true'
INSERT INTO maandtellers (klant_id, maand, sms_review)
VALUES ('11111111-1111-1111-1111-111111111111', huidige_maand(), 29);
DO $$ DECLARE a boolean; b boolean; BEGIN
    a := tel_sms('11111111-1111-1111-1111-111111111111', huidige_maand(), 'review');
    b := tel_sms('11111111-1111-1111-1111-111111111111', huidige_maand(), 'review');
    ASSERT a AND NOT b, format('verwacht true,false; kreeg %s,%s', a, b);
END $$;
\echo 'OK'

\echo '== drempel_bereikt: 80 bij 32, 100 bij 40, elk maar één keer'
UPDATE maandtellers SET sms_review = 0, sms_terugbel = 31
 WHERE klant_id = '11111111-1111-1111-1111-111111111111' AND maand = huidige_maand();
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; BEGIN
    ASSERT drempel_bereikt(k, huidige_maand()) IS NULL, 'bij 31 nog niets';
    PERFORM tel_sms(k, huidige_maand(), 'terugbel');                     -- 32
    ASSERT drempel_bereikt(k, huidige_maand()) = '80',  'bij 32: 80';
    ASSERT drempel_bereikt(k, huidige_maand()) IS NULL, '80 maar één keer';
    UPDATE maandtellers SET sms_terugbel = 39 WHERE klant_id = k AND maand = huidige_maand();
    PERFORM tel_sms(k, huidige_maand(), 'terugbel');                     -- 40
    ASSERT drempel_bereikt(k, huidige_maand()) = '100', 'bij 40: 100';
    ASSERT drempel_bereikt(k, huidige_maand()) IS NULL, '100 maar één keer';
    ASSERT NOT tel_sms(k, huidige_maand(), 'terugbel'), 'boven 40 geen SMS';
END $$;
\echo 'OK'

\echo '== reserveer_terugbel_sms: vast nummer, ok, binnen 24 uur, afgemeld, plafond'
UPDATE maandtellers SET sms_terugbel = 0, gewaarschuwd_80 = false, gewaarschuwd_100 = false
 WHERE klant_id = '11111111-1111-1111-1111-111111111111' AND maand = huidige_maand();
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; u text; BEGIN
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31201234567', 'CA1'); ASSERT u = 'vast_nummer', u;
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, 'anonymous',    'CA2'); ASSERT u = 'vast_nummer', u;
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31611111111', 'CA3'); ASSERT u = 'ok', u;
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31611111111', 'CA4'); ASSERT u = 'binnen_24u', u;
    INSERT INTO afmeldingen (klant_id, mobiel) VALUES (k, '+31622222222');
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31622222222', 'CA5'); ASSERT u = 'afgemeld', u;
    UPDATE maandtellers SET sms_terugbel = 40 WHERE klant_id = k AND maand = huidige_maand();
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31633333333', 'CA6'); ASSERT u = 'plafond', u;
END $$;
\echo 'OK'

\echo '== geef_sms_terug: rij op mislukt, teller 1 lager, en daarna telt de rij niet meer mee'
UPDATE maandtellers SET sms_terugbel = 5
 WHERE klant_id = '11111111-1111-1111-1111-111111111111' AND maand = huidige_maand();
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; v_id bigint; u text; t int; BEGIN
    SELECT r.sms_id INTO v_id FROM reserveer_terugbel_sms(k, '+31644444444', 'CA7') r;
    SELECT sms_terugbel INTO t FROM maandtellers WHERE klant_id = k AND maand = huidige_maand();
    ASSERT t = 6, 'na reservering 6';
    ASSERT geef_sms_terug(v_id), 'teruggeven lukt';
    ASSERT (SELECT status FROM sms_log WHERE sms_log.id = v_id) = 'mislukt', 'status mislukt';
    SELECT sms_terugbel INTO t FROM maandtellers WHERE klant_id = k AND maand = huidige_maand();
    ASSERT t = 5, 'na teruggeven 5';
    ASSERT NOT geef_sms_terug(v_id), 'tweede keer teruggeven doet niets';
    SELECT uitkomst INTO u FROM reserveer_terugbel_sms(k, '+31644444444', 'CA8');
    ASSERT u = 'ok', 'een mislukte SMS telt niet mee voor de 24-uursregel';
END $$;
\echo 'OK'

\echo '== reserveer_review_sms: ok, overgeslagen (30 dagen), uitgesteld (plafond), bezig'
UPDATE maandtellers SET sms_terugbel = 0, sms_review = 0
 WHERE klant_id = '11111111-1111-1111-1111-111111111111' AND maand = huidige_maand();
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; o1 bigint; o2 bigint; o3 bigint;
              u text; s bigint; BEGIN
    INSERT INTO review_opdrachten (klant_id, bron, bron_ref, mobiel, verstuur_na)
    VALUES (k, 'formulier', 'r1', '+31655555555', now() - interval '1 minute') RETURNING id INTO o1;
    SELECT r.uitkomst, r.sms_id INTO u, s FROM reserveer_review_sms(o1) r;
    ASSERT u = 'ok', 'eerste opdracht: ' || u;
    ASSERT (SELECT status FROM review_opdrachten WHERE id = o1) = 'verzenden', 'geclaimd';
    SELECT uitkomst INTO u FROM reserveer_review_sms(o1); ASSERT u = 'bezig', 'tweede claim: ' || u;
    -- W07 zou nu versturen; dat bootsen we na:
    UPDATE sms_log SET status = 'verstuurd', message_sid = 'SM1', segmenten = 1 WHERE id = s;
    UPDATE review_opdrachten SET status = 'verstuurd_sms', verstuurd_op = now() WHERE id = o1;

    INSERT INTO review_opdrachten (klant_id, bron, bron_ref, mobiel, verstuur_na)
    VALUES (k, 'formulier', 'r2', '+31655555555', now() - interval '1 minute') RETURNING id INTO o2;
    SELECT uitkomst INTO u FROM reserveer_review_sms(o2); ASSERT u = 'overgeslagen', 'zelfde nummer binnen 30 dagen: ' || u;

    UPDATE maandtellers SET sms_review = 30 WHERE klant_id = k AND maand = huidige_maand();
    INSERT INTO review_opdrachten (klant_id, bron, bron_ref, mobiel, verstuur_na)
    VALUES (k, 'formulier', 'r3', '+31666666666', now() - interval '1 minute') RETURNING id INTO o3;
    SELECT uitkomst INTO u FROM reserveer_review_sms(o3); ASSERT u = 'uitgesteld', 'plafond: ' || u;
    ASSERT (SELECT verstuur_na FROM review_opdrachten WHERE id = o3) = eerste_werkdag_volgende_maand(),
           'uitgesteld tot de eerste werkdag van de volgende maand';
END $$;
\echo 'OK'

\echo '== verhoog_teller en tel_fallback'
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; f int; BEGIN
    PERFORM verhoog_teller(k, 'oproepen', 1);
    PERFORM verhoog_teller(k, 'belminuten', 3);
    PERFORM tel_fallback(k, 'sms_api_fout');
    PERFORM tel_fallback(NULL, 'onbekend_account');      -- zonder klant: alleen de gebeurtenis
    SELECT fallbacks INTO f FROM maandtellers WHERE klant_id = k AND maand = huidige_maand();
    ASSERT f = 1, 'fallbacks = 1';
    ASSERT (SELECT count(*) FROM gebeurtenissen WHERE soort = 'fallback') = 2, 'twee gebeurtenissen';
END $$;
\o /dev/null
SELECT pg_temp.moet_falen($$SELECT verhoog_teller('11111111-1111-1111-1111-111111111111', 'sms_terugbel', 1)$$);
\o
\echo 'OK'

\echo '== mag_pushen: eerste keer wel, binnen het interval niet'
DO $$ BEGIN
    ASSERT mag_pushen('geweigerd:ACxyz', interval '1 hour'), 'eerste melding';
    ASSERT NOT mag_pushen('geweigerd:ACxyz', interval '1 hour'), 'tweede melding binnen het uur';
    ASSERT mag_pushen('geweigerd:ACander', interval '1 hour'), 'andere sleutel';
END $$;
\echo 'OK'

\echo '== opschonen: oude rijen weg, nieuwe blijven, review_vervallen geschreven'
DO $$ DECLARE k uuid := '11111111-1111-1111-1111-111111111111'; BEGIN
    INSERT INTO oproepen (call_sid, klant_id, aangemaakt_op) VALUES ('CAoud', k, now() - interval '91 days'),
                                                                    ('CAnieuw', k, now());
    INSERT INTO voicemails (recording_sid, call_sid, klant_id, ontvangen_op)
         VALUES ('REoud', 'CAoud', k, now() - interval '31 days'), ('REnieuw', 'CAnieuw', k, now());
    INSERT INTO review_opdrachten (klant_id, bron, bron_ref, mobiel, verstuur_na, aangemaakt_op)
         VALUES (k, 'formulier', 'oud', '+31677777777', now(), now() - interval '31 days');
    INSERT INTO maandtellers (klant_id, maand) VALUES (k, maand_van(now() - interval '25 months'));
    PERFORM opschonen();
    ASSERT NOT EXISTS (SELECT 1 FROM oproepen WHERE call_sid = 'CAoud'),   'oude oproep weg';
    ASSERT     EXISTS (SELECT 1 FROM oproepen WHERE call_sid = 'CAnieuw'), 'nieuwe oproep blijft';
    ASSERT NOT EXISTS (SELECT 1 FROM voicemails WHERE recording_sid = 'REoud'), 'oude voicemail weg';
    ASSERT     EXISTS (SELECT 1 FROM voicemails WHERE recording_sid = 'REnieuw'), 'nieuwe voicemail blijft';
    ASSERT NOT EXISTS (SELECT 1 FROM review_opdrachten WHERE bron_ref = 'oud'), 'vervallen opdracht weg';
    ASSERT     EXISTS (SELECT 1 FROM gebeurtenissen WHERE soort = 'review_vervallen'), 'review_vervallen';
    ASSERT NOT EXISTS (SELECT 1 FROM maandtellers WHERE klant_id = k AND maand = maand_van(now() - interval '25 months')),
           'maandteller van 25 maanden geleden weg';
END $$;
\echo 'OK'

\echo 'ALLE VOLGORDE-TESTS GESLAAGD'
