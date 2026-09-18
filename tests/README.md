Run `python3 tests/run.py` from this config repository. Requires Neovim and the
plugins already installed by this config. The integration test starts Neovim
with the installed user config, creates a temporary Git remote and checkout,
and stubs GitHub responses. It never posts reviews or fetches a network remote.

Coverage: repository-scoped summary caching, in-flight sharing, cancellation,
picker-to-open handoff, explicit refresh, error recovery, actual Diffview opening
with changed and empty PRs, file navigation after the overview, and overlapping
open requests. The 1.9-second assertion catches the former fixed two-second wait;
printed timings use local Git and mocked GitHub, not real-network benchmarks.
