# PR review performance

`<leader>gr` opens the picker; `<leader>gN` opens a PR by number. Opening a PR
fetches its head and target branch, with the summary request running in parallel.
Fetches skip tags, submodules, and automatic maintenance. Branch freshness and
the merge-base diff are preserved on every open, including reopen.

Summaries are cached per repository and PR for 60 seconds. The picker and review
share cached and in-flight requests. Fast scrolling waits 120 ms before making a
request and cancels abandoned previews. `<leader>gi` explicitly refreshes the
summary, including comments and reviews.

Diff language servers start after a buffer stays visible for 150 ms. Buffers
hidden behind the overview do not start servers. Review buffers use the normal
project-root callbacks and skip Biome, ESLint, and Tailwind by default; ordinary
editable files keep their existing configuration. Adjust `review_lsp_exclude` in
`lua/config/review.lua` if those servers are needed in read-only reviews.

Run `python3 tests/run.py` to exercise the importer, picker, request races, and
LSP navigation. See `tests/README.md` for prerequisites and coverage.
