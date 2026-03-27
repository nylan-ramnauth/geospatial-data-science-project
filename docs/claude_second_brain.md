# The Second Brain Stack
## Claude as a Persistent, All-Knowing Research Supervisor

> A design blueprint for using Claude Code + Obsidian + Git to eliminate context loss across
> sessions, team members, and time — achieving AI-assisted productivity, genuine collaboration,
> and full scientific reproducibility. Designed as a test case for a master thesis, scalable to
> any research group.

---

## 1. The Problem

Research projects — especially master theses or multi-month computational pipelines — suffer from
a universal set of failures:

- **Context loss between sessions:** you remember why you made a decision last week, Claude doesn't
- **Context loss across teammates:** your collaborator doesn't know what you tried and abandoned, or why
- **Reproducibility decay:** six months later, nobody remembers *why* the pipeline works the way it does — only *that* it does
- **Scattered knowledge:** decisions live in Slack, code comments, email threads, and memory — never in one place
- **AI that forgets:** every Claude session starts from zero, re-explaining the same context repeatedly

Claude is powerful but stateless. The Second Brain Stack solves this by making the *project itself*
the memory — persistent, versioned, shared, and queryable by Claude at any time.

---

## 2. The Core Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        OBSIDIAN VAULT                             │
│              (shared team brain — single source of truth)         │
│                                                                    │
│  meetings/  research/  decisions/  hypotheses/  drafts/           │
│  docs/      team/      interface/  claude_memory/                 │
└────────────────────────────┬─────────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │ Option A: MCP (live access)  │  Option B: sync script
              │ Claude reads/writes vault    │  git pull → rsync → memory/
              └──────────────┬──────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────────┐
│                      CLAUDE CODE SESSION                          │
│         All-knowing supervisor with full project context          │
│                                                                    │
│   Knows: decisions made, hypotheses, who does what, blockers,     │
│   literature, package docs, pipeline details, thesis narrative     │
└──────────────────────────────────────────────────────────────────┘
```

**Key principle:** The Obsidian vault is the single source of truth.
Claude reads from it. Humans write to it. Git keeps it synced across teammates.

---

## 3. Repository Structure

### The Workspace (local only, not a git repo)

```
~/thesis/
├── CLAUDE.md                  ← workspace-level brief (cross-project reasoning)
├── thesis-brain/              ← git repo → github.com/team/thesis-brain
├── thesis-viirs/              ← git repo → github.com/team/thesis-viirs
│   ├── CLAUDE.md              ← project-level brief (VIIRS coding)
│   └── .claude/
│       ├── mcp.json           ← MCP config (committed, shared)
│       └── skills/            ← custom slash commands (committed, shared)
└── thesis-pypsa/              ← git repo → github.com/team/thesis-pypsa
    ├── CLAUDE.md              ← project-level brief (PyPSA coding)
    └── .claude/
        ├── mcp.json
        └── skills/
