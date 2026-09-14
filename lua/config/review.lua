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
}

-- The PR currently being reviewed, as returned by `gh pr list --json`.
M.current = nil

local FIELDS = table.concat({
  'number',
  'title',
  'author',
  'baseRefName',
  'headRefName',
  'headRefOid',
  'isDraft',
  'url',
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

--- Throwaway read-only split. `q` closes it.
local function scratch(name, text, ft)
  local lines = vim.split(text or '', '\n', { trimempty = true })
  if #lines == 0 then
    lines = { '(no output)' }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  if ft then
    vim.bo[buf].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.cmd 'botright vsplit'
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, nowait = true, desc = 'Close' })
  return buf
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

--- Notes file contents with the seeded <!-- --> header stripped.
local function notes_body(number)
  local path = notes_path(number)
  if vim.fn.filereadable(path) == 0 then
    return ''
  end
  local kept = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    if not line:match '^%s*<!%-%-' then
      table.insert(kept, line)
    end
  end
  return vim.trim(table.concat(kept, '\n'))
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
    M.current = pr
    -- Three dots: merge base of the PR's own target branch vs the PR head, so
    -- merges of the base back into the branch do not show up as the author's
    -- changes.
    local ok, err = pcall(vim.cmd, ('DiffviewOpen %s/%s...%s'):format(remote, base, ref))
    if not ok then
      notify('DiffviewOpen failed: ' .. tostring(err), vim.log.levels.ERROR)
      return
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

  local shown = {}
  for _, pr in ipairs(prs) do
    if not base_filter or pr.baseRefName == base_filter then
      table.insert(shown, pr)
    end
  end
  if #shown == 0 and base_filter then
    notify(('nothing targeting %s -- showing all bases'):format(base_filter))
    shown, base_filter = prs, nil
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
      previewer = previewers.new_termopen_previewer {
        get_command = function(entry)
          return { 'gh', 'pr', 'diff', tostring(entry.value.number), '--color', 'always' }
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
  notify 'loading PRs...'
  run({
    'gh',
    'pr',
    'list',
    '--state',
    'open',
    '--search',
    M.config.search,
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

---------------------------------------------------------------------------
-- Context: description, comments, CI
---------------------------------------------------------------------------

function M.info()
  local pr = require_current()
  if not pr then
    return
  end
  run({ 'gh', 'pr', 'view', tostring(pr.number), '--comments' }, function(res)
    if res.code ~= 0 then
      notify('gh pr view failed: ' .. (res.stderr or ''), vim.log.levels.ERROR)
      return
    end
    scratch(('PR #%d'):format(pr.number), res.stdout, 'markdown')
  end)
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

--- Submit the summary and every queued line comment as one review.
function M.submit(kind)
  local pr = require_current()
  if not pr then
    return
  end
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

  -- GitHub requires a summary for these two events.
  if body == '' and ev.event ~= 'APPROVE' then
    notify(ev.label .. ' needs a summary -- <leader>gn to write one', vim.log.levels.WARN)
    return
  end
  local payload = { commit_id = pr.headRefOid, event = ev.event }
  if body ~= '' then
    payload.body = body
  end
  if #queue > 0 then
    payload.comments = queue
  end

  local prompt
  if #queue == 0 and body == '' then
    prompt = ('%s #%d with no comments?'):format(ev.label, pr.number)
  else
    prompt = ('%s on #%d with %d line comment(s)?'):format(ev.label, pr.number, #queue)
  end
  if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
    return
  end

  run({
    'gh',
    'api',
    '--method',
    'POST',
    ('repos/%s/pulls/%d/reviews'):format(slug, pr.number),
    '--input',
    '-',
  }, function(res)
    if res.code ~= 0 then
      local err = res.stderr
      if err == nil or err == '' then
        err = res.stdout
      end
      -- The usual cause is a comment anchored to a line outside the diff.
      notify('review failed: ' .. (err or ''), vim.log.levels.ERROR)
      return
    end
    save_queue(pr.number, {})
    notify(('#%d submitted (%s, %d line comments)'):format(pr.number, ev.label, #queue))
  end, { stdin = vim.json.encode(payload) })
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
map('<leader>gi', M.info, 'Review: PR description + comments')
map('<leader>gk', M.checks, 'Review: PR checks')

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

map('<leader>gy', M.permalink, 'Review: yank GitHub permalink', { 'n', 'x' })

-- Hunk navigation outside of diff mode (diff mode already has ]c / [c).
map(']h', function()
  require('gitsigns').nav_hunk 'next'
end, 'Next git hunk')
map('[h', function()
  require('gitsigns').nav_hunk 'prev'
end, 'Previous git hunk')

vim.api.nvim_create_user_command('PRReview', function()
  M.pick()
end, { desc = 'Pick a PR to review' })

vim.api.nvim_create_user_command('PRUncomment', function(opts)
  M.unqueue(opts.args)
end, { nargs = 1, desc = 'Drop a queued review comment by index' })

return M
