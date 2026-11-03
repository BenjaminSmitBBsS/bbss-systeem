-- bbss-systeem / db / 000_rollen.sql
-- Eenmalig uitvoeren als superuser (postgres), vóór 001 en 002.
-- Maakt de twee rollen en de database `bbss`. De database `n8n` beheert n8n zelf.
--
-- Gebruik:
--   psql -U postgres -v admin_ww='…' -v app_ww='…' -f 000_rollen.sql
-- De wachtwoorden komen uit de wachtwoordmanager van BBSS en staan nooit in git.

CREATE ROLE bbss_admin LOGIN PASSWORD :'admin_ww';
CREATE ROLE bbss_app   LOGIN PASSWORD :'app_ww';

CREATE DATABASE bbss OWNER bbss_admin ENCODING 'UTF8' TEMPLATE template0;

\connect bbss
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO bbss_admin;
GRANT USAGE ON SCHEMA public TO bbss_app;
ALTER SCHEMA public OWNER TO bbss_admin;
