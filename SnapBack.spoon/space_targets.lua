--- Space selection over a single snapshot. No private APIs in this module.
local targets = {}

function targets.resolve(saved, ids, types, session)
    if not ids then return nil, "missing_spaces" end
    -- A Space ID is useful within the same Mission Control session, but is
    -- never assumed to exist after a reboot. Only ordinary user Spaces move.
    if saved.space_id and session and saved.space_session == session then
        for _, id in ipairs(ids) do
            if id == saved.space_id and types[id] == "user" then return id end
        end
    end
    if saved.space_user_index then
        local index = 0
        for _, id in ipairs(ids) do
            if types[id] == "user" then
                index = index + 1
                if index == saved.space_user_index then return id end
            end
        end
    elseif saved.space_index then
        local id = ids[saved.space_index] -- legacy raw index includes fullscreen Spaces
        if id and types[id] == "user" then return id end
    else
        return nil, "unknown_space"
    end
    return nil, "missing_user_space"
end

return targets
