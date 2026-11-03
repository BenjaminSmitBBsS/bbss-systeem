# bbss-systeem

Het belvangnet, de reviewmodule en de bewaking van bbss.pro. Het ontwerp staat in
`C:\Users\Home\0ben\docs\designs\bbss-pro-technisch-systeem.md`.

| Map | Inhoud |
| --- | --- |
| `db/` | `000_rollen.sql`, `001_schema.sql`, `002_functies.sql`, `klant_afmelden.sql` |
| `db/tests/` | Tests van de database. `bash db/tests/run_tests.sh` (vraagt Docker) |
| `n8n/lib/` | Code voor de Code-nodes: versleutelen en de Twilio-handtekening. `node n8n/lib/test_lib.js` |
| `n8n/workflows/` | Export van de workflows (zonder testgegevens) |
| `docs/` | `server.md` (inrichting), later `aanmelden-klant.md` en `storingen.md` |
| `scripts/` | `export-workflows.sh` |

Geheimen staan nooit in deze repository.
