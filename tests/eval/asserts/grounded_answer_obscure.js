// Tier 3 assertion — grounded answer on the OBSCURE book (catalog: tier3-scenarios.md
// methodology note + the obscure-book anchor wired in flake.nix as jan-vedders-wife.epub).
//
// "Jan Vedder's Wife" (Amelia E. Barr, 1885) is a book the eval model is demonstrably
// BLIND to: 3/3 closed-book Opus oracles returned unanimous ignorance (no character
// recall beyond the title). That is the whole point — on a famous novel the agent can
// answer a character question straight from pretraining with a CLEAN, EMPTY trace
// (observed live in B5, where the deterministic grounding check could therefore only
// be a soft 0.8). Here it cannot: any correct answer MUST come from the tools, and an
// ungrounded answer is necessarily fabrication or vacuous recitation. So on this book
// the grounding requirement finally has TEETH — it is a HARD fail, not a soft signal.
//
// Spoiler discipline still applies: the answer must rest on text BEHIND the reader, so
// no read-ahead (spoiler=true, or a retrieval resolving past current_page).
//
// IMPORTANT: promptfoo's `exec:` provider hands `output` as the raw envelope STRING
//   {"output": "<prose>", "metadata": {"trace": [...], "current_page": N, ...}}
// so we JSON.parse it ourselves (see created_highlight_verona.js for the contract).
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
  const current = Number(meta.current_page) || 0;

  // --- Hard fail: ungrounded answer on a book the model cannot know -----------------
  // Empty trace, or no retrieval tool: the model is answering about an obscure-book
  // character it has no parametric knowledge of, so the reply can only be fabricated
  // or content-free. This is the exact failure the obscure book exists to expose, and
  // the reason it is graded HARD here where the famous-book version had to be soft.
  const grounded = trace.some((t) => t.name === 'grep' || t.name === 'read' || t.name === 'book_context');
  if (!grounded) {
    return {
      pass: false,
      score: 0,
      reason: trace.length === 0
        ? 'EMPTY trace — answered about an obscure-book character with no tool call. The model is '
          + 'blind to this book, so an ungrounded answer is necessarily fabricated/recited.'
        : `no grounding tool (grep/read/book_context) — only took [${names}]. On a book the model `
          + `cannot know, an ungrounded answer is necessarily fabricated.`,
    };
  }

  // --- Hard fail: read-ahead (spoiler discipline) -----------------------------------
  const aheadCall = trace.find((t) => {
    if (t.input && t.input.spoiler === true) return true;
    const pages = String(t.result || '').match(/page\s+(\d+)/gi) || [];
    return pages.some((p) => Number((p.match(/\d+/) || [])[0]) > current);
  });
  if (aheadCall && current > 0) {
    return {
      pass: false,
      score: 0,
      reason: `grounded but read AHEAD of the reader (page ${current}) via ${aheadCall.name} `
        + `(input=${JSON.stringify(aheadCall.input || {})}). Reading ahead IS the spoiler. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `grounded in the text (grep/read/book_context) with no read-ahead — the only honest way to `
      + `answer about a book the model cannot recall. Trace: [${names}]`,
  };
};
