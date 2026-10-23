## Summary

## Related issues

<!-- List every issue this pull request resolves, one per line, as `Closes #123` (`Fixes #123` for a bug) so GitHub
closes it on merge. Use `Part of #123` for an issue that stays open. Write "None" if no issue matches. -->

## Why

## Testing

- [ ] Build succeeds (`xcodegen && xcodebuild ... build` / `./scripts/core-tests.sh`)
- [ ] Verified in the macOS app
- [ ] Tauri checks pass (`npm run check && npm test` and `cargo clippy` / `cargo test` in `apps/tauri`), if `apps/tauri` changed
- [ ] User-facing actions require explicit confirmation via an approval card/plan
