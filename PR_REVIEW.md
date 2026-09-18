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

The picker and review share cached and in-flight requests. Fast scrolling waits
120 ms before making a request and cancels abandoned previews. Cache write
failures do not prevent reviews, and failed requests are never cached.

Diff language servers start after a buffer stays visible for 150 ms. Buffers
hidden behind the overview do not start servers. Review buffers use the normal
project-root callbacks and skip Biome, ESLint, and Tailwind by default; ordinary
editable files keep their existing configuration. Adjust `review_lsp_exclude` in
`lua/config/review.lua` if those servers are needed in read-only reviews.

Run `python3 tests/run.py` to exercise the importer, picker, request races, and
LSP navigation. See `tests/README.md` for prerequisites and coverage.
