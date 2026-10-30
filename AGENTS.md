# Development Rules

## Implementation

- Stay within scope, preserve user work and unaffected behavior, reuse existing components, and follow local style. Avoid unrelated refactoring or dependency changes; keep project wiring correct and preserve `Package.resolved`.
- Inspect the code and execution path before editing. Correct the root cause at its owning boundary; never mask defects with fallbacks, retries, delays, forced refreshes, or error suppression. If the cause is unproven, investigate or report the blocker.
- Follow Apple's official documentation and Human Interface Guidelines. Use English for developer-facing text and existing String Catalogs with `UPPER_SNAKE_CASE` keys for app text; update all supported localizations.

## Validation and Tools

- Use XcodeBuildMCP or the available Xcode MCP. Command-line Xcode tools are allowed only when MCP is unavailable or lacks the required operation.
- Build code changes on all affected available Apple targets. Fix introduced errors and warnings at their cause; report unrelated existing warnings.
- Run the full available test suite when the user requests a code review, or run the requested tests when explicitly asked. Ordinary edits do not trigger tests.
- Add or change test code only when explicitly requested or when covering core app functionality; do not add tests for every change or attempt to cover every scenario.
- Before an authorized commit, run the full suite only if no passing results already cover the final changes; reuse review results when they do.
- If tests fail or produce errors or warnings, stop and ask the user how to proceed; do not independently fix them or commit. Otherwise, complete the authorized commit without reconfirmation.

## Review

- Review is read-only unless fixes are requested. Findings require confirmation from current code and a concrete execution path, or runtime reproduction, with evidence and impact. If code is inconclusive, verify at runtime before claiming a defect.
- Focus on realistic, broadly relevant workflows. Fix confirmed P0/P1 defects and P2 defects seriously affecting user experience. Exclude minor, stylistic, speculative, and extreme edge cases unless requested.

## Git and Handoff

- Git mutations require explicit authorization, including branches, staging, commits, pushes, PRs/replies, merges, and deletion. Never discard user work, alter stashes, or rewrite history without authorization.
- Before committing, inspect tracked, staged, and untracked changes and complete validation above. Keep commits focused; use one concise sentence describing the final changes.
- Write PR descriptions from the final diff and actual validation. Keep handoffs concise: result, root cause, and validation.