```

### When to open Claude where

| Context | Open Claude in | CLAUDE.md loaded |
|---|---|---|
| Cross-project thinking, planning, writing | `~/thesis/` | workspace-level |
| Coding VIIRS pipeline | `~/thesis/thesis-viirs/` | VIIRS project-level |
| Coding PyPSA model | `~/thesis/thesis-pypsa/` | PyPSA project-level |

> **Rule:** workspace level = thinking mode. Project level = coding mode.
> Workspace Claude can read across both repos but should not edit code or run git operations.

### What gets pushed where

| File | Pushed? | Repo |
|---|---|---|
| `~/thesis/CLAUDE.md` | No (local paths) | — |
| `thesis-viirs/CLAUDE.md` | Yes | thesis-viirs |
| `thesis-pypsa/CLAUDE.md` | Yes | thesis-pypsa |
| `.claude/mcp.json` | Yes | each code repo |
| `.claude/skills/` | Yes | each code repo |
| `thesis-brain/` everything | Yes | thesis-brain |

---

## 4. The Brain Repo — Full Structure

```
thesis-brain/
├── .obsidian/                        ← Obsidian config (commit selectively)
│
├── 00_Hub/
│   ├── HOME.md                       ← Obsidian home note (dashboard)
│   ├── project_brief.md              ← one-page thesis summary (stable)
│   ├── timeline.md                   ← milestones, deadlines, submission date
│   └── thesis_narrative.md           ← the scientific story connecting both projects
│
├── 01_Meetings/
│   ├── YYYY-MM-DD_supervisor.md
│   ├── YYYY-MM-DD_team.md
│   └── _template_meeting.md
│
├── 02_Research/
│   ├── literature/
│   │   ├── _template_paper.md        ← standard note format for papers
│   │   ├── Elvidge2017_VIIRS.md
│   │   └── reading_list.md
│   ├── datasets/
│   │   ├── VIIRS_VNP46A2.md          ← dataset card: what, where, how used
│   │   └── PyPSA_Earth_inputs.md
│   ├── docs/                         ← package documentation (uploaded directly)
│   │   ├── pypsa/
│   │   │   ├── components.md
│   │   │   ├── optimization.md
│   │   │   └── network_api.md
│   │   ├── pypsa-earth/
│   │   │   ├── config_reference.md   ← config.yaml full reference
│   │   │   ├── workflow.md
│   │   │   └── troubleshooting.md
│   │   └── blackmarbler/
│   │       └── api_reference.md
│   └── findings/
│       └── cloud_coverage_eastern_cape.md
│
├── 03_Decisions/                     ← Architecture Decision Records (ADR)
│   ├── _template_adr.md
│   ├── viirs/
│   │   ├── ADR_001_coverage_threshold.md
│   │   ├── ADR_002_doe_rolling_window.md
│   │   └── ADR_003_local_vs_supply_area.md
│   └── pypsa/
│       ├── ADR_001_network_resolution.md
│       └── ADR_002_solver_choice.md
│
├── 04_Hypotheses/                    ← research hypotheses, tracked over time
│   ├── H1_uptime_near_grid.md        ← status: CONFIRMED
│   ├── H2_doe_predicts_load.md       ← status: OPEN
│   └── H3_cloud_bias_coast.md        ← status: REJECTED (why)
│
├── 05_Interface/                     ← how VIIRS and PyPSA connect (key layer)
│   ├── data_handoff.md               ← what VIIRS outputs PyPSA consumes
│   ├── shared_assumptions.md         ← assumptions both models share
│   └── validation_plan.md            ← how to cross-validate results
│
├── 06_Drafts/
│   ├── thesis_outline.md
│   ├── ch1_introduction.md
│   ├── ch2_viirs_methods.md
│   ├── ch3_pypsa_methods.md
│   └── ch4_results.md
│
├── 07_Team/
│   ├── nylan.md                      ← role, expertise, current focus, preferences
│   ├── teammate.md
│   └── norms.md                      ← team conventions, communication rules
│
└── 08_Claude_Memory/                 ← machine-readable layer (Claude reads this)
    ├── MEMORY.md                     ← index — Claude reads this first every session
    ├── project_viirs.md              ← pipeline stages, scripts, data paths (R)
    ├── project_pypsa.md              ← model structure, paths, methodology (Python)
    ├── interface.md                  ← how the two projects connect
    ├── decisions.md                  ← condensed ADR log for Claude
    ├── hypotheses.md                 ← hypothesis tracker for Claude
    ├── blockers.md                   ← current open problems
    ├── team.md                       ← who does what, expertise, preferences
    ├── reproducibility_viirs.md      ← step-by-step reproduction guide
    ├── reproducibility_pypsa.md
    └── sessions/
        ├── _template_session.md
        ├── 2026-03-25_nylan.md
        └── 2026-03-25_teammate.md
```

---

## 5. Key Templates

### ADR Template (`03_Decisions/_template_adr.md`)

```markdown
# ADR_XXX — [Decision Title]

