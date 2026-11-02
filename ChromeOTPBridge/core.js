// Runs only in this extension's isolated world on RedisInsight. No credential APIs.
(() => {
  const origin = 'https://redis-insight.dev.indels.tech';
  const database = '89b36460-e2f2-4245-a741-cdb7c13e7e1d';
  const validPhone = value => typeof value === 'string' && value.length === 11 && /^258[0-9]{8}$/.test(value);
  const names = phone => [`auth_step_${phone}${phone}`, `auth_rdb_count:${phone}`, `rate:sms_cd_:${phone}`];
  const failure = code => Object.assign(new Error(code), { code });

  async function run(task) {
    let mutationSent = false;
    try {
      if (!task || task.stand !== '08' || !['ping', 'inspect', 'reset'].includes(task.operation)) throw failure('invalid_request');
      const age = Date.now() / 1000 - task.created;
      if (!Number.isFinite(age) || age < 0 || age >= 5) throw failure('timeout');
      const deadline = task.created * 1000 + 30000;
      if (task.operation !== 'ping' && !validPhone(task.phone)) throw failure('invalid_phone');
      if (location.origin !== origin || location.pathname !== `/${database}/browser`) throw failure('wrong_tab');
      const base = `${origin}/api/databases/${database}`;
      async function api(path, method = 'GET', body) {
        if (Date.now() >= deadline) throw failure('timeout');
        const response = await fetch(base + path, {
          method, credentials: 'same-origin', redirect: 'error',
          headers: { 'Content-Type': 'application/json' },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
          signal: AbortSignal.timeout(Math.max(1, Math.min(8000, Math.floor(deadline - Date.now())))),
        });
        if (response.status === 401 || response.status === 403) throw failure('auth_required');
        if (method === 'DELETE' && response.status === 404) return { affected: 0 }; // Keys may expire concurrently.
        if (!response.ok) throw failure(response.status === 404 ? 'api_not_found' : 'api_error');
        try { return await response.json(); } catch { throw failure('unexpected_response'); }
      }
      const info = await api('');
      // A copied/renamed connection must not silently redirect a reset to another stand.
      if (info.id !== database || typeof info.name !== 'string' || !/^test08\s*[—–-]\s*indelssite-redis$/i.test(info.name)) throw failure('wrong_database');
      if (task.operation === 'ping') return { ok: true, code: 'connected' };
      const allowed = new Set(names(task.phone));
      async function existing() {
        const rows = await api('/keys/get-metadata?encoding=utf8', 'POST', {
          keys: [...allowed], includeSize: false, includeTTL: true,
        });
        if (!Array.isArray(rows)) throw failure('unexpected_response');
        const found = new Set();
        for (const row of rows) {
          const name = typeof row?.name === 'string' ? row.name :
            row?.name?.type === 'Buffer' && Array.isArray(row.name.data) ?
              String.fromCharCode(...row.name.data) : null;
          if (!name || !allowed.has(name)) throw failure('unexpected_keys');
          if (row.type && row.type !== 'none' && row.ttl !== -2) found.add(name);
        }
        return [...found];
      }
      const found = await existing();
      if (task.operation === 'inspect' || found.length === 0) return { ok: true, code: 'checked', found: found.length, deleted: 0, remaining: found.length };
      // Exactly the keys found above, never a wildcard or a command supplied by the caller.
      mutationSent = true;
      // Redis Cluster rejects a DEL spanning different hash slots. Delete each exact key once.
      let deleted = 0;
      for (const key of found) {
        const result = await api('/keys?encoding=utf8', 'DELETE', { keyNames: [key] });
        if (!Number.isInteger(result.affected) || result.affected < 0 || result.affected > 1) throw failure('unexpected_response');
        deleted += result.affected;
      }
      const remaining = await existing();
      return { ok: remaining.length === 0, code: remaining.length ? 'keys_remain' : 'reset', found: found.length, deleted, remaining: remaining.length };
    } catch (error) {
      // No bodies, values, key names, credentials, URLs or phone numbers leave this world.
      return { ok: false, code: mutationSent ? 'reset_unverified' : (error.code || 'connection_error') };
    }
  }
  globalThis.ZhmakeeOTP = Object.freeze({ run });
})();
