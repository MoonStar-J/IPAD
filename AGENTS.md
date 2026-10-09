# Repository workflow

- Preserve existing user changes and follow the scope of the current request.
- Read and apply `karpathy-guidelines` before writing, reviewing, or refactoring code.
- Read and apply `verification-before-completion` before claiming success or committing. Run the relevant verification commands during the current task and inspect their full output and exit status.
- After verification, commit authorized changes directly to main and push to origin/main. Do not create a feature branch or PR unless the user explicitly requests it. Preserve other worktrees and user changes; report verification or push failures accurately.
- Commit subjects, bodies, trailers, and automatically added attribution must not contain the word `codex`, regardless of case. Use concise messages describing the actual changes.
- Do not amend or rewrite existing history unless explicitly requested.
- Respond in concise Korean, leading with the result and clearly stating any unverified behavior.

## Architecture guardrails

- Trace actual user failures through input, state, rendering, and persistence. Separate observed causes from hypotheses.
- Give each state and responsibility one clear owner. Reuse existing sessions, indexes, and caches instead of parallel implementations.
- Refactor the smallest necessary responsibility boundary; remove superseded code and workaround branches in the same change.
- Prefer direct, readable code over empty wrappers, speculative frameworks, or compressed statements.
- Measure input hot paths and invalidate caches only for changed inputs. Do not hide synchronization defects behind arbitrary delays.
- Preserve compatibility, data protection, security, error handling, and Undo consistency when simplifying code.
- Verify real user flows and distinguish synthetic, simulator, physical-device, and account-backed results.