**Date:** YYYY-MM-DD
**Author:** [name]
**Status:** ACCEPTED | SUPERSEDED BY ADR_YYY | UNDER REVIEW

## Decision
[One sentence: what was decided]

## Context
[Why this decision needed to be made]

## Alternatives considered
- Option A: [description] → rejected because [reason]
- Option B: [description] → rejected because [reason]

## Rationale
[Why this option was chosen over alternatives]
Evidence: [sensitivity sweep / literature / supervisor input]

## Consequences
[What this decision affects downstream]

## Code location
[script name, line number(s)]

## Linked hypothesis
[H1, H2, ... if applicable]
```

### Paper Note Template (`02_Research/literature/_template_paper.md`)

```markdown
# [Author YYYY] — [Title]

**Citation key:** author_YYYY (Zotero key)
**Journal/Venue:**
**Tags:** #[tag1] #[tag2]

## Abstract
[auto-imported from Zotero via ZotLit]

## Relevance to thesis
-

## Key findings
-

## Methodology notes
-

## Quotes
>

## Disagreements / limitations
-

## Links to decisions
→ ADR_XXX: [how this paper justifies that decision]

## Links to hypotheses
→ H1: [supports / contradicts / irrelevant]
```

### Session Log Template (`08_Claude_Memory/sessions/_template_session.md`)

```markdown
# Session YYYY-MM-DD — [Name] — [Project: VIIRS | PyPSA | Both]

## What I worked on
-

## Decisions made (→ create ADR if non-trivial)
-

## What I tried and abandoned (and why)
-

## Hypotheses updated
-

## Current state
-

## For my teammate
-

## Blockers / open questions
-

## Next session plan
-
```

### Hypothesis Template (`04_Hypotheses/`)

```markdown
# H[N] — [Hypothesis statement]

**Status:** OPEN | CONFIRMED | REJECTED | PARTIALLY CONFIRMED
**Owner:** [name]
**Opened:** YYYY-MM-DD
**Closed:** YYYY-MM-DD (if applicable)

## Statement
[Clear, falsifiable claim]

## Why we think this
[Prior reasoning, literature support]

## Evidence FOR
-

## Evidence AGAINST
-

## How to test
[Method, script, expected output]

## Result
[When confirmed/rejected: what we found and where]

## Links
- ADR: ADR_XXX
- Literature: [paper notes]
- Code: [script:line]
```

---

## 6. The CLAUDE.md Files

### Workspace-level (`~/thesis/CLAUDE.md`)

```markdown
# Thesis Workspace — Claude Supervisor Brief

You are a senior research supervisor with full knowledge of this thesis.
This workspace contains two interconnected computational projects:

- thesis-viirs/  — VIIRS night-light reliability pipeline (R)
- thesis-pypsa/  — PyPSA-Earth energy capacity model (Python)

## In this mode (workspace level)
You are in THINKING and PLANNING mode, not coding mode.
- Do not edit code files directly
- Help reason across both projects simultaneously
- Review the thesis narrative, cross-project decisions, interface design
- Help write thesis drafts, plan next steps, resolve conflicts between projects
- Challenge assumptions — ask why before accepting

## Always read first (via MCP or memory)
1. 08_Claude_Memory/MEMORY.md
2. 08_Claude_Memory/interface.md
3. 05_Interface/thesis_narrative.md
4. 08_Claude_Memory/hypotheses.md
5. Sessions from the last 3 days (both teammates)

## Brain vault
$OBSIDIAN_VAULT

## The scientific bridge
VIIRS produces settlement-level electrification reliability metrics →
PyPSA-Earth consumes these as demand/load inputs →
Together they answer: [thesis research question]

## Team
- Nylan: [role, focus]
- Teammate: [role, focus]
```

### Project-level (`thesis-viirs/CLAUDE.md`)

```markdown
# VIIRS Pipeline — Claude Supervisor Brief

You are supervising the VIIRS night-light pipeline (R).
The full project brain (including PyPSA context) is at $OBSIDIAN_VAULT.

