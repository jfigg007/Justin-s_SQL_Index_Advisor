# Contributing to Justin's SQL Index Advisor

Thanks for helping improve this project!

## Ways to contribute
- Bug reports (with exact error text and versions)
- Performance/logic fixes
- New guardrails or safety checks
- Docs and examples (screenshots welcome)

## Process
1. Open an Issue describing the change.
2. Fork → branch → PR.
3. Keep PRs small and focused.
4. Add tests or demo scripts where possible.

## Code style
- Use `CREATE OR ALTER` when possible.
- Avoid hard-coding database names.
- Prefer parameterized dynamic SQL and `QUOTENAME`.
- Keep `USE <db>` and DMV queries **in the same batch**.

## Licensing
By contributing, you agree your contributions are MIT-licensed.
