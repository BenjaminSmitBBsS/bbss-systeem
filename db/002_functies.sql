-- bbss-systeem / db / 002_functies.sql
-- De functies van het belvangnet en de reviewmodule (ontwerp: bestand 2).
-- Uitvoeren als bbss_admin, na 001:  psql -U bbss_admin -d bbss -f 002_functies.sql
--
-- Elke functie wordt vanuit n8n met één query aangeroepen. Eén aanroep is één transactie,
-- dus wat binnen een functie gebeurt (lock + controle + reservering) is samen atomair.
-- Alle functies zijn VOLATILE: elke opdracht binnen de functie ziet de laatst vastgelegde gegevens.

BEGIN;

-- ---------------------------------------------------------------------------
-- Hulpfuncties voor tijd
-- ---------------------------------------------------------------------------

-- De huidige maand in Nederlandse tijd, bijvoorbeeld '2026-11'.
CREATE FUNCTION huidige_maand() RETURNS char(7)
LANGUAGE sql STABLE AS $$
    SELECT to_char(now() AT TIME ZONE 'Europe/Amsterdam', 'YYYY-MM')::char(7);
$$;

-- De maand waarin een tijdstip valt, in Nederlandse tijd.
CREATE FUNCTION maand_van(p_tijd timestamptz) RETURNS char(7)
LANGUAGE sql STABLE AS $$
    SELECT to_char(p_tijd AT TIME ZONE 'Europe/Amsterdam', 'YYYY-MM')::char(7);
$$;

-- De eerste werkdag (maandag t/m vrijdag) van de volgende maand, om 10:00 Nederlandse tijd.
CREATE FUNCTION eerste_werkdag_volgende_maand(p_vanaf timestamptz DEFAULT now()) RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $$
DECLARE
    d date := (date_trunc('month', p_vanaf AT TIME ZONE 'Europe/Amsterdam') + interval '1 month')::date;
BEGIN
    WHILE extract(isodow FROM d) IN (6, 7) LOOP
        d := d + 1;
    END LOOP;
    RETURN (d + time '10:00') AT TIME ZONE 'Europe/Amsterdam';
END;
$$;

-- ---------------------------------------------------------------------------
-- normaliseer_06: elk schrijfwijze van een Nederlands mobiel nummer naar +316XXXXXXXX,
-- of NULL als het geen 06-nummer is.
-- ---------------------------------------------------------------------------
CREATE FUNCTION normaliseer_06(p_tekst text) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v text := regexp_replace(coalesce(p_tekst, ''), '[[:space:]().-]', '', 'g');
BEGIN
    IF    v ~ '^06[0-9]{8}$'       THEN RETURN '+31' || substr(v, 2);   -- 0612345678
    ELSIF v ~ '^\+316[0-9]{8}$'    THEN RETURN v;                       -- +31612345678
    ELSIF v ~ '^\+3106[0-9]{8}$'   THEN RETURN '+31' || substr(v, 5);   -- +31 (0)6 …
    ELSIF v ~ '^00316[0-9]{8}$'    THEN RETURN '+' || substr(v, 3);     -- 0031612345678
    ELSIF v ~ '^003106[0-9]{8}$'   THEN RETURN '+31' || substr(v, 6);   -- 0031 (0)6 …
    ELSIF v ~ '^316[0-9]{8}$'      THEN RETURN '+' || v;                -- 31612345678
    END IF;
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tellers
-- ---------------------------------------------------------------------------

-- Maakt de maandrij aan als die nog niet bestaat.
CREATE FUNCTION zorg_voor_maandrij(p_klant uuid, p_maand char(7)) RETURNS void
LANGUAGE sql VOLATILE AS $$
    INSERT INTO maandtellers (klant_id, maand) VALUES (p_klant, p_maand) ON CONFLICT DO NOTHING;
$$;

