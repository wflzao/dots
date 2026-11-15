# Engineering standards

## Done means verified
Done = format, lint, typecheck, build, and tests pass, and you have the output.
Never claim a command passed unless you ran it. Name any gate you could not run.

## Scope
One logical change. No drive-by refactors, renames, or reformatting.
Extend existing code; never leave a parallel implementation beside the old one.
If the diff exceeds ~300 lines or 5 files, propose a split first.
Do not add dependencies without asking; prefer stdlib and what the repo already uses.

## Correctness
Behaviour changes need a test that fails without the change.
Bug fixes need a regression test.
Never weaken or delete a test to make it pass; fix the code or prove the test wrong.
Handle errors explicitly: no swallowed exceptions, no silent fallbacks.
Validate at boundaries; trust internal invariants. Never mock the thing under test.

## Uncertainty
Ambiguous or conflicting requirements: stop and ask. Do not guess and proceed.
Label claims: verified / inferred / unknown. Never invent APIs, paths, flags, or output.

## Risk triggers
- auth, secrets, payments, untrusted input, file/network I/O -> Paladin review
- schema or migration -> forward migration + rollback plan
- public API, CLI, or config format -> compatibility check
- new failure path -> log enough context to debug it

## Closeout
End implementation work with: Changed / Verified / Unverified / Risk.
