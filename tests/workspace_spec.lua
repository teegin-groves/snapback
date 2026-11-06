-- Hammerspoon-boundary tests. These exercise the real Spoon with fake macOS
-- objects; they do not establish real Accessibility/private-Space API support.
return function(t, root)
    local originalHs = _G.hs
    local function copy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for key, v in pairs(value) do out[key] = copy(v) end
        return out
    end

    local function setup()
        local state = { files={}, alerts={}, events={}, keys={}, urls={}, filters=0,
            memberships={}, spaceMoves={}, spaceReads=0 }
        local function screen(id, uuid, name, frame)
            return { id=function() return id end, getUUID=function() return uuid end,
                name=function() return name end, frame=function() return copy(frame) end,
                fullFrame=function() return copy(frame) end }
        end
        state.screens = {screen(1,"A","Dell",{x=0,y=0,w=1000,h=800}),
            screen(2,"B","Dell",{x=1000,y=0,w=1000,h=800})}
        local function window(id, title, home)
            local current = {x=home == 2 and 1100 or 100,y=80,w=400,h=400}
            local app = {name=function() return "Editor" end, bundleID=function() return "app.editor" end,
                pid=function() return 100 end}
            local win = {id=function() return id end, title=function() return title end,
                application=function() return app end, isStandard=function() return true end,
                screen=function() return state.screens[home or 1] end,
                frame=function() return copy(current) end}
            function win:setFrame(frame)
                if self.fail then error("Accessibility denied") end
                if not self.reject then current = copy(frame) end
                return self
            end
            function win:move() error("restore must compute explicit target coordinates") end
            return win
        end
        state.window = window
        state.windows = {window(1,"Sensitive document",1), window(2,"Other",2)}
        local logger = {i=function() end,w=function() end,e=function() end,d=function() end}
        _G.hs = {
            host={globallyUniqueString=function() return "test-session" end},
            configdir="/test", logger={new=function() return logger end},
            fs={pathToAbsolute=function(path) return path end,
                attributes=function(path)
                    if path == "/test/snapback" or state.files[path] ~= nil then return {} end
                end, mkdir=function() return true end},
            json={read=function(path) return copy(state.files[path]) end,
                write=function(data,path)
                    if state.writeFails then return false end
                    state.files[path]=copy(data); return true
                end,
                encode=function(data) state.events[#state.events+1]=copy(data); return data.event or "json" end},
            screen={allScreens=function() return state.screens end,
                watcher={new=function(fn)
                    state.screenChanged=fn
                    return {start=function() end}
                end}},
            window={filter={new=function()
                state.filters=state.filters+1
                return {setDefaultFilter=function(self) return self end,
                    getWindows=function() return state.windows end}
            end}},
            spaces={allSpaces=function()
                    state.spaceReads=state.spaceReads+1
                    if state.spacesUnavailable then return nil,"unavailable" end
                    return {A={11,12},B={21}}
                end,
                spaceType=function() return "user" end,
                windowSpaces=function(win)
                    if state.membershipUnavailable then return nil,"unavailable" end
                    return state.memberships[win:id()] or (win:screen():getUUID() == "B" and {21} or {11})
                end,
                moveWindowToSpace=function(win,id)
                    state.spaceMoves[#state.spaceMoves+1]={win=win:id(),space=id}
                    if win.spaceThrows then error("private API failed") end
                    if win.spaceFails then return nil,"move refused" end
                    if not win.unverified then state.memberships[win:id()]={id} end
                    return true
                end},
            alert={show=function(message) state.alerts[#state.alerts+1]=message end},
            hotkey={bind=function(_,key,fn) state.keys[key]=fn end},
            chooser={new=function(fn)
                state.choose=fn
                return {choices=function(_,choices) state.choices=choices end,show=function() end}
            end},
            dialog={textPrompt=function() return "Save","New profile" end,
                blockAlert=function() state.prompts=(state.prompts or 0)+1; return "Restore" end},
            timer={doAfter=function(_,fn)
                local timer={fn=fn,stop=function(self) self.stopped=true end}
                state.timer=timer; return timer
            end},
            menubar={new=function()
                return {setTitle=function() end,setTooltip=function() end,setMenu=function() end}
            end},
            urlevent={bind=function(name,fn) state.urls[name]=fn end},
            inspect=function() return "params" end,
        }
        -- Capture fake filesystem operations in the production JSON adapter,
        -- then immediately restore Lua's globals before running any command.
        local rename, remove = os.rename, os.remove
        os.rename=function(from,to)
            if state.renameFails then return nil,"denied" end
            state.files[to],state.files[from]=state.files[from],nil
            return true
        end
        os.remove=function(path) state.files[path]=nil end
        local ok, spoon = pcall(dofile,root .. "SnapBack.spoon/init.lua")
        os.rename,os.remove=rename,remove
        assert(ok,spoon)
        return spoon,state
    end

    t.test("capture persists relative geometry and uses a persistent window filter", function()
        local spoon, state = setup()
        t.eq(spoon.captureLayout("Coding").captured,2)
        local saved = spoon.store:activeLayout(spoon.getDisplayConfigId()).windows[2]
        t.eq(saved.unit_frame,{x=0.1,y=0.1,w=0.4,h=0.5})
        t.eq(saved.bundle_id,"app.editor")
        t.eq(saved.pid,100)
        spoon.captureLayout()
        t.eq(state.filters,1)
        for _, event in ipairs(state.events) do t.eq(event.title,nil,"no titles in diagnostics") end
    end)

    t.test("unknown Space capture remains unknown instead of defaulting to one", function()
        local spoon, state = setup()
        state.membershipUnavailable=true
        t.eq(spoon.captureLayout("Coding").unknown_spaces,2)
        local saved = spoon.store:activeLayout(spoon.getDisplayConfigId()).windows[1]
        t.eq(saved.space_index,nil)
        t.eq(saved.space_id,nil)
        t.eq(saved.space_user_index,nil)
    end)

    t.test("write failures and empty captures preserve saved profiles and report failure", function()
        local spoon, state = setup()
        spoon.captureLayout("Coding")
        local before = copy(state.files[spoon.profilesFile])
        state.writeFails=true
        t.eq(spoon.captureLayout("Meeting"),nil)
        t.eq(state.files[spoon.profilesFile],before)
        t.ok(state.alerts[#state.alerts]:find("failed",1,true))
        state.writeFails=false
        state.windows={}
        t.eq(spoon.captureLayout("Coding"),nil)
        t.eq(state.files[spoon.profilesFile],before)
    end)

    t.test("unreadable existing JSON is never overwritten by capture", function()
        local spoon, state = setup()
        state.files[spoon.profilesFile]="damaged"
        t.eq(spoon.captureLayout("Coding"),nil)
        t.eq(state.files[spoon.profilesFile],"damaged")
        t.ok(state.alerts[#state.alerts]:find("Cannot read JSON",1,true))
    end)

    t.test("restore uses new monitor origins and reports observed frame results", function()
        local spoon, state = setup()
        spoon.captureLayout("Coding")
        local old = state.screens[2]
        state.screens[2]={id=function() return 999 end,getUUID=old.getUUID,name=old.name,
            frame=function() return {x=-2000,y=0,w=2000,h=1600} end}
        local report = spoon.restoreLayout()
        t.eq(report.moved,2)
        t.eq(report.frame_failures,0)
        t.eq(state.windows[2]:frame(),{x=-1800,y=160,w=800,h=800})
        t.eq(report.matches.ID,2)
    end)

    t.test("restore isolates a window exception and reports unmatched saved windows", function()
        local spoon, state = setup()
        spoon.captureLayout("Coding")
        state.windows[1].fail=true
        state.windows[3]=state.window(3,"Third",1)
        spoon.captureLayout("More")
        state.windows[3]=nil
        local report=spoon.restoreLayout()
        t.eq(report.moved,1)
        t.eq(report.frame_failures,1)
        t.eq(report.unmatched,1)
        t.ok(state.alerts[#state.alerts]:find("Unmatched: 1",1,true))
    end)

    t.test("rejected geometry is not counted as restored", function()
        local spoon, state = setup()
        spoon.captureLayout("Coding")
        state.windows[1]:setFrame({x=0,y=0,w=100,h=100})
        state.windows[1].reject=true
        local report=spoon.restoreLayout()
        t.eq(report.moved,1)
        t.eq(report.frame_failures,1)
    end)

    t.test("unresolved or ambiguous monitors are skipped instead of guessed", function()
        local spoon, state = setup()
        spoon.captureLayout("Coding")
        local id=spoon.getDisplayConfigId()
        local windows=spoon.store:activeLayout(id).windows
        windows[1].screen_uuid="missing"
        windows[2].screen_uuid="missing"
        windows[2].screen="unplugged"
        spoon.store:saveLayout(id,"Coding",windows,2)
        local report=spoon.restoreLayout()
        t.eq(report.skipped,2)
        t.eq(report.moved,0)
        t.eq(report.windows[1].screen,"ambiguous_name")
    end)

    t.test("restore reports returned Space errors, exceptions and unverified moves", function()
        for _, failure in ipairs({"spaceFails","spaceThrows","unverified"}) do
            local spoon, state = setup()
            state.memberships[1]={12}
            spoon.captureLayout("Coding")
            state.memberships[1]={11}
            state.windows[1][failure]=true
            local report=spoon.restoreLayout()
            t.eq(report.moved,2)
            t.eq(report.space_failures,1)
            t.eq(report.windows[1].space,"failed")
        end
    end)

    t.test("restore resolves Spaces once and verifies successful membership", function()
        local spoon, state=setup()
        state.memberships[1]={12}
        spoon.captureLayout("Coding")
        state.memberships[1]={11}
        state.spaceReads=0
        local report=spoon.restoreLayout()
        t.eq(state.spaceReads,1)
        t.eq(report.space_failures,0)
        t.eq(report.windows[1].space,"moved")
        t.eq(state.spaceMoves,{{win=1,space=12}})
    end)

    t.test("unavailable target Spaces are reported while geometry continues", function()
        local spoon, state=setup()
        spoon.captureLayout("Coding")
        state.spacesUnavailable=true
        local report=spoon.restoreLayout()
        t.eq(report.moved,2)
        t.eq(report.space_failures,2)
    end)

    t.test("existing shortcuts and both URL schemes coexist with profile keyboard controls", function()
        local spoon, state=setup()
        spoon.start()
        state.keys.S()
        t.eq(spoon.store:activeProfileName(spoon.getDisplayConfigId()),"Default")
        state.keys.N()
        state.keys.P()
        t.eq(state.choices,{{text="Default"},{text="New profile"}})
        state.choose({text="Default"})
        t.eq(spoon.store:activeProfileName(spoon.getDisplayConfigId()),"Default")
        state.keys.R()
        state.keys.delete()
        t.eq(spoon.lastReport.operation,"restore")
        state.urls.windowlayout("windowlayout",{action="save",profile="Legacy"})
        state.urls.snapback("snapback",{action="restore",profile="New profile"})
        t.eq(spoon.store:activeProfileName(spoon.getDisplayConfigId()),"New profile")
        spoon.switchProfile("Typo")
        t.eq(spoon.store:activeProfileName(spoon.getDisplayConfigId()),"New profile")
    end)

    t.test("screen debounce retains Automatic, Prompt and Disabled behavior", function()
        local spoon, state=setup()
        spoon.captureLayout("Coding")
        spoon.handleScreenChanged()
        local oldTimer=state.timer
        spoon.handleScreenChanged()
        t.eq(oldTimer.stopped,true)
        state.timer.fn()
        t.eq(spoon.lastReport.operation,"restore")
        spoon.store:setSetting("autoRestoreMode","prompt")
        spoon.handleScreenChanged()
        state.timer.fn()
        t.eq(state.prompts,1)
        spoon.store:setSetting("autoRestoreMode","disabled")
        spoon.lastReport={operation="unchanged"}
        spoon.handleScreenChanged()
        state.timer.fn()
        t.eq(spoon.lastReport.operation,"unchanged")
    end)

    t.test("storage errors in a deferred screen callback are reported", function()
        local spoon, state=setup()
        spoon.captureLayout("Coding")
        spoon.handleScreenChanged()
        state.files[spoon.profilesFile]="damaged after scheduling"
        t.eq(pcall(state.timer.fn),true)
        t.eq(spoon.lastReport.operation,"restoreAfterScreenChange")
        t.ok(spoon.lastReport.error:find("Cannot read JSON",1,true))
    end)

    t.test("a Space move that changes geometry is verified after that move", function()
        local spoon, state=setup()
        state.memberships[1]={12}
        spoon.captureLayout("Coding")
        state.memberships[1]={11}
        local move=hs.spaces.moveWindowToSpace
        hs.spaces.moveWindowToSpace=function(win,id)
            win:setFrame({x=0,y=0,w=100,h=100})
            return move(win,id)
        end
        local report=spoon.restoreLayout()
        t.eq(report.moved,1)
        t.eq(report.frame_failures,1)
        t.eq(report.space_failures,0)
    end)
    _G.hs=originalHs
end
