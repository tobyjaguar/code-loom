# NNNN-x — Title

Plan: .agents/plans/NNNN-slug.md
Zone: assist | auto
<!-- Fence-profile: NAME   optional. Uncomment for a task that must read or
     edit a path in [fence], and only with a profile that names providers
     you are willing to send it to. See README § Fence profiles. -->

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
