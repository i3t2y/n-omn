"use strict";

// Boot window: entrypoint opens the gate while init-nim-keys.sh is still
// registering keys. Forwarding /v1 then comes back as 502 / empty catalog
// and burns the fallback ledger. Hold /v1 with 503 until that process exits.
// /healthz is not this middleware's job and must stay 200 for the keepalive.

const DEFAULT_RUNNING = "/data/.init-running";
const DEFAULT_FAILED = "/data/.init-failed";

function initHoldDecision({ hold, running, failed }) {
  if (hold !== "1") return null;
  if (failed) {
    return {
      status: 503,
      error: "init_failed",
      retryAfter: 30,
      message: "Catalog init failed. Not forwarding. Restart after the init log is clean.",
    };
  }
  if (running) {
    return {
      status: 503,
      error: "init_pending",
      retryAfter: 5,
      message: "Catalog is still registering. Retry shortly.",
    };
  }
  return null;
}

function initHoldMiddleware(opts) {
  const fs = opts.fs || require("fs");
  const runningFile = opts.runningFile || DEFAULT_RUNNING;
  const failedFile = opts.failedFile || DEFAULT_FAILED;
  const log = opts.log;
  return function initHold(req, res, next) {
    let running = false;
    let failed = false;
    try {
      running = fs.existsSync(runningFile);
      failed = fs.existsSync(failedFile);
    } catch {
      running = false;
      failed = false;
    }
    const decision = initHoldDecision({ hold: opts.hold, running, failed });
    if (!decision) return next();
    if (log) {
      log(req, {
        httpStatus: decision.status,
        errorCode: decision.error,
        abortSource: "gate_init_hold",
        msg: decision.message,
      });
    }
    res.set("Retry-After", String(decision.retryAfter));
    return res.status(decision.status).json({
      error: { type: decision.error, message: decision.message },
    });
  };
}

module.exports = { initHoldDecision, initHoldMiddleware };
