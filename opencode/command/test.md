---
description: Author independent tests from the spec and diff
agent: orchestrator
---
Use the current spec and the current diff. Do not read the implementer's reasoning.
Write tests that would fail if the behaviour were wrong. Public behaviour only;
do not mirror internal helpers or assert implementation details.
Run the tests. Report: added, changed, command, pass/fail. Fix nothing.
