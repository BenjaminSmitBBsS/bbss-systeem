-- bbss-systeem / db / klant_afmelden.sql
-- Wist de gegevens van een opgezegde klant (ontwerp: bestand 17, "Afmelden van een klant", stap 4).
-- Pas uitvoeren nadat de doorschakeling is verwijderd en het Twilio-subaccount is gesloten.
--
-- Gebruik:  psql -U bbss_admin -d bbss -v slug=jansen-dak -f klant_afmelden.sql
-- Werkt alleen voor een klant met status 'opgezegd'; anders gebeurt er niets.

\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE af ON COMMIT DROP AS
SELECT id FROM klanten WHERE slug = :'slug' AND status = 'opgezegd';

SELECT CASE WHEN count(*) = 1 THEN 'Klant gevonden, gegevens worden gewist.'
            ELSE 'Geen opgezegde klant met deze slug. Er wordt niets gewist.' END AS melding
  FROM af;

DELETE FROM sms_log           WHERE klant_id IN (SELECT id FROM af);
DELETE FROM review_opdrachten WHERE klant_id IN (SELECT id FROM af);
DELETE FROM oproepen          WHERE klant_id IN (SELECT id FROM af);
DELETE FROM sms_in            WHERE klant_id IN (SELECT id FROM af);
DELETE FROM voicemails        WHERE klant_id IN (SELECT id FROM af);
DELETE FROM afmeldingen       WHERE klant_id IN (SELECT id FROM af);
DELETE FROM gebeurtenissen    WHERE klant_id IN (SELECT id FROM af);

-- De rij blijft bestaan voor maandtellers (geen persoonsgegevens, 24 maanden bewaard).
UPDATE klanten
   SET vakman_mobiel = NULL, vakman_email = NULL,
       twilio_auth_token_enc = NULL, formulier_token_hash = NULL, turnstile_secret_enc = NULL
 WHERE id IN (SELECT id FROM af);

COMMIT;
