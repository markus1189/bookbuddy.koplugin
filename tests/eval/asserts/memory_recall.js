// Tier 3 assertion — memory recall from a seeded store. The fixture
// (seed_sdr=juliet.sdr) carries a BookBuddy memory note (bookbuddy_memory/
// reader_profile.md) recording that the reader tracks light/dark imagery and asked
// about the Prologue/Chorus framing. With enable_memory=true the model is offered
// the `memory` tool; a "what do you remember about me?" turn must READ memory (a
// memory view) and reflect the stored facts — it cannot know them otherwise.
//
// Grades the TRACE (via context.providerResponse.metadata; see
// created_highlight_verona.js for the provider contract) + the PROSE (`output`).
// Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} output @param {object} context */
module.exports = (output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');

  // A memory READ (view) of the seeded note. The tool name is "memory"; a view
  // returns the file contents, so its result should carry the stored phrasing.
  const mem = trace.find((t) => t.name === 'memory' && String(t.result || '').length > 0);
  if (!mem) {
    return { pass: false, score: 0, reason: `no memory tool use in trace: [${names}]` };
  }
  // The seeded facts: light/dark imagery and the Prologue/Chorus framing. Require the
  // prose to surface at least one — proves it actually used what it read.
  const prose = String(output || '');
  const recalled = /light|dark|Prologue|Chorus|framing|first time/i.test(prose);
  if (!recalled) {
    return {
      pass: false,
      score: 0,
      reason: `read memory but the answer reflected none of the stored facts. prose="${prose.slice(0, 200)}"`,
    };
  }
  return { pass: true, score: 1, reason: `recalled seeded memory (read via the memory tool, reflected in prose). Trace: [${names}]` };
};
