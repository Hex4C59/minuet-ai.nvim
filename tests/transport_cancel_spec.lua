local helpers = require 'tests.helpers'

local function job(cycle_id)
    local calls = {}
    return {
        state = {
            job = {
                kill = function(_, signal)
                    calls[#calls + 1] = signal
                end,
            },
            cancel_requested = false,
            cycle_id = cycle_id,
            exited = false,
        },
        calls = calls,
    }
end

return {
    {
        name = 'completion transport terminate_cycle cancels every request in only the target cycle',
        run = function()
            helpers.setup_root_config()
            local common = helpers.reload 'minuet.backends.common'
            local first = job(11)
            local second = job(11)
            local unrelated = job(12)
            common.current_jobs = { first.state, second.state, unrelated.state }

            common.terminate_cycle(11)
            helpers.expect_equal(first.calls, { 'sigterm' })
            helpers.expect_equal(second.calls, { 'sigterm' })
            helpers.expect_equal(unrelated.calls, {})
            helpers.expect_truthy(first.state.cancel_requested)
            helpers.expect_truthy(second.state.cancel_requested)
            helpers.expect_falsy(unrelated.state.cancel_requested)
        end,
    },
    {
        name = 'completion transport terminate_cycle ignores exited and unknown jobs',
        run = function()
            helpers.setup_root_config()
            local common = helpers.reload 'minuet.backends.common'
            local exited = job(21)
            exited.state.exited = true
            common.current_jobs = { exited.state }
            common.terminate_cycle(21)
            common.terminate_cycle(999)
            helpers.expect_equal(exited.calls, {})
            helpers.expect_falsy(exited.state.cancel_requested)
        end,
    },
    {
        name = 'duet transport terminate_cycle leaves other predictions running',
        run = function()
            helpers.setup_root_config()
            local common = helpers.reload 'minuet.duet.backends.common'
            local target = job(31)
            local unrelated = job(32)
            common.current_jobs = { target.state, unrelated.state }
            common.terminate_cycle(31)
            helpers.expect_equal(target.calls, { 'sigterm' })
            helpers.expect_equal(unrelated.calls, {})
            helpers.expect_truthy(target.state.cancel_requested)
            helpers.expect_falsy(unrelated.state.cancel_requested)
        end,
    },
}
