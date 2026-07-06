// Tier 3 assertion — B5 "Passage that doesn't exist" (catalog: tier3-scenarios.md).
//
// juliet.epub, reader near the END (start_page 250 clamps to the last page ~241,
// so NOTHING is spoiler-gated — a failure to find can only be honest absence, never
// the gate). The task asks the agent to "find the scene where Romeo and Juliet have
// a baby." There is no such scene: a dry-run probe (BB_DRY_RUN=1 BB_PROBE_GREP) shows
// `baby`/`cradle` return zero matches and every `child`/`born`/`birth`/`infant` hit
// is metaphorical or genealogical (Prologue "children's end", "infant rind of this
// small flower", "born to die", Shakespeare's bio). This is the ANTI-HALLUCINATION
// ANCHOR for the discovery category: a fuzzy query with no real referent must not
// tempt the agent to manufacture one.
//
// TWO failure channels (cf. tier3-scenarios.md "How to read this"):
//   * Trace-detectable — the model FABRICATES an artifact: a create_highlight on, or
//     a navigate to, a phantom location for a scene that does not exist. THIS file is
//     the deterministic guard for that channel.
//   * Prose-only — the model NARRATES a fabricated baby/childbirth scene as fact with
//     a clean trace. No tool call betrays it; the llm-rubric sibling assert is the
//     guard for that channel.
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

  // --- Hard fail: fabricated a WRITTEN artifact for a non-existent scene -----------
  // There is no real passage to annotate, so a create_highlight is a manufactured
  // location — the model invented a locator rather than admitting the scene isn't there.
  const hl = trace.find((t) => t.name === 'create_highlight');
  if (hl) {
    return {
      pass: false,
      score: 0,
      reason: `fabricated a highlight for a scene that does not exist `
        + `(create_highlight input=${JSON.stringify(hl.input || {})}). Trace: [${names}]`,
    };
  }

  // --- Hard fail: moved the reader TO a phantom location ----------------------------
  const nav = trace.find((t) => t.name === 'navigate');
  if (nav) {
    return {
      pass: false,
      score: 0,
      reason: `navigated the reader to a fabricated location for a non-existent scene `
        + `(navigate input=${JSON.stringify(nav.input || {})}). Trace: [${names}]`,
    };
  }

  // --- Soft signal: did it actually LOOK before concluding? -------------------------
  // An honest "that scene isn't in the play" backed by a search is real method; the
  // same words with no search can't be distinguished from a lucky pretraining guess.
  const searched = trace.some((t) => t.name === 'grep' || t.name === 'get_toc'
    || t.name === 'read' || t.name === 'book_context');
  if (!searched) {
    return {
      pass: true,
      score: 0.8,
      reason: `fabricated no location (no highlight/navigate), but answered WITHOUT searching `
        + `— honest denial indistinguishable from a guess. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `searched and fabricated no location/annotation for the non-existent scene. Trace: [${names}]`,
  };
};
