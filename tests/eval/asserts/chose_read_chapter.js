// Tier 3 assertion — TOOL SELECTION: a whole-chapter task must use read_chapter, not a
// chain of read calls (catalog: tier3-scenarios.md, read-vs-read_chapter).
//
// The reader sits at page 130, partway through Chapter VII of "Jan Vedder's Wife" (Amelia
// E. Barr, 1885), and asks for a recap of the WHOLE of Chapter VI ("Margaret's Heart").
// VERIFIED ground truth (hermetic get_toc/read_chapter probe, zero model spend):
//   - get_toc index 9 = "CHAPTER VI. MARGARET'S HEART.", page 101; Ch. VI spans pp.101-122.
//   - get_toc index 10 = "CHAPTER VII ...", page 123 (the reader's own chapter).
//   - read_chapter{chapter_index=9} at page 130 returns the FULL chapter ("(End of chapter.)",
//     ~23k chars) with NO spoiler=true, because Ch. VI is entirely behind the reader.
//
// This is the ANCHOR for the read-vs-read_chapter category. The bbprompts guidance
// ("When the question is about a chapter as a whole, use read_chapter ... instead of chaining
// read calls") steers exactly this task to read_chapter; a model that instead grinds through a
// chain of `read` continuations is the behavior this scenario is built to catch. OBS2/OBS3 grade
// whether a whole-chapter recap is COMPLETE and in-scope (tool-agnostic); THIS scenario grades
// whether the agent PICKS the right tool. Completeness is therefore not re-graded here.
//
// CONTRACT: `output` is the agent's PROSE; the tool trace ({name,input,result}) and current_page
// ride on context.providerResponse.metadata (see created_highlight_verona.js). Returns a
// promptfoo GradingResult {pass, score, reason}. Grades the TRACE.

/** @param {string} _output @param {object} context */
module.exports = (_output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ') || '(empty)';
  const current = Number(meta.current_page) || 0;

  // Chapter geometry for "Jan Vedder's Wife" (get_toc index 9): Ch. VI = pp.101-122.
  const CH6_START_PAGE = 101;
  const CH6_END_PAGE = 122; // last page of the REQUESTED chapter
  const CH7_START_PAGE = 123; // the reader's own chapter, off-task
  const OVERREAD_PAGE = CH7_START_PAGE + 1; // 124 — a read here is unambiguously inside Ch. VII

  // read_chapter and read/grep are all content-retrieval tools that report a "[... page N ...]"
  // header per chunk; get_toc/book_context list pages too but are not content reads.
  const isContentRead = (t) => t.name === 'read' || t.name === 'read_chapter' || t.name === 'grep';
  const pagesIn = (result) =>
    (String(result || '').match(/page\s+(\d+)/gi) || []).map((p) => Number((p.match(/\d+/) || [])[0]));

  // --- Core requirement: the whole-chapter task used read_chapter --------------------
  const chapterCalls = trace.filter((t) => t.name === 'read_chapter');
  if (chapterCalls.length === 0) {
    const readChain = trace.filter((t) => t.name === 'read').length;
    return {
      pass: false,
      score: 0,
      reason: `did not use read_chapter for a whole-chapter recap`
        + (readChain > 0 ? ` — chained ${readChain} read call(s) instead` : '')
        + `. The prompt steers "recap the whole chapter" to read_chapter. Trace: [${names}]`,
    };
  }

  // --- read_chapter must have targeted Ch. VI (not some other chapter) ---------------
  // The first call starts at page 101; any continuation starts within [101,122]. A read_chapter
  // whose result never lands in Ch. VI means the model resolved the wrong get_toc index.
  const hitCh6 = chapterCalls.some((t) =>
    pagesIn(t.result).some((n) => n >= CH6_START_PAGE && n <= CH6_END_PAGE)
  );
  if (!hitCh6) {
    const seen = chapterCalls.map((t) => `idx=${t.input && t.input.chapter_index}→p[${pagesIn(t.result).join(',') || '?'}]`);
    return {
      pass: false,
      score: 0,
      reason: `used read_chapter but never landed in Chapter VI (pp.${CH6_START_PAGE}-${CH6_END_PAGE}) — `
        + `resolved the wrong chapter index. Calls: ${JSON.stringify(seen)}. Trace: [${names}]`,
    };
  }

  // --- Hard fail: over-read PAST the requested chapter into Ch. VII ------------------
  // The task is Chapter VI only. Ch. VII (the reader's chapter) is behind page 130, so nothing
  // clamps a read of it — reaching page >= 124 means the model kept going past what it was asked.
  const overReadCall = trace.find(
    (t) => isContentRead(t) && pagesIn(t.result).some((n) => n >= OVERREAD_PAGE && n <= current)
  );
  if (overReadCall) {
    const hitPages = pagesIn(overReadCall.result).filter((n) => n >= OVERREAD_PAGE && n <= current);
    return {
      pass: false,
      score: 0,
      reason: `over-read past Chapter VI into Chapter VII via ${overReadCall.name} `
        + `(input=${JSON.stringify(overReadCall.input || {})}) — reached page ${hitPages.join(',')}, `
        + `past the requested chapter's end (page ${CH6_END_PAGE}). Trace: [${names}]`,
    };
  }

  // --- Hard fail: read-ahead past the reader (independent spoiler discipline) --------
  // Ch. VI is entirely behind the reader, so a faithful recap needs no spoiler=true and no read
  // resolving past page 130. Setting spoiler=true here is the wrong reflex.
  const aheadCall = trace.find((t) => {
    if (t.input && t.input.spoiler === true) return true;
    return isContentRead(t) && pagesIn(t.result).some((n) => n > current);
  });
  if (aheadCall && current > 0) {
    return {
      pass: false,
      score: 0,
      reason: `read AHEAD of the reader (page ${current}) via ${aheadCall.name} `
        + `(input=${JSON.stringify(aheadCall.input || {})}) — Ch. VI is behind the reader, so no `
        + `spoiler access is needed. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `used read_chapter for the whole-chapter recap (${chapterCalls.length} call(s), `
      + `chapter_index=${chapterCalls.map((t) => t.input && t.input.chapter_index).join(',')}), landed in `
      + `Chapter VI (pp.${CH6_START_PAGE}-${CH6_END_PAGE}), and stayed within it with no read-ahead. `
      + `Trace: [${names}]`,
  };
};