-- Het harde SMS-plafond: hoogt de teller alleen op als het totaal vóór het ophogen
-- onder de grens ligt (40 voor terugbellen, 30 voor reviews). Eén UPDATE, dus ook bij
-- gelijktijdige aanroepen nooit boven de grens: Postgres her-evalueert de WHERE na het
-- wachten op de rijlock.
CREATE FUNCTION tel_sms(p_klant uuid, p_maand char(7), p_soort text) RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM zorg_voor_maandrij(p_klant, p_maand);
    IF p_soort = 'terugbel' THEN
        UPDATE maandtellers SET sms_terugbel = sms_terugbel + 1
         WHERE klant_id = p_klant AND maand = p_maand
           AND sms_terugbel + sms_review < 40;
    ELSIF p_soort = 'review' THEN
        UPDATE maandtellers SET sms_review = sms_review + 1
         WHERE klant_id = p_klant AND maand = p_maand
           AND sms_terugbel + sms_review < 30;
    ELSE
        RAISE EXCEPTION 'tel_sms: onbekende soort %', p_soort;
    END IF;
    RETURN FOUND;
END;
$$;

-- Telt een aantal op bij een teller van de huidige maand. Alleen de kolommen uit de lijst.
CREATE FUNCTION verhoog_teller(p_klant uuid, p_kolom text, p_aantal int) RETURNS void
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_maand char(7) := huidige_maand();
BEGIN
    IF p_kolom NOT IN ('oproepen','voicemails','belminuten','sms_segmenten','fallbacks','ai_minuten') THEN
        RAISE EXCEPTION 'verhoog_teller: kolom % is niet toegestaan', p_kolom;
    END IF;
    PERFORM zorg_voor_maandrij(p_klant, v_maand);
    EXECUTE format('UPDATE maandtellers SET %1$I = %1$I + $1 WHERE klant_id = $2 AND maand = $3', p_kolom)
      USING coalesce(p_aantal, 0), p_klant, v_maand;
END;
$$;

-- Schrijft een fallback-gebeurtenis, en hoogt de teller op als de klant bekend is.
CREATE FUNCTION tel_fallback(p_klant uuid, p_reden text) RETURNS void
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    INSERT INTO gebeurtenissen (klant_id, soort, reden) VALUES (p_klant, 'fallback', p_reden);
    IF p_klant IS NOT NULL THEN
        PERFORM verhoog_teller(p_klant, 'fallbacks', 1);
    END IF;
END;
$$;

-- Geeft '80' of '100' terug als die drempel nu voor het eerst deze maand bereikt is,
-- anders NULL. Zet meteen de vlag, zodat elke waarschuwing maar één keer uitgaat.
-- Alleen voor het SMS-plafond (40); het AI-plafond volgt in fase 2.
CREATE FUNCTION drempel_bereikt(p_klant uuid, p_maand char(7)) RETURNS text
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    UPDATE maandtellers SET gewaarschuwd_100 = true, gewaarschuwd_80 = true
     WHERE klant_id = p_klant AND maand = p_maand
       AND sms_terugbel + sms_review >= 40 AND NOT gewaarschuwd_100;
    IF FOUND THEN RETURN '100'; END IF;

    UPDATE maandtellers SET gewaarschuwd_80 = true
     WHERE klant_id = p_klant AND maand = p_maand
       AND sms_terugbel + sms_review >= 32 AND NOT gewaarschuwd_80;
    IF FOUND THEN RETURN '80'; END IF;

    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- Reserveringen van SMS-berichten
-- ---------------------------------------------------------------------------

