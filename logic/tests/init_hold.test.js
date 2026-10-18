"use strict";

const assert = require("assert");
const { initHoldDecision, initHoldMiddleware } = require("../init_hold.js");

function run(name, fn) {
  try {
    fn();
    console.log("ok", name);
  } catch (err) {
    console.error("FAIL", name);
    console.error(err);
    process.exitCode = 1;
  }
}

run("explicit hold=0 always forwards", () => {
  assert.strictEqual(
    initHoldDecision({ hold: "0", running: true, failed: true }),
    null
  );
});

run("running lock holds without GATE_INIT_HOLD", () => {
  const d = initHoldDecision({ hold: undefined, running: true, failed: false });
  assert.strictEqual(d.status, 503);
  assert.strictEqual(d.error, "init_pending");
});

run("failed wins over running", () => {
  const d = initHoldDecision({ hold: undefined, running: true, failed: true });
  assert.strictEqual(d.error, "init_failed");
});

run("ready when no locks", () => {
  assert.strictEqual(
    initHoldDecision({ hold: undefined, running: false, failed: false }),
    null
  );
});

run("middleware 503 with Retry-After", () => {
  const fs = { existsSync: (p) => String(p).endsWith(".init-running") };
  const mw = initHoldMiddleware({
    hold: undefined,
    fs,
    runningPaths: ["/data/.init-running"],
    failedPaths: ["/data/.init-failed"],
    log() {},
  });
  let status = 0;
  let header = null;
  let nexted = false;
  const res = {
    set(k, v) {
      header = [k, v];
      return this;
    },
    status(code) {
      status = code;
      return this;
    },
    json() {
      return this;
    },
  };
  mw({}, res, () => {
    nexted = true;
  });
  assert.strictEqual(nexted, false);
  assert.strictEqual(status, 503);
  assert.deepStrictEqual(header, ["Retry-After", "5"]);
});

if (process.exitCode) process.exit(process.exitCode);