## Before implementing anything
1. Check 08_Claude_Memory/decisions.md — has this been tried?
2. Check 08_Claude_Memory/interface.md — does this affect PyPSA inputs?
3. Check 08_Claude_Memory/blockers.md — is this related to a known blocker?

## Reproducibility standard (enforce always)
Every non-obvious parameter or design choice must have:
- An ADR in 03_Decisions/viirs/
- A code comment referencing it: # See ADR_001

## On session start
Read memory, then ask: "What are you working on today?"

## On session end
Run /session-close to write the session log and push the brain.

## Key rules
- Yellow = good on all choropleth maps (enforced convention)
- Coverage filter ≥ 0.50 (ADR_001, do not change without new ADR)
- DOE: 30-day window, ≥8 lit, ≥15 observed (ADR_002)
- Local area is the reporting unit, not supply area (ADR_003)
- Before changing any output format: check interface.md

## Pipeline stages
[See 08_Claude_Memory/project_viirs.md]
```

---

## 7. Zotero Integration

```
Zotero (PDF + metadata)
    ↓ ZotLit plugin (Obsidian)
02_Research/literature/ (annotated notes)
    ↓ MCP
Claude (reads notes, cites correctly, flags gaps)
```

**ZotLit** (recommended Obsidian plugin) creates a note per paper automatically from your
Zotero library. You add: relevance, key findings, links to decisions and hypotheses.

**What Claude gains:** the ability to cite correctly mid-session, flag unsupported claims in
thesis drafts, and link methodology choices back to literature — all from your own annotated notes.

**Discipline required:** 10 minutes per paper to fill in the note template. The quality of
Claude's literature knowledge = the quality of your notes.

---

## 8. Package Documentation in the Brain

Upload documentation directly to `02_Research/docs/`. Claude then reasons across your code
*and* the package docs simultaneously.

**Priority docs to upload:**

| Document | Why |
|---|---|
| PyPSA-Earth `config.yaml` reference | Touched constantly |
| PyPSA network components API | Core objects |
| PyPSA-Earth workflow + Snakemake | How stages connect |
| Solver docs (HiGHS, Gurobi) | Debugging runs |
| VIIRS VNP46A2 user guide | Data quality flags |
| BlackMarble technical notes | Band definitions |

**Version-pin your docs:** rename uploaded files with the version:
`pypsa_earth_config_v0.5.md` — so Claude knows which version's behavior to expect.

---

## 9. The Interface Layer (`05_Interface/`)

The scientific bridge between VIIRS and PyPSA is **the most novel part of the thesis**.
It must be explicitly managed:

```markdown
# 05_Interface/data_handoff.md

## What VIIRS produces for PyPSA

| File | Content | Location |
|------|---------|----------|
| localarea_reliability_yearly_*.parquet | Uptime by local area | reliability_outputs_blackmarbler/ |
| yearly_settlement_stats_2023.parquet | Electrified settlement flags | same |

## What PyPSA expects
- Load profiles scaled by uptime (lower uptime → higher unserved energy)
- Electrification rate per network node (from electrified_best flag)
- Demand growth assumptions validated against VIIRS trends

## Conversion script
[script name + location]

## Shared assumptions (see shared_assumptions.md)
- Population data: DRE Atlas (both models)
- Geographic resolution: local area (42 Eskom areas)
- Year: 2023

