# PR review performance

`<leader>gr` opens the picker; `<leader>gN` opens a PR by number. The PR
list, metadata, summaries, and fetched refs are cached per repository on disk
for five minutes, including across Neovim restarts. Cold opens fetch the head
and target branch while loading the summary in parallel. Fetches skip tags,
submodules, and automatic maintenance.

Warm opens validate the local head and base refs before skipping the network
fetch. Missing or changed refs, a different target branch, or newly known head
or base SHAs trigger a fetch. Cached results may be up to five minutes old.
Use `:PRReview!` to refresh the list, `:PRReview! 123` to refresh a numbered PR,
or `<leader>gR` to refresh the current PR's metadata, refs, and summary.
`<leader>gi` refreshes just the summary, comments, and reviews.

The PR list includes descriptions so the picker can show readable previews
without another network request. Cached full summaries appear immediately,
without the preview debounce. Comments and reviews load after a 120 ms pause.
After 220 ms on the same row, the picker prefetches its Git refs in the background;
selecting the PR shares that fetch or reuses its cached result. Diffview and
language servers start only when you open the PR.

Only one speculative Git fetch runs at a time. Scrolling or closing the picker
cancels queued work; a running fetch finishes into the cache. Failed prefetches
are silent and retried on opening. Cache write failures do not prevent reviews,
and failed requests are never cached.

Diff language servers start after a buffer stays visible for 150 ms. Buffers
hidden behind the overview do not start servers. Review buffers use the normal
project-root callbacks and skip Biome, ESLint, and Tailwind by default; ordinary
editable files keep their existing configuration. Adjust `review_lsp_exclude` in
`lua/config/review.lua` if those servers are needed in read-only reviews.

Run `python3 tests/run.py` to exercise the importer, picker, request races, and
LSP navigation. See `tests/README.md` for prerequisites and coverage.

The picker gives most of its height and the full available width to the preview.
Long paragraphs wrap at word boundaries. Use `<C-d>` / `<C-u>` or Page Down /
Page Up to scroll, and `<C-End>` / `<C-Home>` to reach the end or start while
keeping the PR selected. Background summary updates preserve the viewport.
Routine loading, cache-hit, and opened-PR notifications are suppressed; errors,
queued-comment reminders, and review-action confirmations remain visible.
