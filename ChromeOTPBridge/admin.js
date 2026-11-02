// Fixed test08/Калуга operations. The authenticated browser session and CSRF stay here.
(() => {
  const origin = 'https://test08-podval.int.indels.dev';
  const cityPath = '/podval/city/update?id=590';
  const states = ['enabled', 'disabled'];
  const failure = code => Object.assign(new Error(code), { code });
  async function run(task) {
    let saved = false, go = false, php = false, mutation = false;
    try {
      const age = Date.now() / 1000 - task?.created;
      if (task?.stand !== '08' || task?.city !== 590 || !['admin_read', 'admin_door', 'admin_cache'].includes(task.operation)) throw failure('invalid_request');
      if (!Number.isFinite(age) || age < 0 || age >= 5) throw failure('timeout');
      if (task.operation === 'admin_door' && (!states.includes(task.value) || !states.includes(task.expected))) throw failure('invalid_request');
      if (location.origin !== origin || location.pathname !== '/podval/city/update' || location.search !== '?id=590') throw failure('admin_tab_missing');
      const deadline = task.created * 1000 + 30000;
      async function request(path, method = 'GET', body, headers) {
        if (Date.now() >= deadline) throw failure('timeout');
        const response = await fetch(origin + path, {
          method, body, headers, credentials: 'same-origin', redirect: 'manual',
          signal: AbortSignal.timeout(Math.max(1, Math.min(8000, Math.floor(deadline - Date.now())))),
        });
        if (response.type === 'opaqueredirect' || response.status >= 300 && response.status < 400) throw failure('admin_auth_required');
        if (response.status === 401 || response.status === 403) throw failure('admin_auth_required');
        if (!response.ok) throw failure('admin_request_failed');
        const text = await response.text();
        if (/<input[^>]+type=["']password|name=["']LoginForm\[/i.test(text)) throw failure('admin_auth_required');
        return text;
      }
      function csrfHeader(text) {
        // Laravel's AJAX CSRF header is rendered by the page. Keep it inside this browser world.
        const token = text.match(/['"]X-CSRF-TOKEN['"]\s*:\s*['"]([A-Za-z0-9_=-]{20,2048})['"]/);
        if (!token) throw failure('admin_page_changed');
        return { 'X-CSRF-TOKEN': token[1], 'X-Requested-With': 'XMLHttpRequest' };
      }
      function parse(text) {
        const doc = new DOMParser().parseFromString(text, 'text/html');
        if (doc.querySelector('#City_name')?.value !== 'Калуга') throw failure('admin_page_changed');
        const type = [...(doc.querySelector('#orderCitySettingsTypes')?.options || [])].filter(o => o.textContent.trim() === 'Courier');
        if (type.length !== 1 || !/^[0-9]+$/.test(type[0].value)) throw failure('admin_page_changed');
        const block = doc.querySelector('#order-type-setting-block-' + type[0].value);
        const setting = block?.getAttribute('data-setting-id');
        const field = block?.querySelector('[data-name="door_to_door"]');
        const order = block?.querySelector('[name="OrderTypeCitySettings[order_type_city_id]"]');
        const csrf = block?.querySelector('[name="YII_CSRF_TOKEN"]');
        if (!/^[0-9]+$/.test(setting || '') || order?.value !== type[0].value || !states.includes(field?.value) || !csrf?.value) throw failure('admin_page_changed');
        // Only used to detect unexpected server changes; never returned or persisted.
        const other = [...block.querySelectorAll('[data-name]')].filter(e => e.getAttribute('data-name') !== 'door_to_door').map(e => [e.getAttribute('data-name'), e.value, e.type === 'checkbox' ? e.checked : null]);
        return { door: field.value, setting, order: order.value, csrf: csrf.value, other: JSON.stringify(other) };
      }
      const current = parse(await request(cityPath));
      if (task.operation === 'admin_read') return { ok: true, code: 'admin_loaded', door: current.door };
      if (task.operation === 'admin_door') {
        if (current.door !== task.expected) throw failure('admin_conflict');
        if (current.door !== task.value) {
          const body = new FormData();
          // The admin uses this same endpoint for partial pricing updates. Send only our field.
          body.append('data', JSON.stringify({ order_type_city_id: current.order, door_to_door: task.value }));
          body.append('YII_CSRF_TOKEN', current.csrf);
          mutation = true;
          const response = JSON.parse(await request('/podval/order2020/ordertypecitysettings/update?id=' + current.setting, 'POST', body));
          if (response?.status !== 200) throw failure('admin_save_failed');
          const check = parse(await request(cityPath));
          if (check.door !== task.value || check.other !== current.other) throw failure('admin_verify_failed');
        }
        saved = true;
        return { ok: true, code: 'admin_saved', door: task.value, saved, go: false, php: false };
      }
      // Same operations as the two admin utilities; no other cache endpoints are used.
      const goPage = await request('/podval/gocache/index');
      const goDoc = new DOMParser().parseFromString(goPage, 'text/html');
      if (!goDoc.querySelector('#cleargo') || !goDoc.querySelector('#reason')) throw failure('admin_page_changed');
      mutation = true;
      await request('/podval/gocache/cache', 'POST', new URLSearchParams({ reason: 'Жмякее · test08 · Калуга · сброс GO + PHP' }), csrfHeader(goPage));
      go = true;
      const phpText = await request('/podval/stat/clearcache');
      if (phpText.trim() !== 'Yii cache cleared') throw failure('admin_php_unverified');
      php = true;
      return { ok: true, code: 'admin_cache_done', saved, go, php };
    } catch (error) {
      // No HTML, server messages, CSRF, phone, cookies or credentials cross the bridge.
      return { ok: false, code: saved || go || php ? 'admin_partial' : mutation ? 'admin_unverified' : (error.code || 'admin_connection_error'), saved, go, php };
    }
  }
  globalThis.ZhmakeeAdmin = Object.freeze({ run });
})();
