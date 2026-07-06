// Tier 3 assertion — DEL2 "Two portraits fan out into two delegates"
// (catalog: tier3-scenarios.md, delegation category).
//
// juliet.epub, reader near the END (start_page 250 clamps to the last page ~241, so
// NOTHING is spoiler-gated — both characters' full arcs are on the table) and
// enable_subagents ON. The task asks for a character portrait of BOTH Romeo AND Juliet.
// Each portrait is its own wide, whole-book research job, so the intended shape is to
// fan OUT into TWO delegates — one researching Romeo, one researching Juliet — rather
// than one delegate carrying both (which re-couples the busywork this feature exists to
// split) or grinding both inline. This is the DECOMPOSITION anchor: DEL1 checks that a
// single wide task gets delegated at all; DEL2 checks the model splits an obviously
// two-part request into two parallel hand-offs.
//
// Each delegate tool_use lands in the parent's message history, so the driver's trace
// reconstruction surfaces them as { name: 'delegate', input, result } entries — that is
// the signal this assert grades. We require two DISTINCT delegate calls, one whose task
// names Juliet and a different one whose task names Romeo.
//
// IMPORTANT: promptfoo's `exec:` provider hands `output` as the raw envelope STRING
//   {"output": "<prose>", "metadata": {"trace": [...], ...}}
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

  const delegates = trace.filter((t) => t.name === 'delegate');
  const tasks = delegates.map((d) => (d.input && typeof d.input.task === 'string' ? d.input.task : '').toLowerCase());

  // --- Ran the whole thing inline — never delegated at all -------------------------
  if (delegates.length === 0) {
    return {
      pass: false,
      score: 0,
      reason: `did not delegate — ran both portraits inline instead of fanning out. Trace: [${names || '(empty)'}]`,
    };
  }

  // --- Delegated with an empty task (bbsubagents refuses it) ------------------------
  if (tasks.some((t) => t.trim() === '')) {
    return {
      pass: false,
      score: 0,
      reason: `a delegate carried an empty task (${delegates.length} delegate call(s)). Trace: [${names}]`,
    };
  }

  // --- Batched both characters into ONE delegate — no fan-out -----------------------
  // The point of this scenario is the split; a single delegate (even one covering both
  // Romeo and Juliet) is not the two-way decomposition the request calls for.
  if (delegates.length === 1) {
    return {
      pass: false,
      score: 0,
      reason: `delegated once for both characters instead of one delegate per character `
        + `(task="${tasks[0].slice(0, 120)}"). Trace: [${names}]`,
    };
  }

  // --- Two+ delegates: require one focused on Juliet and a DISTINCT one on Romeo ----
  const jIdx = tasks.findIndex((t) => /\bjuliet\b/.test(t));
  const rIdx = tasks.findIndex((t, i) => i !== jIdx && /\bromeo\b/.test(t));
  if (jIdx === -1 || rIdx === -1) {
    return {
      pass: false,
      score: 0,
      reason: `${delegates.length} delegates, but they do not split into a Juliet task AND a `
        + `separate Romeo task (tasks=${JSON.stringify(tasks.map((t) => t.slice(0, 60)))}). Trace: [${names}]`,
    };
  }

  // --- Spoiler hygiene: the reader did NOT ask to read ahead ------------------------
  // Same reflex check as DEL1: a whole-book portrait is fine, but setting allow_spoiler
  // without being asked is the wrong instinct. At this start_page the reader is already
  // at the end so nothing leaks — worth a soft ding, not a hard fail.
  if (delegates.some((d) => d.input && d.input.allow_spoiler === true)) {
    return {
      pass: true,
      score: 0.7,
      reason: `fanned out into a Juliet delegate and a Romeo delegate (good) but one set `
        + `allow_spoiler=true unprompted. Trace: [${names}]`,
    };
  }

  return {
    pass: true,
    score: 1,
    reason: `fanned out into ${delegates.length} delegates: a Juliet portrait (#${jIdx + 1}) and a `
      + `Romeo portrait (#${rIdx + 1}). Trace: [${names}]`,
  };
};
