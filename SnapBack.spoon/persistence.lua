--- Checked JSON I/O. Rename a complete sibling file over the destination;
--- a failed read/write must never turn existing layouts into an empty store.
local persistence = {}

function persistence.new(deps)
    return {
        read = function(path)
            if not deps.exists(path) then return nil end
            local data = deps.readJson(path)
            assert(type(data) == "table", "Cannot read JSON: " .. path)
            return data
        end,
        write = function(data, path)
            local temporary = path .. ".tmp"
            local ok, result = pcall(deps.writeJson, data, temporary)
            if not ok or result ~= true then
                deps.remove(temporary)
                error("Cannot write JSON: " .. path .. ": " .. tostring(result))
            end
            local renamed, err = deps.rename(temporary, path)
            if not renamed then
                deps.remove(temporary)
                error("Cannot replace JSON: " .. path .. ": " .. tostring(err))
            end
            return true
        end,
    }
end

return persistence
