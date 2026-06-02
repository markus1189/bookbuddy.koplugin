// Tier 3 assertion — edit an EXISTING (seeded) highlight's note. The fixture
// (seed_sdr=juliet.sdr) holds two Prologue highlights; in get_highlights order #1
// is the noted "In fair Verona" and #2 is the bare "ancient grudge". A turn asking
// to annotate the grudge line must look the list up (get_highlights) and then call
// edit_highlight_note on index 2 — NOT create_highlight (a new highlight would be
// the classic wrong move).
//
// Grades the TRACE. Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} output @param {object} _context */
module.exports = (output, _context) => {
  let env;
  try {
    env = JSON.parse(output);
  } catch (e) {
    return { pass: false, score: 0, reason: `driver output was not JSON (${e.message}): ${String(output).slice(0, 300)}` };
  }
  const meta = env.metadata || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');

  if (trace.some((t) => t.name === 'create_highlight')) {
    return { pass: false, score: 0, reason: `created a NEW highlight instead of editing the existing one: [${names}]` };
  }
  const ei = trace.findIndex((t) => t.name === 'edit_highlight_note');
  if (ei === -1) {
    return { pass: false, score: 0, reason: `no edit_highlight_note in trace: [${names}]` };
  }
  const input = trace[ei].input || {};
  const result = String(trace[ei].result || '');
  // The bare grudge highlight is index 2. Accept the call only if it targeted it and
  // the executor confirmed (results that begin "Error:" mean a bad index / no note).
  if (Number(input.highlight_index) !== 2) {
    return {
      pass: false,
      score: 0,
      reason: `edit_highlight_note targeted index ${input.highlight_index} (want 2 = "ancient grudge"). `
        + `input=${JSON.stringify(input)}`,
    };
  }
  if (/^Error:/.test(result) || !/note/i.test(result)) {
    return { pass: false, score: 0, reason: `edit_highlight_note did not confirm a note edit: "${result.slice(0, 160)}"` };
  }
  // Strong signal it grounded the index: get_highlights precedes the edit.
  const lookedUp = trace.slice(0, ei).some((t) => t.name === 'get_highlights');
  return {
    pass: true,
    score: lookedUp ? 1 : 0.8,
    reason: `edited the note on highlight 2 (ancient grudge)${lookedUp ? ', after a get_highlights lookup' : ' (no preceding get_highlights — index possibly guessed)'}. `
      + `Trace: [${names}]`,
  };
};
