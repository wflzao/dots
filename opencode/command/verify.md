---
description: Run the repo gates and report pass/fail
agent: orchestrator
---
Use this repo's gates, in order: format check, lint, typecheck, tests, build.
If a `verify` or `ci` target exists in Makefile, justfile, or package.json, use it.

Stop at the first failure. Show the failing output verbatim (first 40 lines).
Do not fix anything. Report a table: gate | command | pass/fail, then a one-line verdict.
