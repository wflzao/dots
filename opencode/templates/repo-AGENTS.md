# <repo>

## Commands
install: ...
test: ...          test one: ...
lint: ...          typecheck: ...
build: ...         format: ...

If a command is missing, read package.json / Makefile / pyproject.toml first.

## Architecture
entry: ...   domain: ...   data: ...   tests: ...
(5 lines max; link to deeper docs, do not inline them)

## Conventions that differ from defaults
errors: ...   logging: ...   naming: ...   state: ...

## Boundaries
never edit: generated/, vendor/, applied migrations
ask before: schema changes, dependency additions, public API changes
