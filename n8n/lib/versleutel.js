// bbss-systeem / n8n / lib / versleutel.js
// Versleutelen en ontsleutelen van geheimen in Postgres (ontwerp: "Geheimen", Versleutelformaat).
// Deze code wordt letterlijk gekopieerd in de Code-nodes van W00, S01, W05 en W13.
//
// Formaat:   iv (12 bytes) ‖ auth-tag (16 bytes) ‖ versleutelde tekst, AES-256-GCM.
// Sleutel:   BBSS_TOKEN_SLEUTEL = 32 bytes als 64 hex-tekens  (openssl rand -hex 32).
// Transport: n8n geeft de waarde als hex-tekst door. In SQL:
//              opslaan:  UPDATE … SET kolom = decode($1, 'hex')
//              lezen:    SELECT encode(kolom, 'hex') AS kolom_hex …

const crypto = require('crypto');

function sleutelUit(hex) {
  if (typeof hex !== 'string' || !/^[0-9a-fA-F]{64}$/.test(hex)) {
    throw new Error('BBSS_TOKEN_SLEUTEL moet 64 hex-tekens zijn');
  }
  return Buffer.from(hex, 'hex');
}

// tekst (string) -> hex-string voor Postgres
function versleutel(tekst, sleutelHex) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', sleutelUit(sleutelHex), iv);
  const versleuteld = Buffer.concat([cipher.update(String(tekst), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, versleuteld]).toString('hex');
}

// hex-string uit Postgres -> tekst. Geeft een fout als de sleutel niet klopt of de waarde is gewijzigd.
function ontsleutel(hex, sleutelHex) {
  const buf = Buffer.from(String(hex).replace(/^\\x/, ''), 'hex');
  if (buf.length < 29) throw new Error('versleutelde waarde is te kort');
  const iv = buf.subarray(0, 12);
  const tag = buf.subarray(12, 28);
  const data = buf.subarray(28);
  const decipher = crypto.createDecipheriv('aes-256-gcm', sleutelUit(sleutelHex), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(data), decipher.final()]).toString('utf8');
}

if (typeof module !== 'undefined') module.exports = { versleutel, ontsleutel };
