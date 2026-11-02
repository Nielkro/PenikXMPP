# Contributing to DinoX

Thank you for your interest in contributing to DinoX!

## How to Contribute

### Contributor Access

DinoX uses Forgejo at <https://git.dinox.im/dinoxim/dinox>.

- Public registration is enabled, but new accounts are manually approved.
- Regular users cannot create repositories or organizations on this instance.
- Repository forks and repository migrations are intentionally disabled.
- Use Forgejo issues for bug reports and feature requests.
- Use Forgejo AGit for pull requests. This creates a pull request by pushing to
  `refs/for/master`, without creating a fork.

### Reporting Bugs

- Check if the issue already exists in [Forgejo Issues](https://git.dinox.im/dinoxim/dinox/issues)
- Create a new issue using the **Bug Report** template
- Include steps to reproduce, expected behavior, and actual behavior
- Add system information (OS, DinoX version, installation method)
- Attach debug logs — see [DEBUG.md](DEBUG.md) for instructions

### Feature Requests

- Open a new issue using the **Feature Request** template
- Describe the feature and why it would be useful
- If it relates to an XMPP Extension Protocol (XEP), include the XEP number and link
- If possible, include mockups or examples

### Code Contributions

1. **Register and prepare SSH access**
   - Create a Forgejo account at <https://git.dinox.im/user/sign_up>
   - Wait for account approval
   - Add your SSH key in Forgejo account settings

2. **Clone the canonical repository**
   ```bash
   git clone ssh://git@git.dinox.im:2222/dinoxim/dinox.git
   cd dinox
   ```

3. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

4. **Install dependencies and build** — follow the complete
   [Linux Source Build](BUILD.md#linux-source-build) section, including the
   pinned Google/libwebrtc runtime and the production Meson configuration.
   After configuring that build:
   ```bash
   ./scripts/build.sh --strict  # Fail on any compiler warning
   ```

   **Important:** Always use `./scripts/build.sh` instead of `ninja` directly.
   It captures all compiler warnings and displays them prominently at the end.
   A clean build must produce **zero warnings**.

5. **Test your changes** with targeted runtime debug output:
   ```bash
   G_MESSAGES_DEBUG="dino libdino xmpp-vala" ./build/main/dinox
   G_MESSAGES_DEBUG="mqtt" ./build/main/dinox
   ```

   Runtime warnings (like `GtkText - did not receive a focus-out event` or
   `Broken accounting of active state`) only appear when running from the
   terminal — never rely on just the GUI to test. Use [DEBUG.md](DEBUG.md)
   for the right log domain. When broad logging is needed, use
   `scripts/run-dinox-debug.sh`; for focused GTK/GLib warning hunts, use
   `scripts/run_debug.sh --filter <term>` or `scripts/run_debug.sh --fatal`.

   If you change AppStream metadata, desktop integration, or other package-visible
   metadata, run the focused metadata matrix:
   ```bash
   ./scripts/package-runtime-matrix.sh metadata
   ./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
   ```

   Before committing, run the cheap static gate:
   ```bash
   ./scripts/run_all_tests.sh --static
   ```

   This covers documentation links, translation syntax, hidden Unicode,
   Python/shell syntax self-tests and checks, local and Forgejo release helper
   validation, the AppImage runtime mirror self-test, runtime matrix self-test
   logic and package-visible metadata plus the Flatpak manifest.

   For code behavior changes, also run the Meson test runner:
   ```bash
   ./scripts/run_all_tests.sh --meson
   ```

6. **Make your changes**
   - Follow existing code conventions (see below)
   - Test on at least one platform (Linux build, Flatpak, or Windows)

7. **Commit your changes**
   - Use clear, descriptive commit messages
   - Reference issues if applicable: `Fix #123: Description`
   - Keep commits focused — one logical change per commit

8. **Submit a Pull Request with AGit**
   ```bash
   git push origin HEAD:refs/for/master -o topic="your-feature-name"
   ```

   You can also set an explicit pull request title:
   ```bash
   git push origin HEAD:refs/for/master \
     -o topic="your-feature-name" \
     -o title="Short PR title"
   ```

   To update the same pull request, keep using the same `topic`. If you rebased
   or amended commits, add `-o force-push=true`:
   ```bash
   git push origin HEAD:refs/for/master \
     -o topic="your-feature-name" \
     -o force-push=true
   ```

   Do not push directly to `master`. Contributors do not need direct push rights
   and repository creation is intentionally disabled.

9. **Fill out the Pull Request**
   - Fill out the PR template
   - Describe what your PR does and link related issues
   - Add before/after screenshots for UI changes
   - Maintainers review and merge accepted changes

### CI for Pull Requests

External pull requests do not run release or package publishing workflows
automatically. Maintainers run the heavier package builds manually after review.

### Translations

DinoX uses the gettext catalogs listed in `main/po/LINGUAS`. Coverage varies
substantially by locale; use `python3 scripts/check_translations.py` for the
current per-file counts. We welcome translation contributions via pull
requests.

1. Browse the existing `.po` files in `main/po/` — pick your language or create a new one
2. Use a PO editor like [Poedit](https://poedit.net/), [Lokalize](https://apps.kde.org/lokalize/), or any text editor
3. Focus on untranslated (`msgstr ""`) and fuzzy entries first
4. Test your translations locally by building and running DinoX
5. Submit a Pull Request with your updated `.po` file

**Quick start for a new language:**

```bash
# Create a new .po file from the template
cd main/po
msginit -l <LANG_CODE> -i dinox.pot -o <LANG_CODE>.po
# Edit <LANG_CODE>.po with your translations
```

**Translation helper scripts:**

```bash
# Preview batch-inserting missing translation strings into all .po files
python3 scripts/translate_all.py

# Apply the batch translation update after reviewing the dry run
python3 scripts/translate_all.py --apply

# Analyze specific translation keys across all .po files
python3 scripts/analyze_translations.py
```

## Project Architecture

DinoX follows a modular plugin architecture:

| Directory | Purpose |
|-----------|---------|
| `xmpp-vala/` | XMPP protocol library — XEP implementations, stream management |
| `libdino/` | Core application library — services, database, business logic |
| `main/` | GTK4/libadwaita UI — windows, widgets, controllers |
| `qlite/` | SQLite/SQLCipher ORM wrapper |
| `crypto-vala/` | Cryptographic abstractions |
| `plugins/omemo/` | OMEMO encryption (Legacy + OMEMO 2) |
| `plugins/openpgp/` | OpenPGP encryption (XEP-0027, XEP-0373/0374) |
| `plugins/google-webrtc/` | Production audio/video calls and media-message capture through the isolated Google/libwebrtc worker |
| `google-webrtc/` | Native wrapper, worker, device, recorder, and platform runtime code |
| `plugins/rtp/` | Retired legacy GStreamer call engine; disabled in reference and release builds |
| `plugins/ice/` | Legacy ICE/Jingle support plus local-address and Tor/SOCKS5 policy hooks used by direct Jingle-S5B file transfers; not production call ICE |
| `plugins/tor-manager/` | Managed Tor and Lyrebird bridge transport |
| `plugins/http-files/` | HTTP file upload/download (XEP-0363) |
| `plugins/notification-sound/` | Notification sounds |
| `plugins/mqtt/` | MQTT 3.1.1 plugin — IoT sensors, Home Automation, bridging |
| `plugins/bot-features/` | Local HTTP API server, bot management, AI integration |

### Key Patterns

- **Plugin system**: Plugins implement the `RootInterface` and register via `ModuleManager`
- **Async operations**: Use GLib `async`/`yield` pattern throughout
- **Database access**: All queries go through `qlite` — never raw SQL in UI code
- **Signal-based communication**: GLib signals for loose coupling between components

### Helper Scripts

| Script | Purpose |
|--------|--------|
| `scripts/build.sh` | **Primary build script** — captures warnings, `--strict` fails on warnings, and `--clean` cleans outputs while preserving the Meson configuration |
| `scripts/run-dinox-debug.sh` | **Recorded debug launcher** — uses focused default domains and writes timestamped logs plus PID/runinfo files |
| `scripts/run_debug.sh` | **Interactive runtime warning launcher** — focused default domains, `--fatal` for crash-on-warning, `--filter` |
| `scripts/create_openpgp_patches.sh [dino_path]` | Generate diff patches between DinoX and original Dino for OpenPGP porting |
| `scripts/check-shell-syntax.sh [script...]` | Check shell syntax with `bash -n`; use `--self-test` to verify default discovery; without arguments checks Git-tracked shell scripts under `scripts/` by `.sh` suffix or `sh`/`bash` shebang |
| `scripts/check-python-syntax.py [file...]` | Check Python syntax with `py_compile`; use `--self-test` to verify valid and broken sample handling; without arguments checks Git-tracked Python files |
| `scripts/scan_unicode.py` | Scan Git-tracked source and PO/POT translation files for hidden/dangerous Unicode characters; use `--all-files` for a full tree scan and `--self-test` for built-in clean/suspicious samples |
| `scripts/find_dead_code.py` | Heuristic Vala dead-code scanner for review/audit work |
| `scripts/check_translations.py` | Report gettext coverage and fail on `msgfmt` syntax errors; use `--syntax-only` for gates and `--self-test` for built-in valid/broken PO samples |
| `scripts/translate_all.py` | Preview batch translation updates; use `--apply` only after reviewing the dry run |
| `scripts/translate_plugins.py` | Dry-run plugin translation helper; use `--apply` or `--check` explicitly |
| `scripts/analyze_translations.py` | Check coverage of specific translation keys across all languages |

For build, release, and debug scripts see [BUILD.md](BUILD.md#scripts-reference) and [DEBUG.md](DEBUG.md#helper-scripts).

## Code Style

- **Language**: Vala (GTK4 + libadwaita)
- Follow existing code conventions in the file you're editing
- Use meaningful variable and function names
- Comment complex logic, especially protocol-level decisions
- Keep functions focused and small
- Use `debug()`, `warning()`, `critical()` for logging — never `print()`

## Platforms

DinoX runs on Linux and Windows. When contributing:

- **Linux-specific code**: Guarded by `#if !WINDOWS` or runtime checks
- **Windows-specific code**: Guarded by `#if WINDOWS` — see `main/src/ui/application.vala`
- **Cross-platform**: Most code should work on both platforms. Test when possible.

## Communication

- **XMPP Chat** (OMEMO encrypted): [dinox@dinox.im](xmpp:dinox@dinox.im?message)
- **Email**: contact@dinox.im
- **Forgejo Issues**: For bugs and feature requests
- **Security vulnerabilities**: See [SECURITY.md](SECURITY.md) — do NOT open public issues

## License

By contributing, you agree that your contributions will be licensed under the [GPLv3](../../LICENSE).