-- Terugbel-SMS: alle controles en de reservering in één transactie.
-- Uitkomst: ok | vast_nummer | afgemeld | binnen_24u | plafond.
CREATE FUNCTION reserveer_terugbel_sms(p_klant uuid, p_nummer text, p_call_sid text)
RETURNS TABLE (uitkomst text, sms_id bigint)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_id bigint;
BEGIN
    IF p_nummer IS NULL OR p_nummer !~ '^\+316[0-9]{8}$' THEN
        RETURN QUERY SELECT 'vast_nummer'::text, NULL::bigint; RETURN;
    END IF;

    -- Tot het eind van deze aanroep wacht elke andere aanroep voor dezelfde klant en
    -- hetzelfde nummer. Daarna ziet die de reservering hieronder.
    PERFORM pg_advisory_xact_lock(hashtext(p_klant::text || p_nummer));

    IF EXISTS (SELECT 1 FROM afmeldingen WHERE klant_id = p_klant AND mobiel = p_nummer) THEN
        RETURN QUERY SELECT 'afgemeld'::text, NULL::bigint; RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM sms_log
                WHERE klant_id = p_klant AND naar_nummer = p_nummer AND soort = 'terugbel'
                  AND status IN ('gereserveerd','verstuurd')
                  AND aangemaakt_op > now() - interval '24 hours') THEN
        RETURN QUERY SELECT 'binnen_24u'::text, NULL::bigint; RETURN;
    END IF;

    IF NOT tel_sms(p_klant, huidige_maand(), 'terugbel') THEN
        RETURN QUERY SELECT 'plafond'::text, NULL::bigint; RETURN;
    END IF;

    INSERT INTO sms_log (klant_id, soort, naar_nummer, call_sid, status)
    VALUES (p_klant, 'terugbel', p_nummer, p_call_sid, 'gereserveerd')
    RETURNING id INTO v_id;

    RETURN QUERY SELECT 'ok'::text, v_id;
END;
$$;

-- Review-SMS: claimt de opdracht en doet alle controles in één transactie.
-- Uitkomst: ok | bezig | afgemeld | overgeslagen | uitgesteld.
CREATE FUNCTION reserveer_review_sms(p_opdracht bigint)
RETURNS TABLE (uitkomst text, sms_id bigint)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_klant  uuid;
    v_mobiel text;
    v_id     bigint;
BEGIN
    -- 1. Claim: alleen als de opdracht nog wacht. Twee overlappende runs van W07 kunnen
    --    dezelfde opdracht dus nooit allebei versturen.
    UPDATE review_opdrachten r SET status = 'verzenden'
      FROM klanten k
     WHERE r.id = p_opdracht AND r.klant_id = k.id
       AND r.status IN ('gepland','uitgesteld') AND r.verstuur_na <= now()
       AND k.status IN ('proef','actief')
    RETURNING r.klant_id, r.mobiel INTO v_klant, v_mobiel;
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'bezig'::text, NULL::bigint; RETURN;
    END IF;

    -- 2. Lock op klant en nummer (dezelfde sleutel als bij terugbellen).
    PERFORM pg_advisory_xact_lock(hashtext(v_klant::text || v_mobiel));

    -- 3. Afgemeld?
    IF EXISTS (SELECT 1 FROM afmeldingen WHERE klant_id = v_klant AND mobiel = v_mobiel) THEN
        UPDATE review_opdrachten SET status = 'afgemeld' WHERE id = p_opdracht;
        RETURN QUERY SELECT 'afgemeld'::text, NULL::bigint; RETURN;
    END IF;

    -- 4. 30-dagenregel, inclusief een andere opdracht die op dit moment wordt verstuurd.
    IF EXISTS (SELECT 1 FROM review_opdrachten
                WHERE klant_id = v_klant AND mobiel = v_mobiel AND id <> p_opdracht
                  AND ((status = 'verstuurd_sms' AND verstuurd_op > now() - interval '30 days')
                       OR status = 'verzenden')) THEN
        UPDATE review_opdrachten SET status = 'overgeslagen' WHERE id = p_opdracht;
        RETURN QUERY SELECT 'overgeslagen'::text, NULL::bigint; RETURN;
    END IF;

    -- 5. Plafond (30 voor reviews; de laatste 10 van de 40 blijven voor terugbellen).
    IF NOT tel_sms(v_klant, huidige_maand(), 'review') THEN
        UPDATE review_opdrachten
           SET status = 'uitgesteld', verstuur_na = eerste_werkdag_volgende_maand()
         WHERE id = p_opdracht;
        RETURN QUERY SELECT 'uitgesteld'::text, NULL::bigint; RETURN;
    END IF;

    -- 6. Reservering.
    INSERT INTO sms_log (klant_id, soort, naar_nummer, opdracht_id, status)
    VALUES (v_klant, 'review', v_mobiel, p_opdracht, 'gereserveerd')
    RETURNING id INTO v_id;

    RETURN QUERY SELECT 'ok'::text, v_id;
END;
$$;

