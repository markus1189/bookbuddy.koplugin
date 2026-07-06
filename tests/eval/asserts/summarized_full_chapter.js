// Tier 3 assertion — summarize ONE SPECIFIC earlier chapter without over-reading (OBS2).
//
// The reader sits at page 130, partway through Chapter VII of "Jan Vedder's Wife" (Amelia E.
// Barr, 1885). The task asks for Chapter V ("Shipwreck", pp.81-100, ~4090 words) BY NUMBER
// only — the model is NOT told the chapter's name. Chapter VI ("Margaret's Heart", pp.101-122)
// lies BETWEEN the target chapter and the reader — behind the reader, yet OUTSIDE the request:
// reading into it is over-reading, not a spoiler. The eval model is demonstrably BLIND to this
// book (3/3 closed-book oracles returned unanimous ignorance), so a faithful recap can only come
// from actually READING Ch. V to its late beats (the son's birth, the minister forcing Peter's
// door, the climactic wreck of The Solan on the Quarr rocks).
//
// The llm-rubrics grade the PROSE (completeness; staying within Ch. V). THIS deterministic
// assert grades the TRACE for the failures prose can't show:
//
//   - HARD FAIL (ungrounded): no grep/read/book_context — on a blind book an ungrounded recap
//     is fabrication.
//   - HARD FAIL (over-read past the request): a read/grep reaching into Chapter VI (page >= 102,
//     one page of boundary slack). The task is Ch. V ONLY; with the reader 30 pages past Ch. V
//     there is NO spoiler clamp at the V/VI boundary, so the model must stop at that line on its
//     own. Reading on into Ch. VI is exactly the over-reading this scenario is built to catch.
//   - HARD FAIL (read-ahead past the reader): a retrieval resolving past page 130, or any
//     spoiler=true input — genuine spoiler discipline, independent of the request.
//
// It also derives a SOFT coverage score from how near Ch. V's end (≈ page 100) the reads
// reached. Coverage is informational and does NOT gate — the prose rubric is the completeness
// authority, so this stays robust to chunk-size / tool-choice variance.
//
// Provider contract (see created_highlight_verona.js): `output` is the agent's prose;
// the trace ({name,input,result}) and current_page ride on
// context.providerResponse.metadata. Returns a promptfoo GradingResult {pass, score, reason}.

/** @param {string} _output @param {object} context */
module.exports = (_output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');
  const current = Number(meta.current_page) || 0;

  // Chapter geometry for "Jan Vedder's Wife": Ch. V = pp.81-100, Ch. VI starts p.101.
  const CHV_END_PAGE = 100;      // last page of the REQUESTED chapter
  const CHVI_START_PAGE = 101;   // first page of the next chapter (off-task)
  const OVERREAD_PAGE = CHVI_START_PAGE + 1; // 102 — a read here is unambiguously inside Ch. VI

  // Every "[page N]" / "page N" in a tool result, as numbers. crengine's bare in-text page
  // markers ("117") are NOT "page N" and don't count — so this tracks the START page of each
  // read chunk (the tool header), not every page a chunk spans.
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

  // --- Hard fail: over-read PAST the requested chapter into Ch. VI -------------------
  // The task is Chapter V only. With the reader at page 130 there is no spoiler clamp at the
  // V/VI boundary, so a content read reaching page >= 102 means the model kept going into the
  // next chapter instead of stopping at the end of what it was asked about.
  const overReadCall = trace.find((t) => {
    if (t.name === 'read' || t.name === 'grep') {
      return pagesIn(t.result).some((n) => n >= OVERREAD_PAGE && n <= current);
    }
    return false;
  });
  if (overReadCall) {
    const hitPages = pagesIn(overReadCall.result).filter((n) => n >= OVERREAD_PAGE && n <= current);
    return {
      pass: false,
      score: 0,
      reason: `over-read past Chapter V into Chapter VI via ${overReadCall.name} `
        + `(input=${JSON.stringify(overReadCall.input || {})}) — a retrieval reached page `
        + `${hitPages.join(',')}, past the requested chapter's end (≈ page ${CHV_END_PAGE}). The `
        + `task was Ch. V ONLY, and nothing clamped the read here. Trace: [${names}]`,
    };
  }

  // --- Hard fail: read-ahead past the reader (independent spoiler discipline) --------
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
        + `(input=${JSON.stringify(aheadCall.input || {})}). Trace: [${names}]`,
    };
  }

  // --- Soft coverage signal: did the reads reach Chapter V's end region (≈ p.100)? ---
  // read headers report the chunk's START page, so the page heuristic lags the true end
  // reached; treat reaching within ~2 pages of the boundary as "read to the end".
  let maxPage = 0;
  for (const t of trace) {
    if (t.name === 'read' || t.name === 'grep') {
      for (const n of pagesIn(t.result)) if (n <= CHV_END_PAGE && n > maxPage) maxPage = n;
    }
  }
  const reachedEnd = maxPage >= CHV_END_PAGE - 2;
  if (!reachedEnd) {
    return {
      pass: true,
      score: 0.8,
      reason: `grounded, stayed within Ch. V, no read-ahead — but reads only reached page `
        + `${maxPage || '?'} of the chapter's ≈ ${CHV_END_PAGE}, so end-to-end coverage is `
        + `unconfirmed from the trace; the prose rubric is the completeness authority. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `grounded, stayed within Chapter V (no drift into Ch. VI), no read-ahead, and reads `
      + `reached page ${maxPage} near the chapter's end (≈ ${CHV_END_PAGE}) — consistent with `
      + `reading the whole requested chapter and stopping at its boundary. Trace: [${names}]`,
  };
};
