# AGENTS.md — repo facts every agent reads

<!-- Keep under 100 lines. This file is read on every agent call; every line
     costs tokens on every invocation. Facts only, no philosophy. -->

## What this repo is
(One paragraph: what the project does, for whom.)

## Layout
(Map of the crates/packages that matter, one line each. Not a file listing.)

## Build & test
- Gate (run before claiming done): `./.agents/gate.sh`
- (Repo-specific commands: build, run, bench.)

## Conventions
- (Error handling style, naming, module layout — the things reviewers reject.)

## Zones
Agents: check `.agents/zones.toml` before editing. `hand` paths are
human-only — propose via tutor-mode tasks, never edit them.

## The contract layer
- Plans: `.agents/plans/` — read the relevant plan before implementing.
- Tasks: `.agents/tasks/` — an implementer touches only the files its task lists.
- Reviews: `.agents/reviews/` — implementer notes and reviewer verdicts.
- Decisions: `.agents/decisions/` — ADRs; consult before redesigning anything.

## Scout
For "where is X / who calls Y" questions, use the scout agent
(`loom scout "<question>"`) instead of crawling source. Its answers carry
file:line citations; treat uncited claims as unknown.
