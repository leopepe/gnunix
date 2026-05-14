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

1. **Start minimal.** Do not preload all documentation. Identify the topic of the user's request first.
2. **Match the topic** to the table above and load only the files needed.
3. **Cross-topic requests:** If a request spans multiple topics (e.g., "why does the deploy runbook do X?"), load files from each relevant topic (the runbook + the related ADR + `architecture.md` if needed).
4. **Prefer specific files over directories.** When loading from `adrs/` or `runbooks/`, list the directory first, then load only the specific files whose names match the topic.
5. **Re-load on topic shift.** If the conversation shifts to a new topic, load the new topic's files rather than relying on prior context.

### Authoring New Documentation

- **New ADR:** Place in `adrs/` following the existing naming and format conventions. Reference any superseded ADRs.
- **New runbook:** Place in `runbooks/` with a clear, action-oriented filename (e.g., `restart-service.md`).
- **Architecture changes:** Update `architecture.md` and, if the change reflects a decision, add a corresponding ADR.

### Conventions

- Always cite the specific file (and section, if applicable) when answering based on loaded documentation.
- If documentation appears stale or contradicts observed code/behavior, flag it to the user rather than silently reconciling.
- When proposing changes that conflict with an existing ADR, explicitly call out the conflict and suggest either following the ADR or superseding it.
