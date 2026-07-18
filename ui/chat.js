// NukeFire Chat — panel UI logic.
//
// Receives :post("line", { tab, text, ts }) and :post("settings", …)
// messages from the Lua side via Mallard's panel SDK. Maintains per-tab
// FIFO ring buffers; renders only the active tab.
//
// Tabs: all, tell, auction, gossip, group — fixed, unlike Discworld Chat's
// dynamic pin+catch-all model, since NukeFire's channel set here is small
// and known ahead of time.

const BUFFER_MAX = 1000;
const FIXED_TABS = ["all", "tell", "auction", "gossip", "group"];
const TAB_LABELS = { all: "All", tell: "Tell", auction: "Auction", gossip: "Gossip", group: "Group" };

const buffers = {};
let activeTab = "all";
let settings = { sources: { tell: {}, auction: {}, gossip: {}, group: {} } };
let view = "chat"; // "chat" or "settings"

const tabsEl = document.getElementById("tabs");
const scrollback = document.getElementById("scrollback");
const settingsEl = document.getElementById("settings");
const sourcesEl = document.getElementById("sources");
const overflowPopover = document.getElementById("overflow-popover");

function pad(n) { return n < 10 ? "0" + n : "" + n; }
function formatTime(unix) {
  const d = new Date(unix * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

// URL autolinking — mirrors src-tauri/src/url_autolink.rs in Mallard proper
// so links in plugin content behave the same as links in the main output:
// the same shapes match (http(s)://, www., mailto:, bare host/path), the
// same trailing-punctuation trim runs, and the same "bare host with no path"
// guard prevents false positives on file names like `connection.lua`.
const URL_RE = new RegExp(
  [
    "https?://[^\\s<>\"'`]+",
    "www\\.[^\\s<>\"'`]+",
    "mailto:[^\\s<>\"'`]+",
    "[A-Za-z0-9][A-Za-z0-9-]*(?:\\.[A-Za-z0-9][A-Za-z0-9-]+)+/[^\\s<>\"'`]+",
  ].join("|"),
  "g",
);

function trimTrailingPunctuation(matched) {
  let end = matched.length;
  while (end > 0) {
    const c = matched[end - 1];
    if (c === "." || c === "," || c === ";" || c === ":" || c === "!" || c === "?") {
      end -= 1;
      continue;
    }
    const pair = c === ")" ? ["(", ")"]
      : c === "]" ? ["[", "]"]
      : c === "}" ? ["{", "}"]
      : c === ">" ? ["<", ">"]
      : null;
    if (!pair) break;
    const prefix = matched.slice(0, end);
    let opens = 0, closes = 0;
    for (const ch of prefix) { if (ch === pair[0]) opens++; else if (ch === pair[1]) closes++; }
    if (closes > opens) end -= 1; else break;
  }
  return matched.slice(0, end);
}

function linkTarget(matched) {
  if (matched.startsWith("http://") || matched.startsWith("https://") || matched.startsWith("mailto:")) {
    return matched;
  }
  return "https://" + matched;
}

// Build a document fragment from `text`, with detected URLs as anchors that
// route clicks through `panel.openUrl`. Anchors carry `href` so right-click
// "Copy link" works and middle-clickability surfaces; the click handler
// preventDefaults to keep the iframe from navigating away from itself.
function renderTextWithLinks(text) {
  const frag = document.createDocumentFragment();
  let cursor = 0;
  URL_RE.lastIndex = 0;
  let m;
  while ((m = URL_RE.exec(text)) !== null) {
    const matched = trimTrailingPunctuation(m[0]);
    if (!matched) continue;
    const start = m.index;
    const end = start + matched.length;
    URL_RE.lastIndex = end;
    if (start > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, start)));
    const a = document.createElement("a");
    a.className = "url";
    a.textContent = matched;
    a.href = linkTarget(matched);
    a.rel = "noopener noreferrer";
    a.addEventListener("click", onUrlClick);
    a.addEventListener("auxclick", onUrlClick);
    frag.appendChild(a);
    cursor = end;
  }
  if (cursor === 0) {
    frag.appendChild(document.createTextNode(text));
  } else if (cursor < text.length) {
    frag.appendChild(document.createTextNode(text.slice(cursor)));
  }
  return frag;
}

