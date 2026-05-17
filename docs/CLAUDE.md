# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Context Loading Instructions

This repository contains reference documentation organized by topic. Load the relevant files **only when the user's request relates to the corresponding topic** to keep context focused and minimal.

### Topic-Based File Loading

| Topic / Trigger | Files to Load | When to Load |
|---|---|---|
| **Architecture, system design, components, services, data flow, high-level structure** | `architecture.md` | Load when the user asks about how the system is structured, component boundaries, service interactions, technology choices, or any high-level design questions. |
| **Architectural decisions, rationale, trade-offs, "why was X chosen", historical context** | All files under `adrs/` | Load when the user asks why a particular decision was made, wants to understand trade-offs, proposes changes that may conflict with prior decisions, or is authoring a new ADR. Prefer loading only the specific ADR(s) relevant to the topic; load the full directory only if the relevant ADR is unknown. |
| **Operations, incidents, troubleshooting, on-call, deployments, recovery procedures** | Relevant files under `runbooks/` | Load when the user asks how to operate, debug, deploy, recover, or respond to an incident. Load only the runbook(s) matching the specific operational task. |

### Loading Strategy

0. **MemPalace first for searches.** If the question can be answered with a focused excerpt rather than a whole-file load (*"what does ADR-NNN say about X?"*, *"where is Y documented?"*, *"find references to Z"*), query the MemPalace MCP server (`mcp__mempalace__*` tools) before opening any file. The palace is a local index of `docs/` (ADRs, runbooks, architecture) plus the CLAUDE.md hierarchy; one query returns a ~600–900-token excerpt instead of pulling whole ADRs into the context window. Fall back to file `Read` only when the answer truly needs whole-file context, when you already know the exact path, or when you need the *current* state rather than the last-synced snapshot. See `CLAUDE.md § Searching documentation with MemPalace` for the full guidance.
1. **Start minimal.** Do not preload all documentation. Identify the topic of the user's request first.
2. **Match the topic** to the table above and load only the files needed.
3. **Cross-topic requests:** If a request spans multiple topics (e.g., "why does the deploy runbook do X?"), load files from each relevant topic (the runbook + the related ADR + `architecture.md` if needed).
4. **Prefer specific files over directories.** When loading from `adrs/` or `runbooks/`, list the directory first, then load only the specific files whose names match the topic.
5. **Re-load on topic shift.** If the conversation shifts to a new topic, load the new topic's files rather than relying on prior context.

### Authoring New Documentation

- **New ADR:** Place in `adrs/` following the existing naming and format conventions. Reference any superseded ADRs. **Whenever a new ADR is created — or an existing one is amended, superseded, or status-changed — you MUST run the [ADR → Architecture sync workflow](#adr--architecture-sync-workflow) before considering the task complete.**
- **New runbook:** Place in `runbooks/` with a clear, action-oriented filename (e.g., `restart-service.md`).
- **Architecture changes:** Update `architecture.md` and, if the change reflects a decision, add a corresponding ADR. Architecture edits that are not backed by an ADR should be flagged to the user before being written.

### ADR → Architecture sync workflow

This workflow is **mandatory** whenever ADRs change — i.e. on any of:

- A new file added under `adrs/`.
- An existing ADR moving from `Proposed` → `Accepted`, `Accepted` → `Superseded`, or any other status transition.
- An ADR amended in-place (rationale, decision, or consequences edited).
- An ADR explicitly superseding one or more prior ADRs.

Do **not** open the editor on `architecture.md` until steps 1–3 below are complete. The goal is that `architecture.md` is always a *compiled, summarised projection of the current set of accepted ADRs* — never a hand-authored narrative that drifts from them.

**1. Scan all ADRs.** List `adrs/` and read every ADR file (not just the one being added). For each, extract: ID, title, status, the decision in one sentence, and any ADRs it supersedes or is superseded by. Build a mental table of `(ID, status, decision, supersedes, superseded-by)`.

**2. Detect inconsistencies.** Cross-check the table for:

   - **Contradictions** — two `Accepted` ADRs that mandate incompatible choices (e.g., one locks decision X, another silently relies on not-X).
   - **Dangling supersessions** — an ADR claims to supersede another, but the superseded ADR is still marked `Accepted`.
   - **Orphaned amendments** — an ADR has been amended without a follow-up note in the ADRs it amends.
   - **Architecture drift** — claims in `architecture.md` that no `Accepted` ADR supports, or `Accepted` ADRs whose decisions are not reflected in `architecture.md`.
   - **Status gaps** — `Proposed` ADRs that the codebase already depends on, or `Accepted` ADRs that the codebase contradicts.

   Report every inconsistency found to the user **before** writing anything. Do not silently "reconcile" by picking a winner; surface the conflict and ask which ADR is authoritative, or whether a new superseding ADR is needed.

**3. Propose the architecture delta.** Once inconsistencies are resolved (or explicitly deferred by the user), produce a short proposal containing:

   - The list of ADRs that are now in force (with IDs and one-line decisions).
   - The concrete sections of `architecture.md` that will be added, changed, or removed.
   - The concrete changes to the architecture diagram (nodes/edges added, removed, relabeled).
   - Any follow-up ADRs or runbooks the user should consider.

   Wait for user confirmation on the proposal before proceeding to step 4. For trivial ADRs that affect only wording, a one-line proposal is fine, but it must still be shown.

**4. Update `architecture.md`.** Rewrite the affected sections so that the document reads as a *compiled summary* of all currently-accepted ADRs:

   - Every load-bearing claim cites the ADR ID(s) it derives from (e.g. "sysvinit + BSD `/etc/rc.d/` (ADR-001)").
   - Superseded ADRs are not cited as current rationale; they may appear only in a clearly labelled "History" subsection.
   - The document stays concise — it summarises, it does not duplicate ADR prose. If a reader wants rationale, they follow the ADR link.

**5. Update the architecture diagram.** Keep the diagram source-controlled and co-located with `architecture.md` (inline Mermaid in the doc, or a sibling file referenced from it — whichever the doc already uses). Regenerate it so that:

   - Each component / boundary corresponds to a decision in an accepted ADR.
   - The diagram caption or legend lists the ADR IDs that govern the depicted structure.
   - No node or edge exists that is not backed by an ADR or by `architecture.md` body text.

**6. Cross-link.** In the new/changed ADR, add a line like `Architecture impact: see architecture.md §<section>.` In `architecture.md`, link to the ADR by ID. Bidirectional links are required so future scans (step 1) can follow them.

**7. Validate.** Before declaring done:

   - Re-read `architecture.md` end-to-end and confirm every load-bearing statement maps to an `Accepted` ADR.
   - Confirm the diagram renders (if it's Mermaid, paste it through a renderer mentally or via tooling).
   - Confirm no `Accepted` ADR is unmentioned in `architecture.md` unless it is purely operational (in which case it belongs in a runbook, not the architecture doc).

If any step in this workflow cannot be completed (e.g., the user defers a conflict), stop and leave `architecture.md` in its previous state rather than committing a half-synced version. Partial syncs are worse than stale docs because they hide the drift.

### Conventions

- Always cite the specific file (and section, if applicable) when answering based on loaded documentation.
- If documentation appears stale or contradicts observed code/behavior, flag it to the user rather than silently reconciling.
- When proposing changes that conflict with an existing ADR, explicitly call out the conflict and suggest either following the ADR or superseding it.
- Treat `architecture.md` as a derived artifact of the `adrs/` set. If you find yourself editing `architecture.md` without a corresponding ADR change, stop and ask whether an ADR is missing.