## Validation
- [ ] VIIRS uptime correlates with PyPSA load shedding output
- [ ] Electrification rates consistent across both models
```

---

## 10. Novel Capabilities — Beyond Standard Documentation

### The Contradiction Engine
Claude checks every new decision against `decisions.md` before implementing:
> "You're proposing to change the coverage threshold to 0.3. ADR_001 documents that 0.25 was
> tried and rejected — sensitivity sweep showed it introduced significant noise.
> Do you have new evidence that changes this?"

### The Hypothesis Tracker
`04_Hypotheses/` + `08_Claude_Memory/hypotheses.md` gives Claude a live view of the
research's intellectual status. At thesis-writing time, Claude can draft the Results section
narrative directly from confirmed/rejected hypotheses with linked evidence.

### The Stranger Test
Claude periodically audits: *"Can a stranger reproduce this from scratch?"*
- Every script has a header explaining inputs/outputs
- Every non-obvious parameter has an ADR
- Every hardcoded value has a documented rationale
- All data sources are accessible
- Environment is fully specified

### Supervisor Meeting Prep
Before every supervisor meeting, `/supervisor-prep` generates:
- Progress since last meeting (from session logs)
- Decisions made and rationale
- Hypotheses confirmed/rejected
- Current blockers
- Proposed agenda + questions to ask

### Code-to-Brain Linking
Inline comments link code to ADRs:
```r
MIN_COVERAGE <- 0.50  # ADR_001: 0.5 minimises bias, see thesis-brain/03_Decisions/viirs/
```
Claude can trace from any code decision back to its full rationale, and from any ADR to the
exact lines that implement it.

### The Living Methods Section
By submission time, the brain *is* the methods section:
- Decisions → methodology justification
- Hypotheses → results narrative
- Literature notes → related work + citations
- Reproducibility docs → supplementary material
- Session logs → acknowledgement of what was tried

Claude can draft any thesis chapter by reading the brain — not from scratch.

---

## 11. Skills (Custom Slash Commands)

Skills are prompt templates committed to `.claude/skills/` and shared via git.
Every teammate gets them automatically on clone.

### Skills to Build

#### `/session-open`
Reads the 3 most recent session logs, summarises what happened, flags blockers,
and asks what you're working on today. Sets Claude's context for the session.

```
You are starting a new session. Read the last 3 session logs from
08_Claude_Memory/sessions/ and:
1. Summarise what was done recently (both teammates)
2. Flag any open blockers from blockers.md
3. Note any decisions pending documentation
4. Ask: "What are you working on today?"
```

#### `/session-close`
Prompts for session summary, writes the session log to the brain,
updates blockers.md if needed, then commits and pushes.

```
The session is ending. Ask the user:
- What did we work on today?
- What decisions were made? (should these become ADRs?)
- What was tried and abandoned?
- What should the teammate know?
- What are the blockers?

