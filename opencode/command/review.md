---
description: Review the current diff for correctness, risk, and security
agent: orchestrator
---
Run `git diff` and `git status`. If there is no diff, say so and stop.
Pass the diff verbatim to @oracle for correctness and risk review.
If it touches auth, secrets, payments, input parsing, file/network I/O, or
permissions, also pass it to @paladin. Merge, dedupe, rank by severity. Fix nothing.
