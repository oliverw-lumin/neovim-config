-- PR review workflow.
--
-- Pick a PR that is waiting on your review, diff it against the branch it
-- actually targets (not your local HEAD), leave line comments, submit -- all
-- in nvim. Requires the `gh` CLI, plus telescope + diffview.

local M = {}

M.config = {
  remote = 'origin',
  -- Only show PRs whose base is this branch. <C-a> in the picker toggles to
  -- every base. Set to nil to show everything by default.
  base_filter = 'production',
  search = 'review-requested:@me',
  limit = 100,
  notes_dir = vim.fn.stdpath 'state' .. '/pr-review',
  -- Comment authors to hide in the PR summary. Lua patterns matched
  -- case-insensitively against the login, so 'vercel' covers 'vercel[bot]' too.
  ignore_authors = { 'vercel' },
  -- Land on the PR summary rather than the first file's diff. The file panel
  -- stays put; opening a file from it brings the diff back.
  overview_on_open = true,
  -- Opening a PR closes the diff view and buffers of the one before it.
  close_previous = true,
  -- Leave out PRs that already carry an approving review decision.
  hide_approved = true,
}

-- The PR currently being reviewed, as returned by `gh pr list --json`.
M.current = nil

-- Scratch buffers we created for the current PR, wiped when we move on.
M._scratch = {}

-- Rendered summaries, keyed by PR number, so moving around the picker does not
-- re-run gh for a PR it already fetched. Cleared each time the picker opens.
M._info_cache = {}

-- Forward declaration: the picker previews what <leader>gi renders, but that
-- lives further down the file.
local render_info

local FIELDS = table.concat({
  'number',
  'title',
  'author',
  'baseRefName',
  'headRefName',
  'headRefOid',
  'isDraft',
  'url',
  'reviewDecision',
}, ',')

-- `gh pr view --comments` prints the comments *instead of* the preview, so the
-- description is fetched as structured data and rendered here instead.
local INFO_FIELDS = table.concat({
  'number',
  'title',
  'state',
  'isDraft',
  'author',
  'baseRefName',
  'headRefName',
  'url',
  'body',
  'labels',
  'reviewDecision',
  'additions',
  'deletions',
  'changedFiles',
  'comments',
  'reviews',
}, ',')

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'PR review' })
end

local function have_gh()
  if vim.fn.executable 'gh' == 1 then
    return true
  end
  notify('gh CLI not found -- brew install gh && gh auth login', vim.log.levels.ERROR)
  return false
end

local function git_root()
  local out = vim.fn.systemlist 'git rev-parse --show-toplevel'
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == '' then
    return nil
  end
  return out[1]
end

--- Run a command off the main loop and hand the result back on it.
--- `opts` is merged into the vim.system options (e.g. { stdin = json }).
local function run(cmd, on_done, opts)
  local options = vim.tbl_extend('force', { text = true, cwd = git_root() }, opts or {})
  vim.system(cmd, options, function(res)
    vim.schedule(function()
      on_done(res)
    end)
  end)
end

--- Read-only scratch buffer. No window is opened and no `q` mapping is set,
--- because this buffer may be shown in the diff view's own main window, where
--- closing the window would break the layout.
local function scratch_buf(name, text, ft)
  local lines = vim.split(text or '', '\n', { trimempty = true })
  if #lines == 0 then
    lines = { '(no output)' }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if ft then
    vim.bo[buf].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  M._scratch[buf] = true
  return buf
end

--- Show a buffer in a throwaway split. `q` closes it.
local function open_split(buf)
  vim.cmd 'botright vsplit'
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, nowait = true, desc = 'Close' })
  return buf
end

local function scratch(name, text, ft)
  return open_split(scratch_buf(name, text, ft))
end

--- Put a buffer in the diff view's main window and collapse the other diff
--- window so it fills the area, leaving the file panel alone. Opening a file
--- from the panel makes diffview rebuild the pair itself
--- (StandardView:ensure_layout -> Layout:recover), so this is not destructive.
--- Returns false when we are not in a diff view.
local function show_in_main(buf)
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return false
  end

  local view = lib.get_current_view()
  local layout = view and view.cur_layout
  if not layout or type(layout.get_main_win) ~= 'function' then
    return false
  end

  local main = layout:get_main_win()
  if not main or not main.id or not vim.api.nvim_win_is_valid(main.id) then
    return false
  end

  -- Detach the diff buffers before reusing the window.
  pcall(function()
    layout:open_null()
  end)

  for _, win in ipairs(layout.windows or {}) do
    if win.id and win.id ~= main.id and vim.api.nvim_win_is_valid(win.id) then
      pcall(vim.api.nvim_win_close, win.id, true)
    end
  end

  vim.api.nvim_win_set_buf(main.id, buf)
  pcall(vim.api.nvim_win_call, main.id, function()
    vim.cmd 'diffoff'
  end)
  pcall(function()
    vim.wo[main.id].winbar = ''
    vim.wo[main.id].foldcolumn = '0'
    vim.wo[main.id].number = false
    vim.wo[main.id].relativenumber = false
  end)
  pcall(vim.api.nvim_set_current_win, main.id)
  return true