Then write a session log to 08_Claude_Memory/sessions/YYYY-MM-DD_[name].md,
update blockers.md, and offer to git commit + push the brain.
```

#### `/adr [title]`
Creates a new Architecture Decision Record from the template,
pre-filled with today's date and author, opened in editor.

#### `/supervisor-prep`
Reads session logs since the last supervisor meeting,
generates a structured meeting agenda with progress summary,
decisions made, results, blockers, and questions to ask.

#### `/stranger-test`
Audits the codebase for reproducibility gaps:
- Missing script headers
- Undocumented parameters
- ADR-less design choices
- Missing data source docs
- Unspecified package versions

#### `/hypothesis [new|update] [H_number]`
Creates or updates a hypothesis note from the template,
syncs status to `08_Claude_Memory/hypotheses.md`.

#### `/contradiction-check [description]`
Before implementing a change, Claude searches `decisions.md` and all ADRs
for conflicts with the proposed change. Reports any contradictions found.

#### `/thesis-draft [section]`
Drafts a thesis section (methods, results, discussion) by reading the
relevant brain layers: decisions → methods, hypotheses → results,
literature notes → related work. Returns a draft with inline citation keys.

#### `/sync-brain`
Runs `git pull` on the brain repo and syncs memory files.
Useful if MCP is not set up and you want to manually refresh context.

#### `/decisions-audit`
Scans recent git commits in the code repo and checks whether
each non-trivial change has a corresponding ADR. Lists gaps.

---

## 12. Community Skills and MCP Servers

### Claude Code Built-in Skills
- `/commit` — smart commit message generation (built-in)
- `/review-pr` — pull request review (built-in)

### MCP Servers (community)

| Server | What it gives Claude | Link |
|---|---|---|
| `mcp-obsidian` | Live read/write access to the Obsidian vault | MarkusPfundstein/mcp-obsidian |
| `zotero-mcp` | Direct Zotero library access (search, cite) | emerging, check community |
| `github-mcp` | Read issues, PRs, commits across repos | github/github-mcp-server |
| `filesystem-mcp` | Read files outside the code repo | built into Claude |
| `sequential-thinking` | Forces Claude to think step-by-step before acting | modelcontextprotocol/servers |
| `memory-mcp` | Alternative persistent memory (graph-based) | modelcontextprotocol/servers |
| `brave-search` | Web search for Claude during session | brave/brave-search-mcp |

### MCP Config (committed to each code repo)

```json
// .claude/mcp.json
{
  "mcpServers": {
    "obsidian": {
      "command": "mcp-obsidian",
      "args": ["--vault", "${OBSIDIAN_VAULT}"],
      "description": "Team brain — decisions, meetings, literature, hypotheses"
    },
    "github": {
      "command": "github-mcp",
      "env": { "GITHUB_TOKEN": "${GITHUB_TOKEN}" },
      "description": "Cross-repo issue and PR context"
    }
  }
}
```

---

## 13. Day-to-Day Workflow

### Session Start

```bash
# Morning ritual (one alias)
alias research="cd ~/thesis/thesis-viirs && git pull && claude"
```

Claude (via `/session-open` or CLAUDE.md instructions):
> "Last session (2026-03-25, Nylan): finished report Rmd, 18 pages compiling.
> Teammate is working on PyPSA config calibration — blocked on solver timeout.
> Open hypothesis: H2 (DOE predicts PyPSA load) — not yet tested.
> What are you working on today?"

### During Session

- Propose change → Claude checks `decisions.md` for conflicts
- Write code → Claude suggests ADR comment reference
- Get stuck → Claude checks `troubleshooting.md` in package docs
- Make a key finding → Claude updates hypothesis status

### Session End

```bash
/session-close
# → Claude writes session log
# → Updates blockers.md
# → git commit -m "session: 2026-03-26 nylan" && git push
```

Teammate pulls next morning → their Claude knows everything.

---

## 14. Teammate Onboarding (Complete)

```bash
# 1. Clone all three repos
mkdir ~/thesis && cd ~/thesis
git clone github.com/team/thesis-brain
git clone github.com/team/thesis-viirs
git clone github.com/team/thesis-pypsa

# 2. Set environment variables (once, in ~/.zshrc)
echo 'export OBSIDIAN_VAULT="$HOME/thesis/thesis-brain"' >> ~/.zshrc
echo 'export GITHUB_TOKEN="your_token_here"' >> ~/.zshrc
source ~/.zshrc

# 3. Install MCP server (once)
npm install -g mcp-obsidian

# 4. Open Obsidian → add vault → thesis-brain/

# 5. Install ZotLit in Obsidian, connect to Zotero

# 6. Start working
cd ~/thesis/thesis-viirs && claude
```

One setup. Full context from day one. No explaining the project to Claude.

---

## 15. Scalability — From Thesis to Research Group

The system is designed as a **template**, not a one-off solution.

### The Empty Template Repo

```
github.com/[you]/research-brain-template/
├── README.md          ← how to use this template
├── 00_Hub/
├── 01_Meetings/
├── 02_Research/
├── 03_Decisions/
├── 04_Hypotheses/     ← novel addition vs standard PKM
├── 05_Interface/      ← novel addition for multi-model projects
├── 06_Drafts/
├── 07_Team/
└── 08_Claude_Memory/
    └── _template_*.md
