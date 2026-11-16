## Summary

## Related issues

<!-- List every issue this pull request resolves, one per line, as `Closes #123` so GitHub closes it on
merge. Use `Part of #123` for an issue that stays open. Write "None" if no issue matches. -->

## Why

## Testing

<!-- Say what you ran and what you saw, not only that tests pass: the command, the result, and for a UI change a
before/after screenshot (drag it in here, never commit it). Say what you could not check. Made with a coding agent?
Add a line naming the agent and model. -->

- [ ] Build succeeds (`xcodegen && xcodebuild ... build` / `./scripts/core-tests.sh`)
- [ ] Verified in the macOS app
- [ ] Tauri checks pass (`npm run check && npm test` and `cargo clippy` / `cargo test` in `apps/tauri`), if `apps/tauri` changed
- [ ] User-facing actions require explicit confirmation via an approval card/plan
