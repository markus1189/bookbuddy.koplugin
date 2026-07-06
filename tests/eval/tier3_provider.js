// Tier 3 custom promptfoo provider (`file://tier3_provider.js`) — the structured
// replacement for the former bare `exec:bb-tier3-exec` provider.
//
// WHY THIS EXISTS: promptfoo's `exec:` provider does NOT parse the script's stdout —
// it hands the driver's whole JSON envelope to promptfoo as one opaque STRING, so the
// web UI showed raw JSON in the output cell, an empty Metadata panel, zero tokens and
// zero cost, and every assert had to JSON.parse the envelope itself. This provider
// spawns the SAME `bb-tier3-exec` wrapper with the SAME argv contract, parses the
// envelope ONCE, and returns a real ProviderResponse:
//   output     — the agent's final PROSE (clean output cell; llm-rubrics need no transform)
//   metadata   — the driver's envelope metadata verbatim ({trace, usage, stop_reason,
//                current_page, ...}); asserts read it via context.providerResponse.metadata,
//                and the UI renders it in the Metadata panel
//   tokenUsage — mapped from metadata.usage so the token columns light up
//
// `bb-tier3-exec` (flake.nix) still OWNS the koreader runtime env and emits ONLY the
// driver's envelope on stdout; it resolves via PATH (the `.#eval` app's runtimeInputs).
// argv mirrors what promptfoo's exec provider used to pass — (prompt, optionsJSON,
// contextJSON) — because tier3_driver.lua reads arg[1] = task and arg[3] = context
// (→ vars.epub / start_page / seed_sdr / enable_*).

'use strict';

const { execFile } = require('node:child_process');

// A whole-book agent trace with tool results can get big; do not let Node's default
// 1 MiB maxBuffer truncate the envelope mid-JSON.
const MAX_BUFFER = 64 * 1024 * 1024;

class BBTier3Provider {
  constructor(options) {
    options = options || {};
    this.providerId = options.id || 'bb-tier3';
    this.label = options.label;
    this.config = options.config || {};
  }

  id() {
    return this.providerId;
  }

  toString() {
    return '[BookBuddy Tier-3 provider (bb-tier3-exec)]';
  }

  async callApi(prompt, context) {
    const vars = (context && context.vars) || {};
    const argv = [prompt, JSON.stringify({ config: this.config }), JSON.stringify({ vars })];

    let stdout;
    try {
      stdout = await new Promise((resolve, reject) => {
        execFile('bb-tier3-exec', argv, { maxBuffer: MAX_BUFFER }, (err, out, stderr) => {
          if (err) {
            reject(new Error(`bb-tier3-exec failed: ${err.message}\nstderr tail: ${String(stderr).slice(-500)}`));
          } else {
            resolve(out);
          }
        });
      });
    } catch (e) {
      return { error: String(e.message || e) };
    }

    // The wrapper emits exactly ONE envelope line (from BB_EVAL_OUT, so koreader's
    // ffi-load noise can't pollute it). A parse failure here means the driver died
    // before emit() — surface it as a provider ERROR (asserts are skipped), which is
    // the honest classification for a harness crash, vs. the old behavior where every
    // assert individually failed with "driver output was not JSON".
    let env;
    try {
      env = JSON.parse(stdout);
    } catch (e) {
      return {
        error: `driver emitted no parseable envelope (${e.message}): ${String(stdout).slice(0, 300)}`,
      };
    }

    const metadata = env.metadata || {};
    const response = {
      output: typeof env.output === 'string' ? env.output : '',
      metadata,
    };

    // bbanthropic accumulates {input, output, cache_write, cache_read} across the
    // loop's API turns. promptfoo's prompt/completion columns want the model's total
    // input-side work, so fold the cache buckets into `prompt` and surface the read
    // bucket in `cached`. Absent usage (BB_DRY_RUN, a pre-first-turn crash) → omit.
    const u = metadata.usage;
    if (u && typeof u === 'object') {
      const promptTokens = (u.input || 0) + (u.cache_write || 0) + (u.cache_read || 0);
      const completionTokens = u.output || 0;
      response.tokenUsage = {
        prompt: promptTokens,
        completion: completionTokens,
        total: promptTokens + completionTokens,
        cached: u.cache_read || 0,
        numRequests: 1,
      };
    }

    return response;
  }
}

module.exports = BBTier3Provider;
