// bbss-systeem / n8n / lib / twilio_handtekening.js
// Nareken van X-Twilio-Signature (ontwerp: "Webhooks van Twilio"). Gekopieerd in de Code-node van S01.
//
//  1. de volledige publieke URL zoals Twilio die aanriep (WEBHOOK_URL + pad + querystring),
//     met https en zonder poort;
//  2. daarachter alle POST-parameters, gesorteerd op naam, als naam+waarde zonder scheidingsteken;
//  3. HMAC-SHA1 met het auth-token van het (sub)account, als base64;
//  4. vergelijken met de header: eerst de lengte, dan in constante tijd.

const crypto = require('crypto');

function berekenHandtekening(url, params, authToken) {
  const namen = Object.keys(params || {}).sort();
  let tekst = url;
  for (const naam of namen) {
    const waarde = params[naam];
    // Twilio stuurt bij een herhaalde parameter elke waarde mee, in volgorde.
    const waarden = Array.isArray(waarde) ? [...waarde].sort() : [waarde];
    for (const w of waarden) tekst += naam + (w === undefined || w === null ? '' : String(w));
  }
  return crypto.createHmac('sha1', authToken).update(Buffer.from(tekst, 'utf-8')).digest('base64');
}

function handtekeningKlopt(url, params, authToken, header) {
  if (typeof header !== 'string' || header.length === 0) return false;
  const verwacht = Buffer.from(berekenHandtekening(url, params, authToken));
  const gekregen = Buffer.from(header);
  if (verwacht.length !== gekregen.length) return false;   // timingSafeEqual eist gelijke lengte
  return crypto.timingSafeEqual(verwacht, gekregen);
}

if (typeof module !== 'undefined') module.exports = { berekenHandtekening, handtekeningKlopt };
