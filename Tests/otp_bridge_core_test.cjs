const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../ChromeOTPBridge/core.js'), 'utf8');
const phone = ['258', '12345678'].join('');
const keys = [`auth_step_${phone}${phone}`, `auth_rdb_count:${phone}`, `rate:sms_cd_:${phone}`];
const id = '89b36460-e2f2-4245-a741-cdb7c13e7e1d';
const base = 'https://redis-insight.dev.indels.tech';

async function scenario(operation, options = {}) {
  const calls = [];
  let present = options.present ?? keys.slice(), deleted = false;
  const context = vm.createContext({
    location: options.location || { origin: base, pathname: `/${id}/browser` },
    AbortSignal: { timeout: () => undefined },
    fetch: async (url, request) => {
      const body = request.body && JSON.parse(request.body);
      calls.push({ url, method: request.method, body });
      assert.equal(request.credentials, 'same-origin');
      assert.equal(request.redirect, 'error');
      assert.ok(url.startsWith(`${base}/api/databases/${id}`));
      let status = options.auth ? 401 : 200, value;
      if (request.method === 'GET') value = { id, name: options.database || 'test08 — indelssite-redis' };
      else if (request.method === 'POST') {
        assert.deepEqual(body.keys, keys);
        assert.equal(body.includeSize, false);
        if (deleted && options.verifyFails) throw Error('network');
        value = present.map(name => ({ name, type: 'string', ttl: 400 }));
      } else if (request.method === 'DELETE') {
        assert.equal(body.keyNames.length, 1);
        assert.ok(present.includes(body.keyNames[0]));
        assert.ok(body.keyNames.every(k => keys.includes(k) && !k.includes('*')));
        deleted = true;
        value = { affected: 1 };
        present = present.filter(key => key !== body.keyNames[0]);
        if (options.expired) status = 404;
      } else assert.fail('Unexpected mutation');
      return { status, ok: status === 200, json: async () => value };
    },
  });
  vm.runInContext(source, context);
  const result = await context.ZhmakeeOTP.run({ operation, phone: options.phone ?? phone, stand: options.stand || '08', created: Date.now() / 1000 - (options.stale ? 10 : 0) });
  assert.ok(!JSON.stringify(result).includes(phone));
  assert.ok(!JSON.stringify(result).includes('auth_step'));
  return { result, calls };
}

module.exports = (async () => {
  let value = await scenario('ping');
  assert.equal(value.result.ok, true); assert.equal(value.calls.length, 1);
  value = await scenario('inspect');
  assert.equal(value.result.found, 3); assert.equal(value.calls.length, 2);
  value = await scenario('reset', { present: keys.slice(1) });
  assert.equal(value.result.ok, true); assert.equal(value.result.deleted, 2); assert.equal(value.result.remaining, 0);
  assert.deepEqual(value.calls.map(x => x.method), ['GET', 'POST', 'DELETE', 'DELETE', 'POST']);
  value = await scenario('reset', { present: [] });
  assert.equal(value.result.ok, true); assert.equal(value.calls.length, 2);
  value = await scenario('reset', { present: ['auth_rdb_count:another-account'] });
  assert.equal(value.result.code, 'unexpected_keys'); assert.equal(value.calls.length, 2);
  value = await scenario('reset', { database: 'test09 — indelssite-redis' });
  assert.equal(value.result.code, 'wrong_database'); assert.equal(value.calls.length, 1);
  value = await scenario('reset', { auth: true });
  assert.equal(value.result.code, 'auth_required'); assert.equal(value.calls.length, 1);
  for (const options of [{ phone: '*'}, { phone: phone + ';DEL *' }, { phone: phone + '\n' }, { stale: true }, { stand: 'stage' }, { stand: '09' }, { location: { origin: 'https://example.com', pathname: `/${id}/browser` } }]) {
    value = await scenario('reset', options);
    assert.equal(value.result.ok, false); assert.equal(value.calls.length, 0);
  }
  value = await scenario('reset', { expired: true });
  assert.equal(value.result.ok, true); assert.equal(value.result.deleted, 0);
  value = await scenario('reset', { verifyFails: true, present: keys.slice(0, 1) });
  assert.equal(value.result.ok, false); assert.equal(value.result.code, 'reset_unverified');
  assert.equal(value.calls.filter(x => x.method === 'DELETE').length, 1);
  console.log('OTP browser scope, exact keys, read-only checks and verified deletion: passed');
})();
