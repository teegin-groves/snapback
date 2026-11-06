return function(t, root)
    local persistence = dofile(root .. "SnapBack.spoon/persistence.lua")
    local function adapter(failure)
        local files = {profiles={saved=true}}
        local io = persistence.new{
            exists=function(path) return files[path] ~= nil end,
            readJson=function(path) if path == "broken" then return nil end; return files[path] end,
            writeJson=function(data,path)
                files[path] = data
                if failure == "throw" then error("disk full") end
                return failure ~= "write"
            end,
            rename=function(from,to)
                if failure == "rename" then return nil,"denied" end
                files[to], files[from] = files[from],nil
                return true
            end,
            remove=function(path) files[path] = nil end,
        }
        return io, files
    end

    t.test("checked I/O distinguishes a missing file from unreadable existing JSON", function()
        local io, files = adapter()
        t.eq(io.read("missing"), nil)
        files.broken = true
        t.eq(pcall(io.read,"broken"), false)
    end)

    t.test("atomic replacement preserves the destination on write/rename errors", function()
        for _, failure in ipairs({"write","throw","rename"}) do
            local io, files = adapter(failure)
            t.eq(pcall(io.write, {saved=false}, "profiles"), false)
            t.eq(files.profiles, {saved=true})
            t.eq(files["profiles.tmp"], nil)
        end
    end)

    t.test("successful JSON replacement promotes the complete temporary file", function()
        local io, files = adapter()
        t.eq(io.write({new=true}, "profiles"), true)
        t.eq(files.profiles, {new=true})
        t.eq(files["profiles.tmp"], nil)
    end)
end