```

Any research group clones this, fills in their project, and gets:
- Persistent Claude memory from day one
- ADR discipline built into the workflow
- Reproducibility as a first-class concern
- Hypothesis tracking from the start

### What Makes This Novel (vs existing tools)

| Existing approaches | This system |
|---|---|
| Documentation written at the end | Knowledge captured continuously |
| "What does this do?" | "Why does it do this, and what was tried first?" |
| Claude forgets between sessions | Claude remembers everything via brain |
| Reproducibility = README | Reproducibility = living time capsule |
| Tools are separate (Obsidian, Zotero, Claude) | One integrated knowledge infrastructure |
| ADRs used in software only | ADRs applied to scientific methodology |
| Hypothesis tracking in lab notebooks | Hypothesis tracking queryable by AI |

---

## 16. Reproducibility — The Time-Capsule Property

**Goal:** 12 months from now, a stranger (or reviewer, or future you) can:
1. Understand *why* every decision was made
2. Reproduce the full pipeline from raw data to final figures
3. See what was tried and failed (no duplicate effort)
4. Read the scientific reasoning that produced the thesis

### Layers of reproducibility

| Layer | Tool | What it captures |
|---|---|---|
| Code | Git | What changed and when |
| Environment | `renv.lock` / `requirements.txt` | Exact package versions |
| Data | `DATA.md` + Google Drive links | Where to get every input |
| Decisions | ADRs + `decisions.md` | Why the code is the way it is |
| Attempts | Session logs | What was tried and failed |
| Science | Hypotheses | What was believed and whether it held |
| Instructions | `reproducibility.md` | Step-by-step for a stranger |
| Narrative | Thesis drafts in `06_Drafts/` | The human story |

No single layer is sufficient. The whole system together is the time capsule.

---

## 17. Stack Summary

| Component | Tool | Purpose |
|---|---|---|
| Knowledge base | Obsidian | Human-readable team brain |
| Literature | Zotero + ZotLit | Papers → annotated notes in brain |
| Package docs | Markdown files in brain | Claude knows the APIs you use |
| Version control | Git (3 separate repos) | Sync across machines + teammates |
| Live AI access | MCP (mcp-obsidian) | Claude reads/writes vault directly |
| Reproducibility | ADRs + hypotheses + session logs | Time-capsule for future self |
| Workflow automation | Custom skills (slash commands) | Zero-friction rituals |
| Code entry point | `CLAUDE.md` per repo | Claude's behavioral brief |
| Cross-project reasoning | Workspace `CLAUDE.md` | Interface + thesis narrative |

---

*The marginal cost of maintaining this system: 10–15 minutes per session.
The compounding benefit over 12 months: a thesis that is fully reproducible, fully documented,
and whose entire reasoning process is queryable by an AI supervisor — or by a peer reviewer,
or by your future self.*

*This is not a productivity tool. It is knowledge infrastructure for science.*

---

## 18. Questions to Answer Before Building This

Your answers will determine the exact vault structure, which skills to prioritise,
how Claude should behave, and whether the system is realistic to maintain.
Answer these before writing a single file.

---

### A. The Project and Science

1. **What is the exact research question your thesis is trying to answer?**
   *(One sentence if possible. This becomes the anchor of the whole brain.)*

2. **How do VIIRS and PyPSA connect scientifically?**
   Does VIIRS output feed into PyPSA as an input, validate its results, or both?
   What is the causal/methodological link?

3. **What would a successful thesis look like?**
   A published paper? A reproducible pipeline others adopt? A policy recommendation?
   *(This shapes what "done" means and how Claude should prioritise.)*

4. **What are your 3 main research hypotheses right now?**
   Even rough ones. These become the `04_Hypotheses/` starting point.

5. **What is the biggest scientific uncertainty you face today?**
   The thing you don't know yet that the thesis depends on.

---

### B. The Team and Collaboration

6. **Who is your teammate — what is their role, technical background, and focus?**
   *(Determines how to structure `07_Team/` and how Claude should calibrate its advice
   between the two of you.)*

7. **How do you currently communicate as a team?**
   WhatsApp, Slack, email, in-person? Where do decisions currently get made and lost?

8. **Do you work on the same code, or do you each own different parts?**
   *(Determines whether you need branch protection, PR reviews, or clear ownership rules.)*

9. **How often do you work on the project together vs independently?**
   *(Shapes session log frequency and the teammate notification layer.)*

10. **Is your supervisor involved in day-to-day decisions, or only at milestones?**
    How often do you meet? Does the supervisor need to see the brain, or is it internal?

---

### C. The Codebase and Pipeline

11. **What is the current state of each codebase?**
    VIIRS: is the pipeline finished, in progress, or just starting?
    PyPSA: same question.

12. **What are the biggest technical risks in each project?**
    The thing most likely to break, fail, or take 3× longer than expected.

13. **Are there parts of the pipeline you don't fully understand yet?**
    *(These become the first entries in `blockers.md` and shape which package docs
    to prioritise uploading to the brain.)*

14. **What tools and languages does each project use?**
    R / Python / Julia? Which specific packages are central?
    *(Determines which package docs to put in `02_Research/docs/`.)*

15. **Do you use any existing project management tools?**
    GitHub Issues, Notion, Linear, Trello? Or nothing?
    *(Determines whether to integrate with GitHub MCP or keep it self-contained.)*

---

### D. Reproducibility Goals

16. **Who is the intended audience for reproducibility?**
    Just you in 6 months? A peer reviewer? Other researchers who want to reuse the pipeline?
    *(A peer reviewer needs a different level of documentation than future-you.)*

17. **Is there a publication plan?**
    Journal paper? Conference? Open-source release?
    *(A journal submission requires reproducibility standards that shape what must be documented.)*

18. **How are you handling data that can't be pushed to GitHub?**
    Google Drive, Zenodo, institutional storage?
    *(The `DATA.md` and `reproducibility.md` structure depends on this.)*

19. **Do you use environment management tools?**
    `renv` for R? `conda`/`venv` for Python? Docker?
    *(If not yet: should you start? This is a good moment.)*

---

### E. Workflow and Habits

20. **How long is a typical work session on the thesis?**
    1 hour? Half a day? Full day?
    *(Determines how lightweight the session-open/close ritual needs to be.)*

21. **What time of day do you typically work on this?**
    *(Helps design the `/morning` or `/session-open` skill appropriately.)*

22. **How disciplined are you and your teammate about documentation?**
    Honest answer. Will you actually write session logs, or will it feel like overhead?
    *(Determines whether to make logging automatic via Claude, or keep it manual.)*

23. **Have you used Obsidian before?**
    If not: are you comfortable learning it, or would a simpler folder structure work better?

24. **What would make you abandon this system after 2 weeks?**
    *(Design against that answer. Friction kills good systems.)*

---

### F. The Brain's Scope

25. **Should the brain include your thesis writing (drafts, outlines)?**
    Or keep it purely technical (decisions, code, data)?

26. **Should meeting notes with your supervisor live in the brain?**
    Or are those kept separately?

27. **Is Zotero already set up with your references?**
    How many papers do you currently have? Is your library well-organised?

28. **Which package documentation is most urgently needed in the brain?**
    Rank: PyPSA, PyPSA-Earth, Snakemake, BlackMarbler, other.

29. **Do you want the brain to eventually be made public** (e.g. as a template repo
    or supplementary material for a paper)? Or is it permanently internal?
    *(Affects what you write — public-facing notes are written differently.)*

---

### G. Claude's Behaviour

30. **What tone do you want Claude to take as a supervisor?**
    Challenging and direct? Collaborative and exploratory? Somewhere in between?

31. **What would feel like overreach?**
    Things you don't want Claude to weigh in on, even if it has context.

32. **Should Claude ever push back on a direction your supervisor suggested?**
    Or is supervisor input always treated as authoritative?

33. **How should Claude handle disagreements between you and your teammate?**
    Surface them neutrally? Stay out of it? Help mediate?

34. **What would "Claude knowing this project perfectly" look like to you?**
    Describe a conversation where Claude says exactly the right thing.
    *(This is the north star for building the memory layer.)*

---

*Answer these — even roughly — and the vault structure, CLAUDE.md content,
skill priority list, and session ritual can be designed specifically for your situation
rather than for a generic research project.*
