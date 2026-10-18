"use strict";

// Boot window: entrypoint opens the gate while init-nim-keys.sh is still
// registering keys. Forwarding /v1 then comes back as 502 / empty catalog
// and burns the fallback ledger. Hold /v1 with 503 until that process exits.
// /healthz is not this middleware's job and must stay 200 for the keepalive.
//
// Lock files alone are enough (helper.sh + patched entrypoint). Set
// GATE_INIT_HOLD=0 to force-forward even when a lock file is present.

const path = require("path");

function candidatePaths(envName, basename) {
  const out = [];
  if (process.env[envName]) out.push(process.env[envName]);
  const dataDir = process.env.DATA_DIR || "/app/data";
  out.push(path.join(dataDir, basename));
  out.push(path.join("/data", basename));
  out.push(path.join("/app/data", basename));
  return [...new Set(out)];
}

function anyExists(fs, paths) {
  for (const p of paths) {
    try {
      if (fs.existsSync(p)) return true;
    } catch {
      /* ignore */
    }
  }
  return false;
}

function initHoldDecision({ hold, running, failed }) {
  if (hold === "0") return null;
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
  const runningPaths = opts.runningPaths || candidatePaths("INIT_RUNNING_FILE", ".init-running");
  const failedPaths = opts.failedPaths || candidatePaths("INIT_FAILED_FILE", ".init-failed");
  const log = opts.log;
  return function initHold(req, res, next) {
    const running = anyExists(fs, runningPaths);
    const failed = anyExists(fs, failedPaths);
    const decision = initHoldDecision({
      hold: opts.hold !== undefined ? opts.hold : process.env.GATE_INIT_HOLD,
      running,
      failed,
    });
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

module.exports = { initHoldDecision, initHoldMiddleware, candidatePaths, anyExists };
