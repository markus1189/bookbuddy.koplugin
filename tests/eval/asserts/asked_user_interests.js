// Tier 3 assertion — ASK1 "Get-started preset asks the reader about their interests"
// (catalog: tier3-scenarios.md, clarifying-question category).
//
// juliet.epub, reader at the very START (start_page 1) and enable_clarifying_questions
// ON. The task is the built-in "Get started" preset (bbpresets.lua Presets.book[1]):
// "I'm just starting this book. Before I get into it, interview me about what I want to
// focus on ... ask a few short questions, one at a time...". The intended behaviour is
// for the agent to TURN THE QUESTION AROUND and ask the reader — via the ask_user tool —
// rather than guessing what they care about or launching into an overview. This is the
// ANCHOR for the clarifying-question category: a prompt that explicitly wants the model
// to elicit the reader's intent should trigger ask_user.
//
// HANG NOTE: the headless driver stubs Conversation:_askUser to return a skip WITHOUT
// parking the coroutine (tier3_driver.lua section 5), so the model asks once, gets a
// skip, and moves on — no deadlock. The ask_user tool_use is still committed to the
// assistant turn (bbconversation _storeAssistant) before dispatch, so it lands in
// metadata.trace and this assert can see it. We grade only that the tool was CALLED
// (and, softly, that it asked about interests); we do NOT grade a full interview, which
// the skip stub cannot support.
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

  const asks = trace.filter((t) => t.name === 'ask_user');
  if (asks.length === 0) {
    return {
      pass: false,
      score: 0,
      reason: `did not call ask_user — answered/guessed instead of asking the reader about `
        + `their interests. Trace: [${names || '(empty)'}]`,
    };
  }

  // Soft signal: is the (first) question actually about what the reader cares about? The
  // preset is an interest interview, so the question should be about focus/interests/goals
  // — not, say, a generic "which book?". A call that asks something off-topic still passes
  // (the tool WAS used, which is the property under test) but at a reduced score.
  const q = (asks[0].input && typeof asks[0].input.question === 'string' ? asks[0].input.question : '').toLowerCase();
  const aboutInterests = /interest|focus|pay attention|care about|looking for|hope to|want to|curious|enjoy|goal|why .*reading|drew you|drawn to/.test(q);
  if (!aboutInterests) {
    return {
      pass: true,
      score: 0.7,
      reason: `called ask_user (${asks.length}x) but the first question is not clearly about the `
        + `reader's interests (q="${q.slice(0, 80)}"). Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `asked the reader about their interests via ask_user (${asks.length}x; `
      + `q="${q.slice(0, 80)}"). Trace: [${names}]`,
  };
};
