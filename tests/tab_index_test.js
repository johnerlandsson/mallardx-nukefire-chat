// Pure tests for tabIdForIndex. Run with: node tests/tab_index_test.js
// tab_index.js has no DOM/host dependencies, so plain node is enough.
const { tabIdForIndex } = require("../ui/tab_index.js");

let failures = 0;
function check(label, got, want) {
  if (got === want) {
    console.log("ok   " + label);
  } else {
    failures++;
    console.log("FAIL " + label + " — got " + String(got) + ", want " + String(want));
  }
}

const order = ["all", "tell", "auction", "gossip", "group"];
check("index 1 -> all",              tabIdForIndex(order, 1), "all");
check("index 2 -> tell",             tabIdForIndex(order, 2), "tell");
check("index 3 -> auction",          tabIdForIndex(order, 3), "auction");
check("index 4 -> gossip",           tabIdForIndex(order, 4), "gossip");
check("index 5 (last) -> group",     tabIdForIndex(order, 5), "group");
check("last via order.length",       tabIdForIndex(order, order.length), "group");
check("index 6 (past end) -> undef", tabIdForIndex(order, 6), undefined);
check("index 0 -> undef",            tabIdForIndex(order, 0), undefined);
check("non-number -> undef",         tabIdForIndex(order, undefined), undefined);
check("non-array -> undef",          tabIdForIndex(null, 1), undefined);

if (failures > 0) {
  console.log("\n" + failures + " failure(s)");
  process.exit(1);
}
console.log("\nall passed");