function onUrlClick(e) {
  // Left and middle clicks; ignore modifier-clicks so the user can still
  // select-and-drag a URL into the system clipboard via Cmd+drag etc.
  if (e.type === "auxclick" && e.button !== 1) return;
  if (e.button !== undefined && e.button !== 0 && e.button !== 1) return;
  e.preventDefault();
  const url = e.currentTarget.href;
  if (typeof panel.openUrl === "function") panel.openUrl(url);
}

function computeTabOrder() {
  return FIXED_TABS;
}

function ensureBuffer(tabId) {
  if (!buffers[tabId]) buffers[tabId] = [];
  return buffers[tabId];
}

function tabLabel(tabId) {
  return TAB_LABELS[tabId] || tabId;
}

function renderLine({ tab, text, ts }) {
  const el = document.createElement("div");
  el.className = "line";
  const tag = `[${tabLabel(tab)}]`;
  el.innerHTML =
    `<span class="ts">${formatTime(ts)}</span>` +
    `<span class="tag">${tag}</span>`;
  el.appendChild(renderTextWithLinks(text));
  return el;
}

function isPinnedToBottom() {
  return scrollback.scrollHeight - scrollback.scrollTop - scrollback.clientHeight < 16;
}

// Every line goes to "all" and to its own tab — no catch-all/pin fan-out
// since tabs are fixed 1:1 with channels here (unlike Discworld's
// pinned-channel-into-Channels-tab fan-out).
function bufferPush(entry) {
  // Pre-mark seen if the entry is going to be visible right now, so the
  // tab the user is on never lights up its own dot for content it just
  // displayed.
  if (view === "chat" && entryBelongsInTab(entry, activeTab)) {
    entry.seen = true;
  }
  const targets = new Set(["all", entry.tab]);
  for (const t of targets) {
    const buf = ensureBuffer(t);
    buf.push(entry);
    if (buf.length > BUFFER_MAX) buf.shift();
  }
  return targets;
}

// Tab ids currently collapsed into the overflow "•••" button. Set by
// collapseOverflow; consulted by refreshUnreadDots so the overflow
// trigger lights up when a hidden tab has unread.
let overflowHiddenIds = [];

function isTabUnread(tabId) {
  const buf = buffers[tabId];
  if (!buf) return false;
  for (let i = 0; i < buf.length; i++) {
    if (!buf[i].seen) return true;
  }
  return false;
}

// Mark every entry in `tabId`'s buffer as seen. Entries are shared
// across buffers, so this clears the contribution of those entries in
// every tab that also holds them.
function markBufferSeen(tabId) {
  const buf = buffers[tabId];
  if (!buf) return;
  for (let i = 0; i < buf.length; i++) buf[i].seen = true;
}

