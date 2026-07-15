// Tier 3 assertion — C1 "Spoiler-free character portrait" (catalog: tier3-scenarios.md).
//
// Pride & Prejudice @ page 160. Mr. Wickham has just been introduced in the
// NARRATIVE (first narrative hit is page 152 / loc:7, behind the reader) as the
// charming officer who tells Elizabeth his sympathetic account of being wronged
// by Darcy. The task asks for a read on him "so far". A faithful portrait stays
// inside what the page supports — charming, agreeable, plausibly ill-used — and
// must NOT pre-reveal that he is a deceiver who later elopes with Lydia.
//
// TWO leak channels (cf. tier3-scenarios.md "How to read this"):
//   * Trace-detectable — the model re-retrieves with spoiler=true, or reads/greps
//     ahead of page 160, to "complete the picture" with Wickham's later arc.
//   * Prose-only — the model recites the villain reveal FROM PRETRAINING with a
//     clean trace. The proper grader for this is an llm-rubric, which is still
//     DEFERRED (no second credentialed provider wired; see tier3-promptfoo.md
//     "Deferred"). Until then the forbidden-token regex backstop endorsed by the
//     catalog ("/seduc|elope|deceiv/i") is the deterministic guard that ships.
//
// NOTE we deliberately do NOT forbid "Darcy": at p.160 the reader has just heard
// Wickham's OWN account blaming Darcy, so a faithful portrait names Darcy. The
// HAZARD edition's editorial intro (pp.13-28) names Wickham + the elopement and
// sits BEHIND the reader, so a "Wickham" grep surfaces those page-legal spoiler
// hits (product Bug #1) — undetectable by the page gate, which is exactly why the
// prose regex, not a page check, is the catch for that fallout.
//
// Grades the TRACE + PROSE. Returns a promptfoo GradingResult {pass, score, reason}.

// Unambiguous spoilers for a p.160 Wickham portrait. None have textual support yet:
// the elopement/seduction reveal and Darcy's vindicating letter are ~p.200+. Kept
// high-precision (the catalog's /seduc|elope|deceiv/ core + a few equally-specific
// leaks) so a faithful portrait can't trip it even by negation — nuanced prose
// judgement is the deferred llm-rubric's job, not this deterministic backstop. NB
// "Darcy" is intentionally absent: at p.160 Wickham's charming account slanders
// Darcy on-page (probe confirms p.152/153), so a faithful portrait names Darcy.
const FORBIDDEN = /seduc|elope|deceiv|swindl|\blydia\b|gambling debt/i;

// CONTRACT: `output` is the agent's PROSE; the tool trace and current_page ride on
// context.providerResponse.metadata (see created_highlight_verona.js).

/** @param {string} output @param {object} context */
module.exports = (output, context) => {
  const meta = (context && context.providerResponse && context.providerResponse.metadata) || {};
  if (meta.error) {
    return { pass: false, score: 0, reason: `driver reported error: ${meta.error}` };
  }
  const prose = String(output || '');
  const trace = Array.isArray(meta.trace) ? meta.trace : [];
  const names = trace.map((t) => t.name).join(', ');
  const current = Number(meta.current_page) || 160;

  // Only content-retrieval tools can leak later text by reading ahead. get_toc
  // returns the table of contents, whose page numbers necessarily include later
  // chapters -- that is navigation metadata, not the story text, and the prompt
  // steers the model to get_toc for exactly this. Scanning its result for
  // "page > current" is a false positive (cf. summarized_full_chapter.js, which
  // gates the same check on isContentRead). Keep read/read_chapter/grep in scope.
  const isContentRead = (t) => t.name === 'read' || t.name === 'read_chapter' || t.name === 'grep';

  // --- Hard fail: prose-only leak (the dangerous channel) ----------------------
  const hit = prose.match(FORBIDDEN);
  if (hit) {
    return {
      pass: false,
      score: 0,
      reason: `prose leaked a future-plot spoiler (matched /${hit[0]}/). A p.${current} Wickham `
        + `portrait has no textual basis for it — likely recited from pretraining. Trace: [${names}]`,
    };
  }

  // --- Hard fail: trace-detectable leak (reading ahead to "complete" him) -------
  const aheadCall = trace.find((t) => {
    if (t.input && t.input.spoiler === true) return true;
    if (!isContentRead(t)) return false;
    // A content read whose resolved page text exceeds the reader's current page.
    const pages = String(t.result || '').match(/page\s+(\d+)/gi) || [];
    return pages.some((p) => Number((p.match(/\d+/) || [])[0]) > current);
  });
  if (aheadCall) {
    return {
      pass: false,
      score: 0,
      reason: `retrieved ahead of the reader (page ${current}) to build the portrait `
        + `(${aheadCall.name}, input=${JSON.stringify(aheadCall.input || {})}). Reading ahead IS the spoiler. Trace: [${names}]`,
    };
  }

  // --- Grounding gate: a portrait should rest on the text, not pure pretraining -
  // (Soft — a clean restrained answer still demonstrates the product value; but a
  // no-tool answer on a book the model knows cold can't be distinguished from
  // recitation, so it scores lower. cf. methodology note in tier3-scenarios.md.)
  const grounded = trace.some((t) => isContentRead(t) || t.name === 'book_context');
  if (!grounded) {
    return {
      pass: true,
      score: 0.7,
      reason: `spoiler-free portrait, but ungrounded (no grep/read/book_context) — restraint shown, `
        + `yet indistinguishable from pretraining recitation. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `grounded, spoiler-free Wickham portrait — no forbidden tokens, no read-ahead. Trace: [${names}]`,
  };
};
