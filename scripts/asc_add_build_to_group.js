// Poll App Store Connect until a build finishes processing, then add it to the
// internal TestFlight group. Run AFTER `xcrun altool --upload-app` succeeds.
//
// Usage:  node scripts/asc_add_build_to_group.js <BUILD_NUMBER>
//   e.g.  node scripts/asc_add_build_to_group.js 40
//
// Needs the ASC API private key at ~/.appstoreconnect/private_keys/AuthKey_4N8UF433DF.p8
const crypto = require('crypto'), fs = require('fs'), https = require('https');
const BUILD = process.argv[2];
if (!BUILD) { console.error('usage: node asc_add_build_to_group.js <BUILD_NUMBER>'); process.exit(1); }
const KEY_ID = '4N8UF433DF', ISSUER = '49354180-aef7-4964-bba8-b105589d9f55';
const pk = fs.readFileSync(process.env.HOME + '/.appstoreconnect/private_keys/AuthKey_4N8UF433DF.p8', 'utf8');
const b64 = s => Buffer.from(s).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const si = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })) + '.' +
             b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }));
  return si + '.' + crypto.sign('SHA256', Buffer.from(si), { key: pk, dsaEncoding: 'ieee-p1363' })
    .toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
function req(method, path, body) {
  return new Promise((res, rej) => {
    const data = body ? JSON.stringify(body) : null;
    const r = https.request('https://api.appstoreconnect.apple.com' + path, {
      method, headers: { Authorization: 'Bearer ' + jwt(), 'Content-Type': 'application/json',
        ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}) }
    }, rs => { let d = ''; rs.on('data', c => d += c); rs.on('end', () => res({ status: rs.statusCode, json: d ? JSON.parse(d) : {} })); });
    r.on('error', rej); if (data) r.write(data); r.end();
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const app = (await req('GET', '/v1/apps?filter[bundleId]=com.toskaapp.toska')).json.data[0].id;
  const GROUP = 'e0075c3b-b6b0-4c74-881e-9bff5a60bcb3'; // "Internal (me)"
  for (let i = 0; i < 40; i++) {
    const r = await req('GET', '/v1/builds?filter[app]=' + app + '&filter[version]=' + BUILD + '&fields[builds]=version,processingState');
    const b = r.json.data && r.json.data[0];
    if (b && b.attributes.processingState === 'VALID') {
      console.log('build ' + BUILD + ' PROCESSED (VALID), id=' + b.id);
      const add = await req('POST', '/v1/betaGroups/' + GROUP + '/relationships/builds', { data: [{ type: 'builds', id: b.id }] });
      console.log('add to internal group: status ' + add.status + (add.status >= 300 ? ' ' + JSON.stringify(add.json.errors || add.json) : ' OK'));
      return;
    }
    console.log('[' + (i + 1) + '] build ' + BUILD + ' state=' + (b ? b.attributes.processingState : 'not-yet-a-build') + ' — waiting 60s');
    await sleep(60000);
  }
  console.log('still processing after ~40 min');
})().catch(e => { console.error('err', e.message); process.exit(1); });