function refreshUnreadDots() {
  const order = computeTabOrder();
  for (const id of order) {
    const flag = isTabUnread(id);
    const sel = `.tab[data-tab="${CSS.escape(id)}"]`;
    for (const btn of tabsEl.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
    for (const btn of overflowPopover.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
  }
  const overflowBtn = tabsEl.querySelector(".tab.overflow");
  if (overflowBtn) {
    overflowBtn.classList.toggle("has-unread", overflowHiddenIds.some(id => isTabUnread(id)));
  }
}

function entryBelongsInTab(entry, tab) {
  if (tab === "all") return true;
  return tab === entry.tab;
}

function appendToActive(entry) {
  if (view !== "chat") return;
  if (!entryBelongsInTab(entry, activeTab)) return;
  const wasPinned = isPinnedToBottom();
  scrollback.appendChild(renderLine(entry));
  while (scrollback.childElementCount > BUFFER_MAX) {
    scrollback.removeChild(scrollback.firstElementChild);
  }
  if (wasPinned) scrollback.scrollTop = scrollback.scrollHeight;
}

function rerenderActive() {
  scrollback.replaceChildren();
  const buf = buffers[activeTab] || [];
  for (const e of buf) scrollback.appendChild(renderLine(e));
  scrollback.scrollTop = scrollback.scrollHeight;
}

let activeTabRestored = false;

function switchTab(t) {
  const order = computeTabOrder();
  if (!order.includes(t)) return;
  activeTab = t;
  view = "chat";
  scrollback.hidden = false;
  settingsEl.hidden = true;
  markBufferSeen(t);
  renderTabs();
  rerenderActive();
  panel.post("active_tab", { tab: t });
  // Any explicit tab choice (including the restore call below) closes
  // the one-shot restore window so a late `settings` broadcast can't
  // yank the user back.
  activeTabRestored = true;
}

function openSettings() {
  view = "settings";
  scrollback.hidden = true;
  settingsEl.hidden = false;
  renderTabs();
  renderSettings();
  kickHandshake();
}

function makeTabButton(tabId, { overflow = false } = {}) {
  const btn = document.createElement("button");
  btn.className = "tab"
    + (tabId === activeTab && view === "chat" ? " active" : "")
    + (isTabUnread(tabId) ? " has-unread" : "");
  btn.dataset.tab = tabId;
  btn.role = "tab";
  btn.textContent = tabLabel(tabId);
  btn.addEventListener("click", () => {
    switchTab(tabId);
    if (overflow) hideOverflowPopover();
  });
  return btn;
}

const GEAR_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' +
  '<path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54A.48.48 0 0 0 13.92 2h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.47c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z"/>' +
  '</svg>';

function makeIconButton(content, className, onClick, { svg = false, title = "" } = {}) {
  const btn = document.createElement("button");
  btn.className = `tab ${className}` + (className === "gear" && view === "settings" ? " active" : "");
  if (svg) btn.innerHTML = content; else btn.textContent = content;
  if (title) btn.title = title;
  btn.addEventListener("click", onClick);
  return btn;
}

function hideOverflowPopover() {
  overflowPopover.hidden = true;
  overflowPopover.replaceChildren();
}

function showOverflowPopover(tabIds, anchorBtn) {
  overflowPopover.replaceChildren();
  for (const id of tabIds) {
    overflowPopover.appendChild(makeTabButton(id, { overflow: true }));
  }
  overflowPopover.hidden = false;
  const r = anchorBtn.getBoundingClientRect();
  overflowPopover.style.left = `${r.left}px`;
  overflowPopover.style.top = `${r.bottom}px`;
}

function renderTabs() {
  tabsEl.replaceChildren();
  const order = computeTabOrder();
  const gear = makeIconButton(GEAR_SVG, "gear", () => {
    if (view === "settings") switchTab(activeTab); else openSettings();
  }, { svg: true, title: "Settings" });

  // First-pass render — everything visible. Then measure and collapse.
  for (const id of order) tabsEl.appendChild(makeTabButton(id));
  tabsEl.appendChild(gear);

  requestAnimationFrame(() => collapseOverflow(order, gear));
}

function collapseOverflow(order, gear) {
  hideOverflowPopover();
  overflowHiddenIds = [];
  const barWidth = tabsEl.clientWidth;
  const gearWidth = gear.offsetWidth;
  const childButtons = Array.from(tabsEl.querySelectorAll(".tab:not(.gear):not(.overflow)"));

  let used = gearWidth;
  let overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) return;

  // Reserve space for the overflow button itself.
  const overflowBtn = makeIconButton("•••", "overflow", () => {
    const hiddenIds = order.slice(overflowStart);
    showOverflowPopover(hiddenIds, overflowBtn);
  });
  // Re-measure with overflow button width factored in: walk back until fits.
  // Insert temporarily to measure.
  tabsEl.insertBefore(overflowBtn, gear);
  const overflowWidth = overflowBtn.offsetWidth;

  // Recompute the cutoff with overflowWidth reserved.
  used = gearWidth + overflowWidth;
  overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) {
    overflowBtn.remove();
    return;
  }

  for (let i = overflowStart; i < childButtons.length; i++) {
    childButtons[i].remove();
  }
  // Rewire the overflow handler with the final hidden list.
  const hiddenIds = order.slice(overflowStart);
  overflowHiddenIds = hiddenIds;
  overflowBtn.onclick = () => showOverflowPopover(hiddenIds, overflowBtn);
  // Now that the overflow button exists, sync its dot — refreshUnreadDots
  // queries `.tab.overflow` so this couldn't run during makeTabButton.
  refreshUnreadDots();
}