end

local function require_current()
  if M.current then
    return M.current
  end
  notify('no PR open -- <leader>gr to pick one', vim.log.levels.WARN)
end

--- owner/repo, from the configured remote.
local function repo_slug()
  local url = vim.fn.systemlist('git remote get-url ' .. M.config.remote)[1]
  if not url then
    return nil
  end
  return url:match 'github%.com[:/](.-)%.git$' or url:match 'github%.com[:/](.+)$'
end

--- Recover a repo-relative path from a normal buffer or a diffview:// one.
local function repo_relative(path)
  path = path:gsub('^%a[%w.+-]*://', '')
  local rel = path:match '/%.git/[^/]+/(.+)$'
  if rel then
    return rel
  end
  local root = git_root()
  if root and vim.startswith(path, root .. '/') then
    return path:sub(#root + 2)
  end
  return nil
end

local function in_visual()
  local mode = vim.fn.mode()
  return mode == 'v' or mode == 'V' or mode == '\22'
end

--- Cursor line, or the selected range in visual mode.
local function cursor_range()
  local first, last = vim.fn.line '.', vim.fn.line '.'
  if in_visual() then
    first, last = vim.fn.line 'v', vim.fn.line '.'
    if first > last then
      first, last = last, first
    end
  end
  return first, last
end

--- Leave visual mode immediately, so prompts opened afterwards behave.
local function leave_visual()
  if in_visual() then
    local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(esc, 'nx', false)
  end
end

---------------------------------------------------------------------------
-- On-disk state: notes and the pending line-comment queue
---------------------------------------------------------------------------

local function notes_path(number)
  return ('%s/%d.md'):format(M.config.notes_dir, number)
end

local function queue_path(number)
  return ('%s/%d.comments.json'):format(M.config.notes_dir, number)
end

local function load_queue(number)
  local path = queue_path(number)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if ok and type(data) == 'table' then
    return data
  end
  return {}
end

local function save_queue(number, queue)
  vim.fn.mkdir(M.config.notes_dir, 'p')
  if #queue == 0 then
    vim.fn.delete(queue_path(number))
    return
  end
  vim.fn.writefile({ vim.json.encode(queue) }, queue_path(number))
end

--- Write the open gn buffer if it is this PR's notes file.
local function flush_notes(number)
  local path = vim.fn.fnamemodify(notes_path(number), ':p')
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd 'silent write'
    end)
  end
end

--- Notes contents with the seeded <!-- --> header stripped. Prefers the live
--- gn buffer so unsaved drafts still go out.
local function notes_body(number)
  flush_notes(number)
  local path = vim.fn.fnamemodify(notes_path(number), ':p')
  local buf = vim.fn.bufnr(path)
  local lines
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  elseif vim.fn.filereadable(path) == 1 then
    lines = vim.fn.readfile(path)
  else
    return ''
  end
  local kept = {}
  for _, line in ipairs(lines) do
    if not line:match '^%s*<!%-%-' then
      table.insert(kept, line)
    end
  end
  return vim.trim(table.concat(kept, '\n'))
end

---------------------------------------------------------------------------
-- Tearing down the previous review
---------------------------------------------------------------------------

--- Close every open diff view and wipe what the last PR left lying around.
--- DiffView:close() destroys its own file buffers and its tabpage, so this
--- mostly has to make sure the view object goes with them; lib.is_buf_in_use
--- guards the sweep for any diffview:// buffer that outlived its view.
local function close_previous(number)
  local ok, lib = pcall(require, 'diffview.lib')
  if ok and lib.views then
    -- dispose_view mutates lib.views, so walk a copy.
    local views = {}
    for _, view in ipairs(lib.views) do
      table.insert(views, view)
    end
    for _, view in ipairs(views) do
      pcall(function()
        view:close()
        lib.dispose_view(view)
      end)
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        local in_use = false
        if lib.is_buf_in_use then
          local got, used = pcall(lib.is_buf_in_use, buf)
          in_use = got and used
        end
        if name:match '^diffview://' and not in_use then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end

  -- Our own summary / checks / queue scratches. All 'nofile', nothing to lose.
  for buf in pairs(M._scratch) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    M._scratch[buf] = nil
  end

  -- The notes buffer is a real file, so save it before letting it go.
  if number then
    local buf = vim.fn.bufnr(vim.fn.fnamemodify(notes_path(number), ':p'))
    if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
      if vim.bo[buf].modified then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd 'silent write'
        end)
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---------------------------------------------------------------------------
-- Opening a PR
---------------------------------------------------------------------------

