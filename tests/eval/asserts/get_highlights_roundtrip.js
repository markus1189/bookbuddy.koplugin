// Tier 3 assertion — seeded-fixture round-trip. The book is opened with a fixture
// .sdr (tests/eval/fixtures/juliet.sdr, via the `seed_sdr` var) that already holds
// two Prologue highlights: a NOTE on "In fair Verona" and a bare highlight on
// "ancient grudge". A "what have I highlighted?" turn must call get_highlights and
// surface those real, pre-existing annotations (proving the seed loaded on open).
//
// Grades the TRACE (see created_highlight_verona.js for the provider contract:
// prose in `output`, trace on context.providerResponse.metadata).
// Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} output @param {object} context */
module.exports = (output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');

  const gh = trace.find((t) => t.name === 'get_highlights');
  if (!gh) {
    return { pass: false, score: 0, reason: `no get_highlights in trace: [${names}]` };
  }
  // The tool_result must list the seeded annotations — proves they loaded from the
  // fixture sidecar rather than the model inventing or the open starting empty.
  const result = String(gh.result || '');
  const sawVerona = /Verona/i.test(result);
  const sawGrudge = /grudge/i.test(result);
  if (!(sawVerona && sawGrudge)) {
    return {
      pass: false,
      score: 0,
      reason: `get_highlights did not return both seeded highlights `
        + `(Verona=${sawVerona}, grudge=${sawGrudge}). result="${result.slice(0, 200)}"`,
    };
  }
  // The prose should actually report them back to the reader (not just call the tool).
  const prose = String(output || '');
  const proseReflects = /Verona|grudge|Prologue/i.test(prose);
  return {
    pass: true,
    score: proseReflects ? 1 : 0.8,
    reason: `get_highlights returned the seeded annotations; prose ${proseReflects ? 'reflects' : 'omits'} them. `
      + `Trace: [${names}]`,
  };
};
