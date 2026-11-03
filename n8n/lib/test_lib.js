// bbss-systeem / n8n / lib / test_lib.js
// Test van versleutel.js en twilio_handtekening.js.
// Gebruik:  node n8n/lib/test_lib.js            (alleen eigen tests)
//           TWILIO_LIB=<pad naar node_modules/twilio> node n8n/lib/test_lib.js
//           (vergelijkt ook met de officiële validateRequest van de Twilio-bibliotheek)

const assert = require('assert');
const crypto = require('crypto');
const { versleutel, ontsleutel } = require('./versleutel');
const { berekenHandtekening, handtekeningKlopt } = require('./twilio_handtekening');

let geslaagd = 0;
function test(naam, fn) { fn(); geslaagd++; console.log('OK  ', naam); }

// ---- versleutel.js
const sleutel = crypto.randomBytes(32).toString('hex');
const token = 'a'.repeat(31) + 'b';

test('versleutelen en ontsleutelen geeft de oorspronkelijke waarde', () => {
  assert.strictEqual(ontsleutel(versleutel(token, sleutel), sleutel), token);
});
test('formaat: 12 bytes IV + 16 bytes tag + tekst', () => {
  const buf = Buffer.from(versleutel(token, sleutel), 'hex');
  assert.strictEqual(buf.length, 12 + 16 + Buffer.byteLength(token));
});
test('twee keer versleutelen geeft een andere waarde (nieuwe IV)', () => {
  assert.notStrictEqual(versleutel(token, sleutel), versleutel(token, sleutel));
});
test('Postgres-hexvorm met \\x ervoor wordt ook gelezen', () => {
  assert.strictEqual(ontsleutel('\\x' + versleutel(token, sleutel), sleutel), token);
});
test('verkeerde sleutel geeft een fout', () => {
  const ander = crypto.randomBytes(32).toString('hex');
  assert.throws(() => ontsleutel(versleutel(token, sleutel), ander));
});
test('gewijzigde waarde geeft een fout', () => {
  const hex = versleutel(token, sleutel);
  const kapot = hex.slice(0, -2) + (hex.slice(-2) === '00' ? '01' : '00');
  assert.throws(() => ontsleutel(kapot, sleutel));
});
test('sleutel van verkeerde lengte wordt geweigerd', () => {
  assert.throws(() => versleutel(token, 'abc'));
});

// ---- twilio_handtekening.js
const url = 'https://n8n.voorbeeld.nl/webhook/voice?klant=test';
const params = { CallSid: 'CA1234567890ABCDE', Caller: '+31612345678', Digits: '1234',
                 From: '+31612345678', To: '+3197010000001', AccountSid: 'AC' + 'a'.repeat(32) };
const authToken = '12345';

test('een juiste handtekening klopt', () => {
  const h = berekenHandtekening(url, params, authToken);
  assert.ok(handtekeningKlopt(url, params, authToken, h));
});
test('een ander token klopt niet', () => {
  const h = berekenHandtekening(url, params, 'anders');
  assert.ok(!handtekeningKlopt(url, params, authToken, h));
});
test('een gewijzigde parameter klopt niet', () => {
  const h = berekenHandtekening(url, params, authToken);
  assert.ok(!handtekeningKlopt(url, { ...params, From: '+31600000000' }, authToken, h));
});
test('een URL zonder querystring klopt niet', () => {
  const h = berekenHandtekening(url, params, authToken);
  assert.ok(!handtekeningKlopt('https://n8n.voorbeeld.nl/webhook/voice', params, authToken, h));
});
test('een lege of te korte header geeft false, geen fout', () => {
  assert.strictEqual(handtekeningKlopt(url, params, authToken, ''), false);
  assert.strictEqual(handtekeningKlopt(url, params, authToken, 'abc'), false);
  assert.strictEqual(handtekeningKlopt(url, params, authToken, undefined), false);
});

// ---- Vergelijking met de officiële Twilio-bibliotheek (als die beschikbaar is)
if (process.env.TWILIO_LIB) {
  const twilio = require(process.env.TWILIO_LIB);
  const gevallen = [
    [url, params],
    ['https://n8n.voorbeeld.nl/webhook/oproep-klaar', { CallStatus: 'completed', CallDuration: '37', Called: '+3197010000001' }],
    ['https://n8n.voorbeeld.nl/webhook/sms-in', { Body: 'Stop! Graag niet meer — dank je', From: '+31612345678', NumSegments: '1' }],
  ];
  gevallen.forEach(([u, p], i) => {
    test(`gelijk aan twilio.validateRequest (geval ${i + 1})`, () => {
      const onze = berekenHandtekening(u, p, authToken);
      assert.ok(twilio.validateRequest(authToken, onze, u, p), 'Twilio keurt onze handtekening af');
      const fout = berekenHandtekening(u, p, 'anders');
      assert.ok(!twilio.validateRequest(authToken, fout, u, p), 'Twilio keurt een foute handtekening goed');
    });
  });
} else {
  console.log('(overgeslagen: vergelijking met de Twilio-bibliotheek; zet TWILIO_LIB)');
}

console.log(`\n${geslaagd} tests geslaagd`);
