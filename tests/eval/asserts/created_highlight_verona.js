// Tier 3 promptfoo assertion (walking skeleton) — grades the tool TRACE, not the
// prose. juliet.epub ground truth: the FIRST "Verona" is the Prologue line "In
// fair Verona, where we lay our scene." on page 6 (loc:1) — NOT page 7 (the later
// "SCENE I. Verona. A public place.").
//
// CONTRACT (tier3_provider.js): the provider parses the driver's envelope, so
// `output` is the agent's final PROSE and the envelope metadata rides on
// context.providerResponse.metadata ({trace, usage, current_page, error, ...}).
// Each trace entry is {name, input, result} where `result` is the tool_result
// text (carrying the resolved page, e.g. "Highlighted on page 6, Prologue").
//
// Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} _output @param {object} context */
module.exports = (_output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }

  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  if (trace.length === 0) {
    return { pass: false, score: 0, reason: 'empty tool trace — the model took no tool actions' };
  }

  const names = trace.map((t) => t.name).join(', ');
  const hl = trace.findIndex((t) => t.name === 'create_highlight');
  if (hl === -1) {
    return { pass: false, score: 0, reason: `no create_highlight in trace: [${names}]` };
  }

  // The resolved page lives in the create_highlight tool_result text.
  const result = String(trace[hl].result || '');
  const page = (result.match(/page\s+(\d+)/i) || [])[1];
  const input = trace[hl].input || {};
  const onFirstVerona = page === '6' || input.locator === 'loc:1';
  if (!onFirstVerona) {
    return {
      pass: false,
      score: 0,
      reason: `create_highlight did not land on the first Verona (want page 6 / loc:1). `
        + `input=${JSON.stringify(input)} result="${result.slice(0, 160)}"`,
    };
  }

  // The model should LOCATE the line (grep / book_context) before highlighting,
  // not guess a locator blind. Soft signal: still a pass, but a lower score.
  const located = trace.slice(0, hl).some((t) => t.name === 'grep' || t.name === 'book_context');
  if (!located) {
    return {
      pass: true,
      score: 0.8,
      reason: `highlighted the first Verona (page ${page || 'loc:1'}) but without a preceding `
        + `grep/book_context — possibly guessed. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `create_highlight on page ${page || 'loc:1'} (first Verona), located via grep/book_context. `
      + `Trace: [${names}]`,
  };
};