-- Een SMS die de Twilio-API weigerde (foutcode, dus geen kosten): rij op 'mislukt' en
-- de teller van die soort in de maand van de reservering weer 1 omlaag.
-- Geeft false als de rij niet (meer) op 'gereserveerd' stond.
CREATE FUNCTION geef_sms_terug(p_sms_id bigint) RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_klant uuid; v_soort text; v_tijd timestamptz;
BEGIN
    UPDATE sms_log SET status = 'mislukt'
     WHERE id = p_sms_id AND status = 'gereserveerd'
    RETURNING klant_id, soort, aangemaakt_op INTO v_klant, v_soort, v_tijd;
    IF NOT FOUND THEN RETURN false; END IF;

    IF v_soort = 'terugbel' THEN
        UPDATE maandtellers SET sms_terugbel = greatest(sms_terugbel - 1, 0)
         WHERE klant_id = v_klant AND maand = maand_van(v_tijd);
    ELSE
        UPDATE maandtellers SET sms_review = greatest(sms_review - 1, 0)
         WHERE klant_id = v_klant AND maand = maand_van(v_tijd);
    END IF;
    RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Meldingslimiet: true als er een pushmelding met deze sleutel mag uitgaan, en schrijft
-- dan meteen 'push_verstuurd'. De sleutel is de soort melding plus slug of AccountSid.
-- ---------------------------------------------------------------------------
CREATE FUNCTION mag_pushen(p_sleutel text, p_interval interval) RETURNS boolean
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('push:' || p_sleutel));
    IF EXISTS (SELECT 1 FROM gebeurtenissen
                WHERE soort = 'push_verstuurd' AND reden = p_sleutel
                  AND tijd > now() - p_interval) THEN
        RETURN false;
    END IF;
    INSERT INTO gebeurtenissen (soort, reden) VALUES ('push_verstuurd', p_sleutel);
    RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Opschonen (W09): wist alles volgens de bewaartermijnen en geeft per tabel het aantal terug.
-- De opnames en records bij Twilio wist W09 zelf via de API.
-- ---------------------------------------------------------------------------
CREATE FUNCTION opschonen() RETURNS TABLE (tabel text, gewist bigint)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE n bigint;
BEGIN
    -- Niet-verstuurde reviewopdrachten vervallen 30 dagen na aanmaken (met een gebeurtenis).
    WITH weg AS (
        DELETE FROM review_opdrachten
         WHERE status IN ('gepland','uitgesteld') AND aangemaakt_op < now() - interval '30 days'
        RETURNING klant_id, id
    )
    INSERT INTO gebeurtenissen (klant_id, soort, reden)
    SELECT klant_id, 'review_vervallen', 'opdracht ' || id FROM weg;
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'review_opdrachten (vervallen)'; gewist := n; RETURN NEXT;

    -- Verstuurde opdrachten 30 dagen na versturen; overige afgehandelde 30 dagen na aanmaken.
    DELETE FROM review_opdrachten
     WHERE (status = 'verstuurd_sms' AND verstuurd_op < now() - interval '30 days')
        OR (status IN ('afgemeld','overgeslagen','mislukt') AND aangemaakt_op < now() - interval '30 days');
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'review_opdrachten'; gewist := n; RETURN NEXT;

    DELETE FROM voicemails WHERE ontvangen_op < now() - interval '30 days';
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'voicemails'; gewist := n; RETURN NEXT;

    DELETE FROM oproepen WHERE aangemaakt_op < now() - interval '90 days';
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'oproepen'; gewist := n; RETURN NEXT;

    DELETE FROM sms_log WHERE aangemaakt_op < now() - interval '90 days';
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'sms_log'; gewist := n; RETURN NEXT;

    DELETE FROM sms_in WHERE ontvangen_op < now() - interval '90 days';
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'sms_in'; gewist := n; RETURN NEXT;

    DELETE FROM gebeurtenissen WHERE tijd < now() - interval '90 days';
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'gebeurtenissen'; gewist := n; RETURN NEXT;

    DELETE FROM maandtellers WHERE maand < maand_van(now() - interval '24 months');
    GET DIAGNOSTICS n = ROW_COUNT; tabel := 'maandtellers'; gewist := n; RETURN NEXT;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO bbss_app;

COMMIT;
