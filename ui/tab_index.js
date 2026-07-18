// Pure helper: map a 1-based strip position to a tab id.
// Shared by chat.js (loaded as a browser global) and tests (node require).
// The strip order is `["all", "tell", "auction", "gossip"]` — callers pass
// FIXED_TABS from chat.js.
function tabIdForIndex(order, index) {
  if (!Array.isArray(order)) return undefined;
  if (typeof index !== "number" || index < 1 || index > order.length) {
    return undefined;
  }
  return order[index - 1];
}

// Dual export: in the browser `module` is undefined and `tabIdForIndex`
// stays a global; under node the test can require() it.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { tabIdForIndex };
}
