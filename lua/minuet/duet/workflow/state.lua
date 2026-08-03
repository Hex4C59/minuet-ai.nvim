local M = {}

---@param preview table
---@return table
function M.new(preview)
    ---@type table<integer, minuet.DuetState>
    local states = {}
    local request_seq = 0

    local store = {}

    ---@param bufnr integer
    ---@return minuet.DuetState
    function store.get(bufnr)
        local state = states[bufnr]
        if not state then
            state = {}
            states[bufnr] = state
        end
        return state
    end

    ---@param bufnr integer
    ---@param state minuet.DuetState
    function store.clear(bufnr, state)
        local semantic_cancel = state.semantic_cancel
        state.semantic_cancel = nil
        if semantic_cancel then
            semantic_cancel()
        end
        preview.clear(bufnr, state)
        state.pending_seq = nil
        state.pending_request = nil
        state.cycle_id = nil
        state.lease = nil
        state.edit = nil
        state.candidate = nil
        state.origin_row = nil
        state.origin_col = nil
        state.jump_required = nil
        state.target_bufnr = nil
        state.cross_buffer = nil
        state.focusing = nil
        state.semantic = nil
    end

    ---@param lease minuet.SuggestionLease?
    ---@return minuet.DuetState?
    function store.for_lease(lease)
        if not lease then
            return nil
        end
        return states[lease.state_bufnr or lease.bufnr]
    end

    ---@param bufnr integer
    function store.drop(bufnr)
        states[bufnr] = nil
    end

    ---@return integer
    function store.next_request_seq()
        request_seq = request_seq + 1
        return request_seq
    end

    function store.clear_all()
        for bufnr, state in pairs(states) do
            preview.clear(bufnr, state)
        end
        states = {}
    end

    ---@return table<integer, minuet.DuetState>
    function store.states()
        return states
    end

    return store
end

return M
