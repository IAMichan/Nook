## Summary

## Why

## Testing

- [ ] Build succeeds (`xcodegen && xcodebuild ... build` / `./scripts/core-tests.sh`)
- [ ] Verified in the macOS app
- [ ] Tauri checks pass (`npm run check && npm test` and `cargo clippy` / `cargo test` in `apps/tauri`), if `apps/tauri` changed
- [ ] User-facing actions require explicit confirmation via an approval card/plan