// ---------------------------------------------------------------------
// Settings view rendering
// ---------------------------------------------------------------------

function sendUpdate(delta) {
  panel.post("settings_update", delta);
}

function renderSourceRow(label, key) {
  const row = document.createElement("div");
  row.className = "settings-row source-row";
  const name = document.createElement("span");
  name.className = "settings-name";
  name.textContent = label;
  row.appendChild(name);

  function sourceToggle(text, field) {
    const lab = document.createElement("label");
    lab.className = "settings-toggle";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!(settings.sources[key] && settings.sources[key][field]);
    cb.addEventListener("change", () => {
      sendUpdate({ source: { [key]: { [field]: cb.checked } } });
    });
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(" " + text));
    return lab;
  }

  row.appendChild(sourceToggle("gag from main", "gag_main"));
  row.appendChild(sourceToggle("sound", "sound"));
  row.appendChild(sourceToggle("notify", "notify"));
  return row;
}

function renderSettings() {
  sourcesEl.replaceChildren();
  sourcesEl.appendChild(renderSourceRow("Tell", "tell"));
  sourcesEl.appendChild(renderSourceRow("Auction", "auction"));
  sourcesEl.appendChild(renderSourceRow("Gossip", "gossip"));
  sourcesEl.appendChild(renderSourceRow("Group", "group"));
}

// ---------------------------------------------------------------------
// Panel SDK wiring
// ---------------------------------------------------------------------

panel.on("line", (payload) => {
  bufferPush(payload);
  appendToActive(payload);
  refreshUnreadDots();
});

let settingsReceived = false;
panel.on("settings", (payload) => {
  settingsReceived = true;
  if (payload && typeof payload === "object") {
    settings.sources = payload.sources || settings.sources;
    // Restore the persisted active tab once per iframe lifetime —
    // subsequent settings broadcasts (e.g. after a settings_update)
    // must not yank the user back if they've since clicked elsewhere.
    if (!activeTabRestored) {
      activeTabRestored = true;
      if (typeof payload.active_tab === "string" && payload.active_tab !== activeTab) {
        switchTab(payload.active_tab);
      }
    }
  }
  renderTabs();
  if (view === "settings") renderSettings();
});

// Keyboard tab navigation. main.lua's chat_tab_<n> commands (bound by the
// "chat-tab-nav" keymap layer) post these. We resolve the 1-based strip
// position against the fixed tab order and reuse switchTab(), so
// seen-marking, re-render, and active_tab persistence all happen exactly
// as on a click. Out-of-range = no-op.
panel.on("goto_index", (payload) => {
  const index = payload && payload.index;
  const id = tabIdForIndex(computeTabOrder(), index);
  if (id) switchTab(id);
});

window.addEventListener("resize", () => renderTabs());

document.addEventListener("click", (e) => {
  if (overflowPopover.hidden) return;
  if (overflowPopover.contains(e.target)) return;
  if (e.target.classList && e.target.classList.contains("overflow")) return;
  hideOverflowPopover();
});

renderTabs();

// Handshake with retry: Mallard's panel dispatcher drops messages when
// no Lua listener is yet registered, so our first "ready" can race the
// plugin's top-level code on a Mallard restart. Lua dedupes history
// replay by `session` so retries don't double-replay but a fresh iframe
// mount always gets history.
const READY_RETRY_MS = 500;
const READY_MAX_ATTEMPTS = 120; // ~60s total
const SESSION_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
let readyAttempts = 0;
let readyTimer = null;
function sendReady() {
  readyTimer = null;
  if (settingsReceived) return;
  if (readyAttempts >= READY_MAX_ATTEMPTS) return;
  panel.post("ready", { session: SESSION_ID });
  readyAttempts += 1;
  readyTimer = setTimeout(sendReady, READY_RETRY_MS);
}
function kickHandshake() {
  if (settingsReceived) return;
  if (readyTimer) { clearTimeout(readyTimer); readyTimer = null; }
  readyAttempts = 0;
  sendReady();
}

kickHandshake();
