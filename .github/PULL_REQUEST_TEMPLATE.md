## Description

<!-- Briefly describe what this PR does -->
<!-- External contributors: DinoX uses Forgejo AGit PRs instead of forks. Keep the same AGit topic when updating this PR. -->

## Related Issues

<!-- Link related issues -->
Fixes #
Closes #
Related to #

## Type of Change

<!-- Mark with [x] -->
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Code style / refactoring (no functional changes)
- [ ] Performance improvement
- [ ] Test addition / modification
- [ ] Security fix

## Testing Done

<!-- Describe the tests you ran -->
- [ ] Tested manually on: ___
- [ ] Cheap static gate passes (`./scripts/run_all_tests.sh --static`)
- [ ] Meson test runner passes (`./scripts/run_all_tests.sh --meson`)
- [ ] MQTT tests pass (`meson test -C build 'mqtt-test' --print-errorlogs`)
- [ ] No compiler warnings (`./scripts/build.sh --strict`)
- [ ] Runtime matrix self-test passes (`./scripts/package-runtime-matrix.sh self-test`) if packaging diagnostics changed
- [ ] Package metadata checks pass (`./scripts/package-runtime-matrix.sh metadata` and `./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json`) if AppStream, desktop or packaging metadata changed
- [ ] Tested with multiple accounts
- [ ] Tested encryption (if applicable)
- [ ] Tested calls (if applicable)

**Test Environment**:
- OS: <!-- e.g. Ubuntu 24.04, Arch Linux, Windows 11 -->
- Desktop: <!-- e.g. GNOME 49, KDE Plasma 6, Cinnamon -->
- Display: <!-- Wayland / X11 -->
- DinoX Version: <!-- e.g. 2.0.0 -->

## Screenshots

<!-- If UI changes, add before/after screenshots -->

<details>
<summary>Before</summary>

<!-- Screenshot -->

</details>

<details>
<summary>After</summary>

<!-- Screenshot -->

</details>

## Checklist

<!-- Mark completed items with [x] -->

### Code Quality
- [ ] Code compiles without warnings (`./scripts/build.sh --strict`)
- [ ] Follows [CODING_GUIDELINES.md](../docs/internal/CODING_GUIDELINES.md)
- [ ] Follows [SECURITY_GUIDELINES.md](../docs/internal/SECURITY_GUIDELINES.md) (for crypto / auth / DB code)
- [ ] No commented-out code or debug prints left
- [ ] Proper error handling — every `catch` logs at minimum `debug()`

### Testing
- [ ] Meson test runner passes (`./scripts/run_all_tests.sh --meson`)
- [ ] MQTT Meson suite passes (`meson test -C build 'mqtt-test' --print-errorlogs`), if affected
- [ ] Added tests for new functionality
- [ ] Manually tested changes
- [ ] No regressions in existing features

### Documentation
- [ ] Updated relevant documentation
- [ ] Added/updated code comments
- [ ] Updated [CHANGELOG.md](../docs/internal/CHANGELOG.md) if needed
- [ ] Updated README XEP table if added XEP support
- [ ] Updated [TESTING.md](../docs/internal/TESTING.md) if tests were added
- [ ] Documentation links pass (`./scripts/check-doc-links.py`) if docs changed

### Database (if applicable)
- [ ] No database schema changes
- [ ] Or: Database migration added and tested
- [ ] Or: Migration documented in commit message
- [ ] Schema migration uses VERSION increment
- [ ] No `exec()` for DML queries (use Qlite ORM)
- [ ] Queries have appropriate LIMIT clauses

### Commit Messages
- [ ] Commit messages follow conventional format
- [ ] Each commit is atomic and logical

## Additional Notes

<!-- Any additional information for reviewers -->

## Review Checklist (for maintainers)

- [ ] Code review completed
- [ ] Tested locally
- [ ] Documentation adequate
- [ ] Follows project conventions
- [ ] Packaging / CI review checks completed if packaging, release workflow or package metadata changed
- [ ] Ready to merge
