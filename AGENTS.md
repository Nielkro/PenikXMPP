# System Instructions for Claude

## 1. Language Rules
- **Communication:** You must communicate with me, explain concepts, and write your markdown responses entirely in **Russian**.
- **Code & Commits (CRITICAL):** All code comments, docstrings, inline documentation, and Git commit messages MUST be written strictly in **English**. Never use Russian inside the actual source code or version control history.

## 2. Project Architecture & Navigation
We maintain a strict project index in `PROJECT_MAP.md`.

When starting a new task, making changes, or looking for where to implement a feature:
1. ALWAYS silently read `PROJECT_MAP.md` first to understand the context and project structure.
2. Locate the exact file paths from the map before attempting to read or edit source code.
3. If you create a new file or significantly change an existing file's purpose, you MUST update `PROJECT_MAP.md` to reflect this change before finishing the task.

## 3. Auto-Commit Rule
After completing any task (changes to code, config, docs, etc.) you MUST automatically commit with `git add -A && git commit`. Use the project's conventional commit style:

- Format: `type(scope): short imperative description` (no period)
- Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`
- Scope (optional): `android`, `ui`, `chat`, `server`, `push`, `ci`, etc.
- Body (optional): bullet-point list prefixed with `-` detailing specific changes
- Language: English only, lowercase description
- **Verification before commit:** This repository has NO pre-commit hook — CI only runs after a push. Run the targeted checks from section 4 yourself before committing, scoped to the components you actually touched. Do not run full test suites when a compile check is enough.

Examples:
```
feat(ws): rate limit incoming frames
fix: show "just now" for presence when last seen under a minute
refactor: drop presence REST polling now that WS push delivers live updates
chore: untrack uploaded files, ignore server/data/upload
```

## 4. Build & Test Verification
Commands mirror what CI runs (`.github/workflows/ci-fast.yml`, `dev-integration.yml`).

- **Android** — from the `android/` directory, always invoke as `bash ./gradlew` (never `./gradlew` directly):
  - Fast compile check: `bash ./gradlew compileConversationsFreeDebugKotlin`
  - When playstore-only code changed too: `bash ./gradlew compileConversationsPlaystoreDebugKotlin`
  - Unit tests: `bash ./gradlew testConversationsFreeDebugUnitTest`
  - There is no plain `compileDebugKotlin` task — the app uses flavors (`conversations`/`quicksy` × `free`/`playstore`).
- **Rust** — in `server/MicroServices/penik-service-rs/` and `fpush/`:
  - Fast check: `cargo check`
  - When logic changed: `cargo test --all`
- **Lua** — server module tests run from the repo root with plain `lua`:
  - `lua server/Modules/test_mod_funxmpp.lua`
  - `lua server/Modules/test_mod_stickers_auth.lua`
  - `lua server/Modules/test_mod_penik_silent_muc.lua`

## 5. Subagent Invocation Policy
- **Read-Only / Research Subagents:** You may invoke as many concurrent or sequential research/read-only subagents as needed to explore the codebase, analyze logs, read documentation, or inspect multiple modules in parallel.
- **Code-Modifying / Write Subagents:** If subagents are tasked with modifying code, editing files, or running build/refactoring tasks:
  - Strictly **ONLY ONE** write subagent may be active at any given time.
  - The subagent is disposable / single-use for that task and must handle changes across all relevant layers (Android Kotlin/Java app, Rust microservices and push services, Lua server modules) within that single invocation. Never spawn multiple concurrent subagents to edit code simultaneously.
  - `libs/Penik` is a read-only UI donor — never edit anything under it; port code from it instead.
  - After a write subagent finishes, the **main agent** must verify the project base: check with `git status` / `git diff` that no needed files were deleted, nothing unrelated was removed, and the edits only touch the intended files. If the subagent damaged the base, the main agent fixes it before proceeding.
  - The **main agent** performs the `git add` / `git commit` itself. Write subagents must never commit; their edits become part of one commit made by the main agent.
