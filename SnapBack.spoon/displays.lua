--- Display identity and unambiguous target selection, over plain records.
local displays = {}

function displays.configId(screens)
    local keys = {}
    for _, screen in ipairs(screens) do
        keys[#keys + 1] = screen.uuid or ("id:" .. tostring(screen.id))
    end
    table.sort(keys)
    return "uuid:" .. table.concat(keys, "|")
end

function displays.legacyId(screens)
    local ids = {}
    for _, screen in ipairs(screens) do ids[#ids + 1] = screen.id end
    table.sort(ids)
    return table.concat(ids, "_")
end

function displays.resolve(saved, screens)
    local found
    if saved.screen_uuid then
        for _, screen in ipairs(screens) do
            if screen.uuid == saved.screen_uuid then
                if found then return nil, "ambiguous_uuid" end
                found = screen
            end
        end
        if found then return found, "uuid" end
    end
    for _, screen in ipairs(screens) do
        if screen.name and screen.name == saved.screen then
            if found then return nil, "ambiguous_name" end
            found = screen
        end
    end
    return found, found and "name" or "missing_screen"
end

return displays
