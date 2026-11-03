-- bbss-systeem / db / tests / test_rechten_app.sql
-- Draai als bbss_app (de rol van n8n). Controleert de rechten uit bestand 1:
-- een rij toevoegen via een sequence, een functie uitvoeren en een rij wissen.

\set ON_ERROR_STOP on

-- Toevoegen in een tabel met een bigserial (rechten op de sequence) via een functie.
SELECT uitkomst FROM reserveer_terugbel_sms('11111111-1111-1111-1111-111111111111', '+31688888888', 'CAapp');

-- Rechtstreeks toevoegen en wissen.
INSERT INTO gebeurtenissen (soort, reden) VALUES ('workflow_fout', 'rechtentest');
DELETE FROM gebeurtenissen WHERE reden = 'rechtentest';

-- Mag geen tabellen aanmaken.
DO $$ BEGIN
    BEGIN
        EXECUTE 'CREATE TABLE mag_niet (x int)';
        RAISE EXCEPTION 'bbss_app kon een tabel aanmaken';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
END $$;

\echo 'RECHTEN bbss_app GESLAAGD'
