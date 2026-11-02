# Conversation Timeline Rewrite Plan

This document preserves the agreed plan for rewriting the DinoX conversation
renderer without damaging existing chat functionality.

The rewrite must stay staged, auditable, and reversible. It is not a quick
patch and must not be implemented as a big-bang replacement.

## Goals

- Reduce flicker when opening or switching chats.
- Reduce layout churn caused by tearing down and rebuilding the message list.
- Move the renderer toward a model-backed timeline architecture.
- Keep all existing 1:1, MUC, private MUC, file-transfer, media, OMEMO,
  OpenPGP, call, notification, and plugin behavior intact.
- Remove GTK deprecation usage only in chat-renderer code that is touched by
  the rewrite. Unrelated Vala-generated C, RTP/GStreamer, ICE/Nice, or other
  warning groups remain separate work.

## Current Architecture Summary

The current conversation view is a manual `Gtk.Box` based renderer. It owns
sorted collections, maps from meta-items to skeletons and widgets, and inserts
or removes widgets directly.

Chat switches currently rebuild the latest window of items. This can recreate
message skeletons, avatars, reactions, file widgets, previews, and media
widgets. The current rendering path also has separate reveal/opacity handling
in the outer conversation controller and the inner conversation view.

These properties make flicker, delayed reveal, layout jumps, and expensive
large-MUC avatar work more likely.

## Non-Breakage Requirements

The rewrite must not break:

- 1:1 chats.
- MUCs and private MUCs.
- Local `ContentItemStore` ordering and hide semantics.
- MAM/history sync flow, which must remain outside the UI renderer.
- Quote jumps, search jumps, highlight behavior, and scroll restoration.
- Bottom-lock behavior and loading older/newer local history windows.
- Date separators.
- Unread indicators.
- Chat-state rows.
- MUC status rows.
- Inline notifications.
- OMEMO bad-message rows and device notifications.
- OpenPGP-related rows and encryption indicators.
- Message reactions.
- Message corrections, deletions, and retractions.
- Delivery/error/edited state updates.
- Calls and call-state rows.
- File-transfer visible actions: download, cancel, retry, upload progress, and
  download progress.
- Image previews and image download state.
- Audio playback lifecycle.
- Video preview/playback lifecycle.
- GStreamer pipeline cleanup.
- Plaintext lease handling for encrypted media.
- Windows and Linux file-open behavior.
- Existing plugin contracts until a compatible replacement is proven.

## Target Architecture

The preferred target is a model-backed timeline:

- `ConversationTimelineModel` holds timeline data without owning GTK widgets.
- `TimelineRow` objects represent messages, files, calls, separators, unread
  markers, MUC status rows, chat-state rows, notification rows, and plugin rows.
- `ConversationTimelineController` owns conversation switching, local history
  windows, populator lifecycle, trimming, scroll anchors, and bottom state.
- The eventual renderer uses `Gtk.ListView`, a `Gio.ListModel` or custom
  `GListModel`, and `Gtk.SignalListItemFactory`.
- Row widgets use explicit `setup`, `bind`, `unbind`, and `teardown`
  lifecycles.
- A compatibility layer keeps existing `MetaConversationItem`,
  `ConversationItemCollection`, `NotificationCollection`, and
  `ConversationAdditionPopulator` behavior working during migration.

## Migration Order

### Slice 0: Document Invariants and Measurements

- Document current invariants: initial item count, paging size, trim limit,
  sorting, merge rules, bottom-state handling, and populator ordering.
- Add or preserve timing points for chat switch, `clear`, latest display,
  item insertion, skeleton creation, avatar initialization, and preview
  initialization.
- Keep behavior unchanged.

### Slice 1: Fix Existing Lifecycle Baseline

- Add explicit `ContentProvider` close/uninit behavior.
- Unregister the content provider when the conversation becomes `null`.
- Ensure `dispose()` unregisters active providers.
- Make `clear()` dispose skeletons and all meta-items exactly once.
- Recalculate header/merge state deterministically after inserts.

### Slice 2: Unify Reveal Ownership

