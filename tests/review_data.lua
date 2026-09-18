vim.opt.rtp:prepend(vim.fn.getcwd())
local jobs = {}
vim.system = function(cmd, opts, callback)
  local job = { cmd = cmd, opts = opts, callback = callback }
  function job:kill()
    self.killed = true
  end
  jobs[#jobs + 1] = job
  return job
end
local data = require 'config.review_data'
local function finish(job, result)
  job.callback(result or { code = 0, stdout = '{"number":7,"title":"example"}' })
  vim.wait(20, function()
    return false
  end)
end
local received = 0
local function receive(err, pr)
  assert(not err and pr.number == 7)
  received = received + 1
end
local cancel = data.summary('/one', 7, receive)
data.summary('/one', 7, receive)
assert(#jobs == 1, 'in-flight requests must be shared')
cancel()
finish(jobs[1])
assert(received == 1, 'cancelled subscriber must not fire')
data.summary('/one', 7, receive)
assert(#jobs == 1 and received == 2, 'completed response must be cached')
data.summary('/two', 7, receive)
assert(#jobs == 2 and jobs[2].opts.cwd == '/two', 'cache must be repository scoped')
finish(jobs[2])
data.summary('/one', 7, receive, true)
assert(#jobs == 3, 'explicit refresh must bypass cache')
finish(jobs[3])
local unsubscribe = data.summary('/cancel', 7, receive)
unsubscribe()
vim.wait(200, function()
  return jobs[4].killed
end)
assert(jobs[4].killed, 'unused request must be cancelled')
finish(jobs[4])
local before = received
local leave = data.summary('/handoff', 7, receive)
leave()
data.summary('/handoff', 7, receive)
vim.wait(150, function()
  return false
end)
assert(not jobs[5].killed, 'opening must adopt a picker request')
finish(jobs[5])
assert(received == before + 1)
local failed
local function failure(err)
  failed = err
end
data.summary('/error', 7, failure)
finish(jobs[6], { code = 1, stderr = 'offline' })
assert(failed:find 'offline')
data.summary('/error', 7, failure)
assert(#jobs == 7, 'errors must not be cached')
finish(jobs[7], { code = 0, stdout = 'bad json' })
assert(failed == 'could not parse gh output')
print 'PASS review summary cache, sharing, cancellation, handoff, refresh, errors'
vim.cmd 'qa!'
