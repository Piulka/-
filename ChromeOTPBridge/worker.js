const targetURL = 'https://redis-insight.dev.indels.tech/89b36460-e2f2-4245-a741-cdb7c13e7e1d/browser';
let port, active = false, reconnect;

async function execute(task) {
  if (active) return { ok: false, code: 'busy' };
  active = true;
  try {
    const tabs = await chrome.tabs.query({ url: targetURL + '*' });
    const tab = tabs.find(t => t.url === targetURL && !t.incognito);
    if (!tab) return { ok: false, code: 'tab_missing' };
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ['core.js'] });
    const results = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: request => globalThis.ZhmakeeOTP.run(request),
      args: [task],
    });
    return results[0]?.result || { ok: false, code: 'connection_error' };
  } catch { return { ok: false, code: 'connection_error' }; }
  finally { active = false; }
}

function connect() {
  if (port) return;
  clearTimeout(reconnect);
  port = chrome.runtime.connectNative('local.zhmakee.otp');
  const current = port;
  current.onMessage.addListener(async task => {
    if (typeof task?.id !== 'string' || !/^[a-f0-9-]{36}$/i.test(task.id)) return;
    const result = await execute(task);
    try { current.postMessage({ id: task.id, ...result }); } catch { /* Native app disconnected. */ }
  });
  current.onDisconnect.addListener(() => {
    void chrome.runtime.lastError; // Consume Chrome's generic error without recording it.
    if (port === current) port = null;
    reconnect = setTimeout(connect, 3000);
  });
}
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.action.onClicked.addListener(connect);
connect();