- Remove or replace duplicate reveal/opacity ownership between the outer
  controller and the inner conversation view.
- Avoid a fixed blank delay during chat switching.
- Keep bottom snap and restore behavior tied to stable layout state.

### Slice 3: Move Expensive Work Out of the Hot Path

- Initialize avatars only when the corresponding header is visible.
- Defer or throttle avatar fetches during bulk inserts, especially in large
  MUCs.
- Stabilize URL preview layout so late previews do not push visible messages.
- Move render-triggered media side effects, such as video autodownload, into an
  idempotent model or service layer.

### Slice 4: Introduce Timeline Model Under the Old Renderer

- Add `ConversationTimelineModel` and `TimelineRow`.
- Keep the existing `Gtk.Box` renderer as an adapter.
- Move insertion/removal decisions through the model before rendering widgets.
- Keep current plugin and populator behavior compatible.

### Slice 5: Add Experimental `Gtk.ListView` Renderer

- Add a `Gtk.ListView` renderer behind a safe runtime or build-time switch.
- Use a compatibility renderer first, reusing existing skeleton/widget behavior
  where necessary.
- Keep the old renderer available as fallback until parity is proven.

### Slice 6: Port Scroll, Paging, Jump, and Highlight

- Port `initialize_around_message` behavior.
- Preserve reply/search jump behavior for unloaded target messages.
- Preserve bottom-lock and active scroll restoration.
- Load older/newer local history without visible jumps.
- Do not move MAM fetching into the UI renderer.

### Slice 7: Harden File, Media, and Call Lifecycles

- Keep file-transfer controls visible on the row itself.
- Preserve download, cancel, retry, upload progress, download progress, and
  failure states.
- Ensure image preview work is cancellable per row generation.
- Ensure audio/video `unbind` does not accidentally destroy user-intended
  playback state.
- Preserve GStreamer cleanup, bus watches, timeouts, and plaintext leases.
- Preserve call-widget signal and timeout cleanup.

### Slice 8: Preserve and Extend Plugin Compatibility

- Keep date separator, unread, chat-state, MUC status, OMEMO, OpenPGP, and
  notification rows working.
- Keep existing collection and populator signals compatible.
- Add optional new bindable renderer APIs only after the old behavior is
  stable.

### Slice 9: Chat-Renderer GTK Cleanup

- Remove deprecated GTK usage in touched chat-renderer code.
- Keep warning cleanup focused on the renderer slice.
- Do not hide unrelated compiler warnings with casts or non-functional changes.

### Slice 10: Remove the Old Renderer

- Remove the old `Gtk.Box` renderer only after the new renderer passes parity
  tests.
- Keep compatibility code only where plugins still require it.
- Run final audit for signal leaks, source IDs, disposal, media lifecycle, and
  Windows/Linux differences.

## Validation Matrix

Each implementation slice must be independently buildable and reviewable.

Required checks depend on the touched code, but the full rewrite must cover:

- `meson compile -C build main/dinox`.
- Timing comparison with `DINOX_UI_TIMING=1`.
- Linux runtime smoke testing.
- Windows runtime/package smoke testing when renderer, file, or media behavior
  is affected.
- Long 1:1 chat.
- Large MUC.
- Private MUC.
- Scrollback and loading older history.
- Jump to reply and jump to search result.
- Message correction, deletion, and retraction.
- Reactions on visible and newly loaded items.
- Incoming and outgoing file transfers.
- Transfer cancel, retry, upload progress, and download progress.
- Image preview and download state.
- Audio playback across chat switches.
- Video preview and playback across viewport changes.
- Call rows and call state changes.
- OMEMO and OpenPGP plugin rows.
- Inline notifications.
- Memory growth and signal/source cleanup after repeated chat switches.

## Implementation Rules

- Keep patches narrow.
- Keep each slice independently reviewable and revertible.
- Do not remove old behavior before the replacement has proven parity.
- Use architecture, developer, reviewer, and auditor passes for major slices.
- Do not merge a renderer slice if plugin compatibility, scroll behavior,
  file-transfer behavior, or media lifecycle is uncertain.
