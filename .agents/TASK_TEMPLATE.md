# NNNN-x — Title

Plan: .agents/plans/NNNN-slug.md
Zone: assist | auto
<!-- Fence-profile: NAME   optional, and NOT documentation only: once this key
     is here, `loom new <task>` REFUSES until you pass the same name on the
     command line, and dies outright on a different one. Uncomment it for a
     task that must read or edit a path in [fence], with a profile that names
     providers you are willing to send it to. The line documents the INTENT (an
     architect agent may have written it); `loom new <task> --fence-profile
     NAME` is the CONSENT, and every later command for the task repeats that
     flag. See README § Fence profiles. -->

## Files
<!-- The ONLY files the implementer may touch. -->
- path/to/file.rs        (modify)
- path/to/new_file.rs    (create)

## Objective
What this task delivers, in a few sentences. Reference the plan's Design
section rather than restating it.

## Constraints
- Task-specific requirements (API stability, no new deps, perf bounds...).

## Definition of done
- [ ] `./.agents/gate.sh` exits 0
- [ ] Task-specific checks (named tests pass, behaviour pinned...).