--- Fetch the PR head and its base branch, then diff head against the merge
--- base. Nothing is checked out, so your working tree is untouched.
function M.open(pr)
  local remote = M.config.remote
  local base = pr.baseRefName
  local ref = ('refs/pr/%d'):format(pr.number)

  notify(('#%d fetching (%s -> %s)'):format(pr.number, pr.headRefName, base))

  run({
    'git',
    'fetch',
    remote,
    ('+refs/pull/%d/head:%s'):format(pr.number, ref),
    ('+refs/heads/%s:refs/remotes/%s/%s'):format(base, remote, base),
  }, function(res)
    if res.code ~= 0 then
      notify('fetch failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      return
    end
    -- Leave the previous review behind before opening this one.
    if M.config.close_previous then
      close_previous(M.current and M.current.number)
    end

    M.current = pr
    -- Three dots: merge base of the PR's own target branch vs the PR head, so
    -- merges of the base back into the branch do not show up as the author's
    -- changes.
    local ok, err = pcall(vim.cmd, ('DiffviewOpen %s/%s...%s'):format(remote, base, ref))
    if not ok then
      notify('DiffviewOpen failed: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Land on the PR summary rather than whichever file diffview opened first.
    -- Registered after DiffviewOpen (DiffviewGlobal only exists once the plugin
    -- has loaded) but before its async file loading finishes, so the event is
    -- still ahead of us.
    if M.config.overview_on_open then
      local shown = false
      local function overview()
        if shown then
          return
        end
        shown = true
        M.info { pr = pr, main_only = true }
      end

      local global = rawget(_G, 'DiffviewGlobal')
      local emitter = global and global.emitter
      if emitter and emitter.once then
        emitter:once('diff_buf_win_enter', function()
          vim.schedule(overview)
        end)
      end
      -- Fallback: a PR with no files never fires that event.
      vim.defer_fn(overview, 2000)
    end

    local pending = #load_queue(pr.number)
    if pending > 0 then
      notify(('#%d %s (%d comments still queued)'):format(pr.number, pr.title, pending))
    else
      notify(('#%d %s'):format(pr.number, pr.title))
    end
  end)
end

---------------------------------------------------------------------------
-- Picker
---------------------------------------------------------------------------

function M.show_picker(prs, base_filter)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local previewers = require 'telescope.previewers'
  local entry_display = require 'telescope.pickers.entry_display'

  -- Drop already-approved PRs here as well as in the search query: a negated
  -- search qualifier fails quietly, and this cannot.
  local candidates = {}
  for _, pr in ipairs(prs) do
    if not (M.config.hide_approved and pr.reviewDecision == 'APPROVED') then
      table.insert(candidates, pr)
    end
  end

  local shown = {}
  for _, pr in ipairs(candidates) do
    if not base_filter or pr.baseRefName == base_filter then
      table.insert(shown, pr)
    end
  end
  if #shown == 0 and base_filter then
    notify(('nothing targeting %s -- showing all bases'):format(base_filter))
    shown, base_filter = candidates, nil
  end

  local displayer = entry_display.create {
    separator = '  ',
    items = { { width = 6 }, { width = 14 }, { width = 16 }, { remaining = true } },
  }

  pickers
    .new({}, {
      prompt_title = base_filter and ('PRs for review -> ' .. base_filter)
        or 'PRs for review (all bases)',
      finder = finders.new_table {
        results = shown,
        entry_maker = function(pr)
          local author = pr.author and pr.author.login or '?'
          return {
            value = pr,
            ordinal = ('%d %s %s %s'):format(pr.number, pr.title, author, pr.baseRefName),
            display = function()
              return displayer {
                { '#' .. pr.number, 'TelescopeResultsNumber' },
                { pr.baseRefName, 'TelescopeResultsComment' },
                { author, 'TelescopeResultsIdentifier' },
                (pr.isDraft and '[draft] ' or '') .. pr.title,
              }
            end,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      -- Preview the PR summary -- the same thing <leader>gi shows once it is
      -- open -- rather than the first file's diff.
      previewer = previewers.new_buffer_previewer {
        title = 'PR summary',
        -- One preview buffer per PR, so a slow gh call still lands in the
        -- buffer belonging to the entry that asked for it.
        get_buffer_by_name = function(_, entry)
          return 'pr-summary-' .. tostring(entry.value.number)
        end,
        define_preview = function(self, entry)
          local number = entry.value.number
          local bufnr = self.state.bufnr

          local function fill(text)
            if not vim.api.nvim_buf_is_valid(bufnr) then
              return
            end
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, '\n', { plain = true }))
            pcall(function()
              require('telescope.previewers.utils').highlighter(bufnr, 'markdown')
            end)
          end

          if M._info_cache[number] then
            fill(M._info_cache[number])
            return
          end

          fill(('# #%d %s\n\nloading...'):format(number, entry.value.title or ''))

          run({ 'gh', 'pr', 'view', tostring(number), '--json', INFO_FIELDS }, function(res)
            if res.code ~= 0 then
              fill('gh pr view failed:\n\n' .. (res.stderr or ''))
              return
            end
            local ok, data = pcall(vim.json.decode, res.stdout)
            if not ok or type(data) ~= 'table' then
              fill 'could not parse gh output'
              return
            end
            M._info_cache[number] = render_info(data)
            fill(M._info_cache[number])
          end)
        end,
      },
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            M.open(entry.value)
          end
        end)
        -- Toggle between "only PRs targeting the production branch" and everything.
        local toggle = function()
          actions.close(prompt_bufnr)
          local next_filter = nil
          if not base_filter then
            next_filter = M.config.base_filter
          end
          M.show_picker(prs, next_filter)
        end
        map('i', '<C-a>', toggle)
        map('n', '<C-a>', toggle)
        return true
      end,
    })
    :find()
end

function M.pick()
  if not have_gh() then
    return
  end
  M._info_cache = {}
  notify 'loading PRs...'

  local search = M.config.search
  if M.config.hide_approved then
    search = search .. ' -review:approved'
  end

  run({
    'gh',
    'pr',
    'list',
    '--state',
    'open',
    '--search',
    search,
    '--limit',
    tostring(M.config.limit),
    '--json',
    FIELDS,
  }, function(res)
    if res.code ~= 0 then
      notify('gh pr list failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      return
    end
    local ok, prs = pcall(vim.json.decode, res.stdout)
    if not ok or type(prs) ~= 'table' then
      notify('could not parse gh output', vim.log.levels.ERROR)
      return
    end
    if #prs == 0 then
      notify 'no PRs awaiting your review'
      return
    end
    M.show_picker(prs, M.config.base_filter)
  end)
end

--- Open any PR by number, whether or not it is assigned to you. Accepts
--- "1284", "#1284", or a full pull-request URL.
function M.open_number(arg)
  if not have_gh() then
    return
  end

  local function go(input)
    if not input or input == '' then
      return
    end

    -- A URL for some other repo would give a number we then fetch from *this*
    -- repo's origin, quietly diffing the wrong PR. Refuse instead.
    local owner_repo = input:match 'github%.com/([^/]+/[^/]+)/pull/%d+'
    if owner_repo then
      local slug = repo_slug()
      if slug and owner_repo:lower() ~= slug:lower() then
        notify(('that PR is in %s, but this repo is %s'):format(owner_repo, slug), vim.log.levels.ERROR)
        return
      end
    end

    local number = input:match 'pull/(%d+)' or input:match '(%d+)'
    if not number then
      notify('no PR number in: ' .. input, vim.log.levels.WARN)
      return
    end

    notify('loading #' .. number .. '...')
    run({ 'gh', 'pr', 'view', number, '--json', FIELDS }, function(res)
      if res.code ~= 0 then
        notify(('could not load #%s: %s'):format(number, res.stderr or ''), vim.log.levels.ERROR)
        return
      end
      local ok, pr = pcall(vim.json.decode, res.stdout)
      if not ok or type(pr) ~= 'table' or not pr.number then
        notify('could not parse gh output', vim.log.levels.ERROR)
        return
      end
      M.open(pr)
    end)
  end

  if arg and arg ~= '' then
    go(tostring(arg))
  else
    vim.ui.input({ prompt = 'PR number or url: ' }, go)
  end
end

---------------------------------------------------------------------------
-- Context: description, comments, CI
---------------------------------------------------------------------------

local function ignored_author(login)
  login = (login or ''):lower()
  for _, pattern in ipairs(M.config.ignore_authors or {}) do
    if login:find(pattern:lower()) then
      return true
    end
  end
  return false
end

--- Title, metadata, description, reviews and comments as one markdown document.
--- (Declared as a local at the top of the file.)
function render_info(d)
  local out = {}
  local function add(line)
    table.insert(out, line or '')
  end
  local function add_block(text)
    for _, line in ipairs(vim.split(text or '', '\n', { plain = true })) do
      add((line:gsub('\r$', '')))
    end
  end

  add(('# #%s  %s'):format(tostring(d.number), d.title or ''))
  add ''

  local meta = { d.state or 'OPEN' }
  if d.isDraft then
    table.insert(meta, 'DRAFT')
  end
  table.insert(meta, ('%s -> %s'):format(d.headRefName or '?', d.baseRefName or '?'))
  table.insert(meta, '@' .. ((d.author and d.author.login) or '?'))
  if d.reviewDecision and d.reviewDecision ~= '' then
    table.insert(meta, d.reviewDecision)
  end
  if d.changedFiles then
    table.insert(meta, ('%d files +%d -%d'):format(d.changedFiles, d.additions or 0, d.deletions or 0))
  end
  add('`' .. table.concat(meta, '  |  ') .. '`')

  if d.labels and #d.labels > 0 then
    local names = {}
    for _, label in ipairs(d.labels) do
      table.insert(names, label.name)
    end
    add('')
    add('labels: ' .. table.concat(names, ', '))
  end

  add ''
  add(d.url or '')
  add ''
  add '---'
  add ''

  if d.body and vim.trim(d.body) ~= '' then
    add_block(d.body)
  else
    add '_(no description)_'
  end

  local hidden = 0

  -- Reviews carrying a verdict or a summary. An empty COMMENTED review is just
  -- the container for someone's line comments, so it is dropped.
  local reviews = {}
  for _, r in ipairs(d.reviews or {}) do
    local login = r.author and r.author.login
    if ignored_author(login) then
      hidden = hidden + 1
    elseif vim.trim(r.body or '') ~= '' or (r.state and r.state ~= 'COMMENTED') then
      table.insert(reviews, r)
    end
  end

  local comments = {}
  for _, c in ipairs(d.comments or {}) do
    if ignored_author(c.author and c.author.login) then
      hidden = hidden + 1
    else
      table.insert(comments, c)
    end
  end

  if #reviews > 0 then
    add ''
    add '---'
    add ''
    add '## Reviews'
    for _, r in ipairs(reviews) do
      add ''
      add(('### @%s — %s'):format((r.author and r.author.login) or '?', r.state or ''))
      add ''
      if vim.trim(r.body or '') ~= '' then
        add_block(r.body)
      else
        add '_(no summary)_'
      end
    end
  end

  if #comments > 0 then
    add ''
    add '---'
    add ''
    add '## Comments'
    for _, c in ipairs(comments) do
      add ''
      add(('### @%s — %s'):format((c.author and c.author.login) or '?', (c.createdAt or ''):sub(1, 10)))
      add ''
      add_block(c.body)
    end
  end

  if hidden > 0 then
    add ''
    add(('_%d hidden (ignore_authors: %s)_'):format(hidden, table.concat(M.config.ignore_authors or {}, ', ')))
  end

  return table.concat(out, '\n')
end

--- opts.pr        review this PR instead of the current one
--- opts.main_only only place it in the diff view's main window; if we are not
---                in a diff view, do nothing rather than opening a split
function M.info(opts)
  opts = opts or {}
  local pr = opts.pr or require_current()
  if not pr then
    return
  end
  run({ 'gh', 'pr', 'view', tostring(pr.number), '--json', INFO_FIELDS }, function(res)
    if res.code ~= 0 then
      if not opts.main_only then
        notify('gh pr view failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      end
      return
    end
    local ok, data = pcall(vim.json.decode, res.stdout)
    if not ok or type(data) ~= 'table' then
      notify('could not parse gh output', vim.log.levels.ERROR)
      return
    end
    local buf = scratch_buf(('PR #%d'):format(pr.number), render_info(data), 'markdown')
    if not show_in_main(buf) and not opts.main_only then
      open_split(buf)
    end
  end)
end

--- Open the PR on github.com in the system browser.
function M.browse()
  local pr = require_current()
  if not pr then
    return
  end

  -- The picker already gave us the URL, so this needs no round trip.
  local url = pr.url
  if url and url ~= '' and vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then
      notify(url)
      return
    end
  end

  -- Older nvim, or a PR record without a url: let gh work it out.
  run({ 'gh', 'pr', 'view', tostring(pr.number), '--web' }, function(res)
    if res.code ~= 0 then
      notify('could not open the PR: ' .. (res.stderr or ''), vim.log.levels.ERROR)
    end
  end)
end

--- Is the cursor in one of the diff windows (rather than the file panel)?
local function in_diff_window()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return false
  end
  local view = lib.get_current_view()
  local layout = view and view.cur_layout
  if not layout then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  for _, w in ipairs(layout.windows or {}) do
    if w.id == win then
      return true
    end
  end
  return false
end

--- Open the working-tree copy of the file under review in a new tab, at the
--- same line, where LSP actually works.
---
--- The diff buffers are `diffview://` scratch buffers holding a git blob from a
--- revision that was never checked out, so no language server can attach to
--- them or resolve anything around them. This is your branch's copy of the
--- file, not the PR's -- fine for "where is this defined" and "who calls this",
--- wrong for any line the PR actually changed.
function M.open_local()
  local ok, lib = pcall(require, 'diffview.lib')
  local view = ok and lib.get_current_view()
  local entry = view and view.cur_entry
  if not entry then
    notify('not in a diff view', vim.log.levels.WARN)
    return
  end

  local root = git_root()
  if not root then
    notify('not inside a git repo', vim.log.levels.WARN)
    return
  end

  -- Only trust the cursor line if we are in a diff window, not the file tree.
  local line = 1
  if in_diff_window() then
    line = vim.fn.line '.'
  end

  -- A renamed file may only exist under its old name on your branch.
  local target
  for _, candidate in ipairs { entry.path, entry.oldpath } do
    if candidate and candidate ~= '' then
      local full = root .. '/' .. candidate
      if vim.fn.filereadable(full) == 1 then
        target = full
        break
      end
    end
  end

  if not target then
    notify((entry.path or '?') .. ' does not exist on your branch', vim.log.levels.WARN)
    return
  end

  vim.cmd('tabedit ' .. vim.fn.fnameescape(target))
  line = math.min(line, vim.api.nvim_buf_line_count(0))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd 'normal! zz'
  notify(('%s:%d (your branch, not the PR)'):format(vim.fn.fnamemodify(target, ':.'), line))
end

function M.checks()
  local pr = require_current()
  if not pr then
    return
  end
  -- gh exits non-zero when checks are failing or pending, so show output either way.
  run({ 'gh', 'pr', 'checks', tostring(pr.number) }, function(res)
    local text = res.stdout
    if text == nil or text == '' then
      text = res.stderr
    end
    scratch(('PR #%d checks'):format(pr.number), text)
  end)
end

---------------------------------------------------------------------------
-- Line comments
--
-- GitHub anchors review comments to (path, side, line), where RIGHT is the
-- post-change file and LEFT the pre-change one. Comments are queued locally
-- and sent together with the summary when you submit, which is exactly how a
-- "pending review" works in the web UI.
---------------------------------------------------------------------------

--- Where is the cursor, in GitHub review terms? nil when not in a diff window.
local function diff_location()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    notify('diffview is not loaded', vim.log.levels.WARN)
    return nil
  end

  local view = lib.get_current_view()
  if not view or not view.cur_entry or not view.cur_layout then
    notify('not in a diff view -- <leader>gr to open a PR', vim.log.levels.WARN)
    return nil
  end

  local layout = view.cur_layout
  local win = vim.api.nvim_get_current_win()
  local side
  if layout.b and layout.b.id == win then
    side = 'RIGHT'
  elseif layout.a and layout.a.id == win then
    side = 'LEFT'
  else
    notify('put the cursor in one of the diff windows', vim.log.levels.WARN)
    return nil
  end

  local entry = view.cur_entry
  local path = entry.path
  if side == 'LEFT' and entry.oldpath and entry.oldpath ~= '' then
    path = entry.oldpath
  end
  if not path or path == '' then
    notify('could not work out which file this is', vim.log.levels.WARN)
    return nil
  end

  return { path = path, side = side }
end

local function add_comment(pr, loc, first, last, body)
  body = vim.trim(body or '')
  if body == '' then
    notify('empty comment, nothing queued', vim.log.levels.WARN)
    return
  end

  local queue = load_queue(pr.number)
  local item = { path = loc.path, side = loc.side, line = last, body = body }
  if last > first then
    item.start_line = first
    item.start_side = loc.side
  end
  table.insert(queue, item)
  save_queue(pr.number, queue)

  local where = loc.path .. ':' .. (last > first and ('%d-%d'):format(first, last) or tostring(last))
  notify(('queued (%d pending) %s'):format(#queue, where))
end

--- One-line comment on the cursor line or the visual selection.
function M.comment()
  local pr = require_current()
  if not pr then
    return
  end
  local loc = diff_location()
  if not loc then
    return
  end
  local first, last = cursor_range()
  leave_visual()

  local where = vim.fn.fnamemodify(loc.path, ':t') .. ':' .. tostring(last)
  vim.ui.input({ prompt = ('Comment on %s > '):format(where) }, function(input)
    if input then
      add_comment(pr, loc, first, last, input)
    end
  end)
end

--- Multi-line comment: compose in a split, <C-s> to queue, q to discard.
function M.compose()
  local pr = require_current()
  if not pr then
    return
  end
  local loc = diff_location()
  if not loc then
    return
  end
  local first, last = cursor_range()
  leave_visual()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  pcall(vim.api.nvim_buf_set_name, buf, ('comment %s:%d'):format(loc.path, last))

  vim.cmd 'botright 12split'
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    vim.cmd 'stopinsert'
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    close()
    add_comment(pr, loc, first, last, body)
  end, { buffer = buf, desc = 'Queue this comment' })

  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, desc = 'Discard' })

  notify '<C-s> to queue, q to discard'
  vim.cmd 'startinsert'
end

function M.queued()
  local pr = require_current()
  if not pr then
    return
  end
  local queue = load_queue(pr.number)
  if #queue == 0 then
    notify('no queued comments for #' .. pr.number)
    return
  end
  local lines = {}
  for i, c in ipairs(queue) do
    local where = c.start_line and ('%d-%d'):format(c.start_line, c.line) or tostring(c.line)
    local head = vim.split(c.body, '\n')[1] or ''
    table.insert(lines, ('%d. [%s] %s:%s  %s'):format(i, c.side, c.path, where, head))
  end
  table.insert(lines, '')
  table.insert(lines, ('-- :PRUncomment <n> to drop one, <leader>gQ to clear all'))
  scratch(('PR #%d queued comments'):format(pr.number), table.concat(lines, '\n'))
end

function M.unqueue(index)
  local pr = require_current()
  if not pr then
    return
  end
  local queue = load_queue(pr.number)
  index = tonumber(index)
  if not index or not queue[index] then
    notify('no queued comment ' .. tostring(index), vim.log.levels.WARN)
    return
  end
  local removed = table.remove(queue, index)
  save_queue(pr.number, queue)
  notify(('dropped comment on %s:%d (%d left)'):format(removed.path, removed.line, #queue))
end

function M.clear_queue()
  local pr = require_current()
  if not pr then
    return
  end
  local queue = load_queue(pr.number)
  if #queue == 0 then
    notify 'queue already empty'
    return
  end
  if vim.fn.confirm(('Discard %d queued comments on #%d?'):format(#queue, pr.number), '&Yes\n&No', 2) ~= 1 then
    return
  end
  save_queue(pr.number, {})
  notify 'queue cleared'
end

---------------------------------------------------------------------------
-- Summary notes and submitting
---------------------------------------------------------------------------

--- A real file per PR, so notes survive a restart.
function M.notes()
  local pr = require_current()
  if not pr then
    return
  end
  vim.fn.mkdir(M.config.notes_dir, 'p')
  local path = notes_path(pr.number)
  local fresh = vim.fn.filereadable(path) == 0
  vim.cmd('botright vsplit ' .. vim.fn.fnameescape(path))
  if fresh then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      ('<!-- #%d %s -->'):format(pr.number, pr.title),
      ('<!-- %s -->'):format(pr.url or ''),
      '',
      '',
    })
    vim.cmd 'normal! G'
  end
end

local EVENTS = {
  approve = { event = 'APPROVE', label = 'APPROVE' },
  comment = { event = 'COMMENT', label = 'COMMENT' },
  request = { event = 'REQUEST_CHANGES', label = 'REQUEST CHANGES' },
}

local function api_post(endpoint, payload, on_done)
  run({ 'gh', 'api', '--method', 'POST', endpoint, '--input', '-' }, on_done, {
    stdin = vim.json.encode(payload),
  })
end

--- Submit the summary and every queued line comment as one review.
--- opts.skip_confirm / opts.on_done are for close-PR, which already confirmed.
local function submit_review(pr, kind, opts)
  opts = opts or {}
  local ev = EVENTS[kind]
  if not ev then
    notify('unknown review type: ' .. tostring(kind), vim.log.levels.ERROR)
    return
  end
  if not have_gh() then
    return
  end

  local slug = repo_slug()
  if not slug then
    notify('could not read the ' .. M.config.remote .. ' remote', vim.log.levels.ERROR)
    return
  end

  vim.cmd 'silent! wall'
  local body = notes_body(pr.number)
  local queue = load_queue(pr.number)

  -- A verdict needs something behind it, but line comments count -- an empty
  -- summary is fine when you have already said it inline.
  if body == '' and #queue == 0 and ev.event ~= 'APPROVE' then
    notify(
      ev.label .. ' needs a summary (<leader>gn) or at least one line comment',
      vim.log.levels.WARN
    )
    return
  end
  local payload = { commit_id = pr.headRefOid }
  if body ~= '' then
    payload.body = body
  end
  if #queue > 0 then
    payload.comments = queue
  end

  if not opts.skip_confirm then
    local prompt
    if #queue == 0 and body == '' then
      prompt = ('%s #%d with no comments?'):format(ev.label, pr.number)
    else
      prompt = ('%s on #%d with %d line comment(s)?'):format(ev.label, pr.number, #queue)
    end
    if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
      return
    end
  end

  local function finished()
    save_queue(pr.number, {})
    notify(('#%d submitted (%s, %d line comments)'):format(pr.number, ev.label, #queue))
    if opts.on_done then
      opts.on_done()
    end
  end

  local function failed(res, what)
    local err = res.stderr
    if err == nil or err == '' then
      err = res.stdout
    end
    -- The usual cause is a comment anchored to a line outside the diff.
    notify((what or 'review failed: ') .. (err or ''), vim.log.levels.ERROR)
  end

  local reviews_endpoint = ('repos/%s/pulls/%d/reviews'):format(slug, pr.number)

  -- With a summary (or when approving, where the body is optional) the review
  -- goes out in one request.
  if body ~= '' or ev.event == 'APPROVE' then
    payload.event = ev.event
    api_post(reviews_endpoint, payload, function(res)
      if res.code ~= 0 then
        return failed(res)
      end
      finished()
    end)
    return
  end

  -- No summary: POST without an event, which creates a PENDING review and has
  -- no body requirement, then submit that review, where the body is optional.
  -- This is the same two-step the web UI performs.
  api_post(reviews_endpoint, payload, function(res)
    if res.code ~= 0 then
      return failed(res)
    end

    local ok, review = pcall(vim.json.decode, res.stdout)
    if not ok or type(review) ~= 'table' or not review.id then
      notify('could not read the pending review id from gh', vim.log.levels.ERROR)
      return
    end

    api_post(('%s/%d/events'):format(reviews_endpoint, review.id), { event = ev.event }, function(res2)
      if res2.code ~= 0 then
        -- The comments are on GitHub as a pending review; only the verdict failed.
        save_queue(pr.number, {})
        return failed(res2, 'comments posted as a pending review, but submitting failed: ')
      end
      finished()
    end)
  end)
end

function M.submit(kind)
  local pr = require_current()
  if not pr then
    return
  end
  submit_review(pr, kind)
end

--- Close the GitHub PR. Posts the gn notes and any queued line comments first.
function M.close_pr()
  local pr = require_current()
  if not pr then
    return
  end
  if not have_gh() then
    return
  end

  vim.cmd 'silent! wall'
  local body = notes_body(pr.number)
  local queue = load_queue(pr.number)

  local prompt
  if body ~= '' or #queue > 0 then
    prompt = ('Close #%d on GitHub, sending gn notes and %d line comment(s)?'):format(
      pr.number,
      #queue
    )
  else
    prompt = ('Close #%d on GitHub with no comment?'):format(pr.number)
  end
  if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
    return
  end

  local function tear_down()
    close_previous(pr.number)
    M.current = nil
  end

  local function do_close()
    local cmd = { 'gh', 'pr', 'close', tostring(pr.number) }
    -- Line comments already went out as a review (with the notes as its body).
    -- Notes-only uses --comment so the close reason is on the issue thread.
    if body ~= '' and #queue == 0 then
      table.insert(cmd, '--comment')
      table.insert(cmd, body)
    end
    run(cmd, function(res)
      if res.code ~= 0 then
        local err = res.stderr
        if err == nil or err == '' then
          err = res.stdout
        end
        notify('close failed: ' .. (err or ''), vim.log.levels.ERROR)
        return
      end
      notify(('#%d closed'):format(pr.number))
      tear_down()
    end)
  end

  if #queue > 0 then
    submit_review(pr, 'comment', { skip_confirm = true, on_done = do_close })
    return
  end
  do_close()
end

---------------------------------------------------------------------------
-- Permalinks, for referring to code outside the diff
---------------------------------------------------------------------------

function M.permalink()
  local slug = repo_slug()
  if not slug then
    notify('could not read the ' .. M.config.remote .. ' remote', vim.log.levels.ERROR)
    return
  end
  local rel = repo_relative(vim.fn.expand '%:p')
  if not rel then
    notify('could not work out this file\'s path in the repo', vim.log.levels.WARN)
    return
  end

  local sha = M.current and M.current.headRefOid
  if not sha then
    local head = vim.fn.systemlist 'git rev-parse HEAD'
    sha = head and head[1]
  end
  if not sha or sha == '' then
    notify('could not resolve a commit to link to', vim.log.levels.WARN)
    return
  end

  local first, last = cursor_range()
  local anchor = ('#L%d'):format(first)
  if last > first then
    anchor = anchor .. ('-L%d'):format(last)
  end

  local url = ('https://github.com/%s/blob/%s/%s%s'):format(slug, sha, rel, anchor)
  vim.fn.setreg('+', url)
  notify(url)
end

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

local function map(lhs, rhs, desc, mode)
  vim.keymap.set(mode or 'n', lhs, rhs, { desc = desc })
end

map('<leader>gr', M.pick, 'Review: pick a PR')
map('<leader>gR', function()
  if M.current then
    M.open(M.current)
  else
    M.pick()
  end
end, 'Review: reopen current PR diff')
map('<leader>gi', function()
  M.info()
end, 'Review: PR description + comments')
map('<leader>gk', M.checks, 'Review: PR checks')
map('<leader>gN', function()
  M.open_number()
end, 'Review: open PR by number')
map('<leader>go', M.browse, 'Review: open PR in browser')
map('<leader>gf', M.open_local, 'Review: open local copy of this file (LSP)')

map('<leader>gm', M.comment, 'Review: comment on this line', { 'n', 'x' })
map('<leader>gM', M.compose, 'Review: comment (multi-line)', { 'n', 'x' })
map('<leader>gq', M.queued, 'Review: list queued comments')
map('<leader>gQ', M.clear_queue, 'Review: clear queued comments')

map('<leader>gn', M.notes, 'Review: summary notes')
map('<leader>gA', function()
  M.submit 'approve'
end, 'Review: submit approval')
map('<leader>gC', function()
  M.submit 'comment'
end, 'Review: submit comment')
map('<leader>gX', function()
  M.submit 'request'
end, 'Review: submit request-changes')
map('<leader>gZ', M.close_pr, 'Review: close PR (send gn notes)')

map('<leader>gy', M.permalink, 'Review: yank GitHub permalink', { 'n', 'x' })

-- Hunk navigation outside of diff mode (diff mode already has ]c / [c).
map(']h', function()
  require('gitsigns').nav_hunk 'next'
end, 'Next git hunk')
map('[h', function()
  require('gitsigns').nav_hunk 'prev'
end, 'Previous git hunk')

vim.api.nvim_create_user_command('PRReview', function(opts)
  if opts.args and opts.args ~= '' then
    M.open_number(opts.args)
  else
    M.pick()
  end
end, { nargs = '?', desc = 'Review a PR: pick from your queue, or pass a number/url' })

vim.api.nvim_create_user_command('PRUncomment', function(opts)
  M.unqueue(opts.args)
end, { nargs = 1, desc = 'Drop a queued review comment by index' })

vim.api.nvim_create_user_command('PRClose', function()
  M.close_pr()
end, { desc = 'Close the current PR, sending gn notes and queued comments' })

return M
