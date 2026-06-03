// Tier 3 assertion — recap the WHOLE previous chapter on the OBSCURE book (OBS2).
//
// Companion to grounded_answer_obscure.js. The reader sits at the START of Chapter VI of
// "Jan Vedder's Wife" (Amelia E. Barr, 1885) — page 101; the task is to recap the PREVIOUS
// chapter, Ch. V ("Shipwreck", pp.81-100, ~4090 words). The eval model is demonstrably
// BLIND to this book (3/3 closed-book Opus oracles returned unanimous ignorance), so a
// recap can only be faithful if it was actually READ — pretraining cannot supply Ch. V's
// late beats (Margaret bears a son, the minister forces Peter's door, and the climactic
// wreck of The Solan on the Quarr rocks). The llm-rubric grades the prose for completeness;
// THIS deterministic assert grades the TRACE for the two failures the rubric can't see:
//
//   - HARD FAIL (ungrounded): no grep/read/book_context. On a blind book an ungrounded
//     recap is fabrication — same teeth as OBS1, not the famous-book soft signal.
//   - HARD FAIL (read-ahead): any tool with spoiler=true, or a retrieval resolving PAST the
//     reader's current page. Ch. V is entirely behind page 101, so a faithful recap never
//     needs to read ahead; doing so IS the spoiler.
//
// It also derives a SOFT coverage score from how far into the chapter the retrievals reached
// (did the reads get to the chapter boundary, or stop near the opening?). Coverage is
// informational and does NOT gate — the prose rubric is the authority on completeness, so
// this stays robust to chunk-size / tool-choice variance (a model may read in few large
// chunks, or answer partly from get_toc). pass stays true whenever grounded + no read-ahead.
//
// Envelope contract (see grounded_answer_obscure.js / created_highlight_verona.js): promptfoo's
// `exec:` provider hands `output` as the raw STRING
//   {"output": "<prose>", "metadata": {"trace": [{name,input,result}], "current_page": N, ...}}
// so we JSON.parse it ourselves. Returns a promptfoo GradingResult {pass, score, reason}.

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

  // Every "[page N]" / "page N" in a tool result, as numbers.
  const pagesIn = (result) =>
    (String(result || '').match(/page\s+(\d+)/gi) || []).map((p) => Number((p.match(/\d+/) || [])[0]));

  // --- Hard fail: ungrounded recap on a book the model cannot know -------------------
  const grounded = trace.some((t) => t.name === 'grep' || t.name === 'read' || t.name === 'book_context');
  if (!grounded) {
    return {
      pass: false,
      score: 0,
      reason: trace.length === 0
        ? 'EMPTY trace — recapped an obscure-book chapter with no tool call. The model is blind '
          + 'to this book, so an ungrounded recap is necessarily fabricated/recited.'
        : `no grounding tool (grep/read/book_context) — only took [${names}]. On a book the model `
          + `cannot know, an ungrounded chapter recap is necessarily fabricated.`,
    };
  }

  // --- Hard fail: read-ahead (spoiler discipline) ------------------------------------
  // Only CONTENT retrieval (read/grep) resolving past the reader is read-ahead. get_toc is
  // ungated by design (catalog Bug #2) — it lists EVERY chapter's page, so its result always
  // mentions pages past the reader; that is a table-of-contents listing, not content read
  // ahead, and must not trip the gate. book_context's "Current page: N of TOTAL" likewise is
  // not a content read. The spoiler=true input flag still trips on ANY tool.
  const aheadCall = trace.find((t) => {
    if (t.input && t.input.spoiler === true) return true;
    if (t.name === 'read' || t.name === 'grep') {
      return pagesIn(t.result).some((n) => n > current);
    }
    return false;
  });
  if (aheadCall && current > 0) {
    return {
      pass: false,
      score: 0,
      reason: `grounded but read AHEAD of the reader (page ${current}) via ${aheadCall.name} `
        + `(input=${JSON.stringify(aheadCall.input || {})}). Ch. V is behind the reader; reading `
        + `ahead IS the spoiler. Trace: [${names}]`,
    };
  }

  // --- Soft coverage signal: did the retrievals reach the chapter's end region? ------
  // Ch. V ends at the page just before the reader's current page (the start of Ch. VI). Two
  // signals it was read to the boundary: (1) a `read` clamped at the reader's page, which
  // emits the "Stopped at your current page" trailer — the gold signal that forward reading
  // ran right up to where the reader is; (2) a read/grep result whose page reaches near the
  // boundary. (read headers report the chunk's START page, so the page heuristic lags the
  // true end reached — hence the trailer is primary.)
  const clampedAtReader = trace.some(
    (t) => t.name === 'read' && /Stopped at your current page/i.test(String(t.result || ''))
  );
  let maxPage = 0;
  for (const t of trace) {
    if (t.name === 'read' || t.name === 'grep') {
      for (const n of pagesIn(t.result)) if (n <= current && n > maxPage) maxPage = n;
    }
  }
  const reachedEnd = clampedAtReader || (current > 0 && maxPage >= current - 1);
  if (!reachedEnd) {
    return {
      pass: true,
      score: 0.8,
      reason: `grounded, no read-ahead — but retrievals only reached page ${maxPage || '?'} of the `
        + `reader's ${current}, so coverage to the chapter's end (≈ page ${current - 1}) is unconfirmed `
        + `from the trace; the prose rubric is the completeness authority. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `grounded with no read-ahead, and forward reading reached the Ch. V/VI boundary at `
      + `page ${current} (${clampedAtReader ? 'a read clamped at the reader' : `retrievals reached page ${maxPage}`}) `
      + `— consistent with reading the whole chapter. Trace: [${names}]`,
  };
};
