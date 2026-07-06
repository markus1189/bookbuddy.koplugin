// Tier 3 assertion — DEL1 "Cross-cutting analysis launches a delegate"
// (catalog: tier3-scenarios.md, delegation category).
//
// juliet.epub, reader near the END (start_page 250 clamps to the last page ~241, so
// NOTHING is spoiler-gated) and enable_subagents ON (the driver wires the per-test
// `enable_subagents` var into cfg, which is what makes Conversation:new keep the
// `delegate` tool AND buildBody append the DELEGATE_NOTE). The task asks for a WIDE,
// cross-cutting sweep of the whole play — tracing a motif end to end — which the
// delegation guidance (bbprompts DELEGATE_NOTE / delegate tool description) explicitly
// steers to a helper: "tracing a motif ... across the whole book ... so all that
// intermediate searching stays out of our conversation." A single-passage question,
// by contrast, the model should answer itself. This is the ANCHOR for the delegation
// category: the model must recognise a whole-book research job and hand it off rather
// than grinding through the greps inline in the parent's own context.
//
// The delegate tool_use lands in the parent's message history like any other, so the
// driver's trace reconstruction surfaces it as a { name: 'delegate', input, result }
// entry — that is the signal this assert grades.
//
// CONTRACT: `output` is the agent's PROSE; the tool trace rides on
// context.providerResponse.metadata (see created_highlight_verona.js).
//
// Grades the TRACE. Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} _output @param {object} context */
module.exports = (_output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');

  // --- Core requirement: the wide sweep was delegated -------------------------------
  const del = trace.find((t) => t.name === 'delegate');
  if (!del) {
    return {
      pass: false,
      score: 0,
      reason: `did not delegate the cross-cutting sweep — the model ran it inline `
        + `instead of handing it to a helper. Trace: [${names || '(empty)'}]`,
    };
  }

  // A delegate with an empty task burns a round on nothing (bbsubagents refuses it),
  // so a real hand-off carries a self-contained instruction.
  const task = del.input && typeof del.input.task === 'string' ? del.input.task.trim() : '';
  if (task === '') {
    return {
      pass: false,
      score: 0,
      reason: `delegated with an empty task (input=${JSON.stringify(del.input || {})}). Trace: [${names}]`,
    };
  }

  // --- Spoiler hygiene: the reader did NOT ask to read ahead ------------------------
  // The task is a whole-book sweep but the reader never asked to look past their
  // position, so allow_spoiler must stay false/absent. (At this start_page the reader
  // is already at the end, so nothing leaks either way — but setting the flag without
  // being asked is the wrong reflex, worth a soft ding rather than a hard fail.)
  if (del.input && del.input.allow_spoiler === true) {
    return {
      pass: true,
      score: 0.7,
      reason: `delegated the sweep (good) but set allow_spoiler=true unprompted — the `
        + `reader did not ask to read ahead. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `delegated the cross-cutting sweep to a helper (task="${task.slice(0, 120)}"). Trace: [${names}]`,
  };
};
