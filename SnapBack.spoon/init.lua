--- === SnapBack ===
--- Modified 2026-11-06: workspace reliability, shortcuts and diagnostics.
---
--- Layout profiles for every display setup: your windows snap back into place
--- when you dock, undock, or your screens wake.
---
--- Download: https://github.com/jamesagarside/snapback
---

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "SnapBack"
obj.version = "0.6.0"
obj.author = "James Garside"
obj.homepage = "https://github.com/jamesagarside/snapback"
obj.license = "Apache-2.0 - https://www.apache.org/licenses/LICENSE-2.0"

obj.logger = hs.logger.new('SnapBack', 'info')
-- Space IDs can be recycled. Persist a Spoon-session token so an old ID is
-- only preferred while this instance still knows what that ID referred to.
obj.spaceSession = hs.host.globallyUniqueString()

-- Configuration
-- Configuration is now dynamic (see below)


-- Use hs.configdir or resolve ~/.hammerspoon safely
local configDir = hs.configdir or hs.fs.pathToAbsolute("~/.hammerspoon")
obj.storagePath = configDir .. "/snapback"
obj.legacyStoragePath = configDir .. "/window-layouts"
obj.profilesFile = obj.storagePath .. "/profiles.json"
obj.settingsFile = obj.storagePath .. "/settings.json"
obj.dirCreated = false

-- Ensure storage directory exists
function obj.ensureStorageExists()
    if obj.dirCreated then return end
    -- Migrate data saved under the pre-rename (AutoArrange) storage location
    if not hs.fs.attributes(obj.storagePath) and hs.fs.attributes(obj.legacyStoragePath) then
        assert(os.rename(obj.legacyStoragePath, obj.storagePath), "Cannot migrate SnapBack storage")
    end
    if not hs.fs.attributes(obj.storagePath) then
        assert(hs.fs.mkdir(obj.storagePath), "Cannot create SnapBack storage directory")
    end
    obj.dirCreated = true
end

-- Submodules live next to this file inside the Spoon
local spoonPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or ""
local Store = dofile(spoonPath .. "store.lua")
local geometry = dofile(spoonPath .. "geometry.lua")
local matcher = dofile(spoonPath .. "matcher.lua")
local actions = dofile(spoonPath .. "actions.lua")
local minimap = dofile(spoonPath .. "minimap.lua")
local displays = dofile(spoonPath .. "displays.lua")
local persistence = dofile(spoonPath .. "persistence.lua")
local spaceTargets = dofile(spoonPath .. "space_targets.lua")

local jsonFiles = persistence.new{
    exists = function(path) return hs.fs.attributes(path) ~= nil end,
    readJson = function(path) return hs.json.read(path) end,
    writeJson = function(data, path) return hs.json.write(data, path, true, true) end,
    rename = os.rename,
    remove = os.remove,
}

function obj.logEvent(event, fields)
    fields = fields or {}
    fields.event = event
    fields.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    obj.logger.i(hs.json.encode(fields))
end

-- Profile Store: profiles, layouts, and settings behind one interface.
-- Hammerspoon supplies the storage adapters; tests supply in-memory ones.
obj.store = Store.new{
    profilesFile = obj.profilesFile,
    settingsFile = obj.settingsFile,
    readJson = jsonFiles.read,
    writeJson = jsonFiles.write,
    ensureStorage = function() obj.ensureStorageExists() end,
}

-- UI: Prompt to set base modifiers
function obj.configureModifiers()
    local current = table.concat(obj.store:baseModifiers(), ", ")
    local button, input = hs.dialog.textPrompt("SnapBack Config", "Enter base modifiers (comma separated):", current, "Save & Reload", "Cancel")
    
    if button == "Save & Reload" and input then
        local parts = {}
        local map = {
            cntl = "ctrl", control = "ctrl",
            opt = "alt", option = "alt", atl = "alt", -- frequent typo 'atl'
            command = "cmd",
            shft = "shift"
        }

        for w in string.gmatch(input, "([^,]+)") do
            -- trim whitespace
            local mod = w:match("^%s*(.-)%s*$"):lower()
            if mod and mod ~= "" then
                -- Normalize
                mod = map[mod] or mod
                table.insert(parts, mod)
            end
        end
        
        if #parts > 0 then
            obj.store:setSetting("baseModifiers", parts)
            hs.reload()
        else
            hs.alert.show("Invalid input")
        end
    end
end

-- Toggle Auto-Restore Mode
function obj.setAutoRestoreMode(mode)
    obj.store:setSetting("autoRestoreMode", mode)
    hs.alert.show("Auto-Restore: " .. mode:upper())
end

-- Resolve a registry row to its callable. Snap rows dispatch to
-- snapWindow; command rows map to profile operations.
local commandFns = {
    save = function() obj.captureLayout(nil) end,
    restore = function() obj.restoreLayout() end,
    saveAs = function() obj.saveAsNewProfile() end,
    chooseProfile = function() obj.chooseProfile() end,
}

local function actionFn(row)
    if row.snap then
        return function() obj.snapWindow(row.snap) end
    end
    return commandFns[row.command]
end

local function plainFrame(f)
    return { x = f.x, y = f.y, w = f.w, h = f.h }
end

function obj.screenRecords()
    local records = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        table.insert(records, { id = screen:id(), uuid = screen:getUUID(), name = screen:name(),
            usable = plainFrame(screen:frame()), live = screen })
    end
    return records
end

-- UUID configuration keys survive numeric display-ID changes. Copy legacy
-- data only when its numeric key still identifies this connected setup.
function obj.getDisplayConfigId(screens)
    screens = screens or obj.screenRecords()
    local configId = displays.configId(screens)
    if obj.store:migrateConfig(configId, displays.legacyId(screens)) then
        obj.logEvent("config_migrated", { config = configId })
    end
    return configId
end

-- Keep one filter alive so already-discovered windows on other Spaces remain
-- known. This still cannot enumerate all unvisited Spaces reliably.
function obj.knownWindows()
    if not obj.windowFilter then
        obj.windowFilter = hs.window.filter.new():setDefaultFilter({})
    end
    return obj.windowFilter:getWindows()
end

-- hs.spaces wraps private macOS APIs that can fail or throw on newer macOS
-- versions; guard every call so Spaces trouble degrades a capture/restore
-- (windows land on the current Space) instead of aborting it
local function spacesCall(fn, ...)
    local ok, result, err = pcall(fn, ...)
    if ok and result ~= nil and result ~= false then return result end
    local reason = ok and (err or "unavailable") or result
    obj.logEvent("spaces_api_failed", { reason = tostring(reason) })
    return nil, tostring(reason)
end

-- Helper: Get Space Index map
-- Returns: { [spaceID] = index } and { [screenUUID] = {spaceID, ...} }
function obj.getSpaceMap()
    local map, types, userIndexes = {}, {}, {}
    local spaces = spacesCall(hs.spaces.allSpaces) or {}
    for screenUUID, spaceIDs in pairs(spaces) do
        local userIndex = 0
        for i, spaceID in ipairs(spaceIDs) do
            map[spaceID] = i
            types[spaceID] = spacesCall(hs.spaces.spaceType, spaceID)
            if types[spaceID] == "user" then
                userIndex = userIndex + 1
                userIndexes[spaceID] = userIndex
            end
        end
    end
    return map, spaces, types, userIndexes
end

-- Helper: Get Space ID from Screen UUID and Index
function obj.getSpaceID(screenUUID, index)
    local spaces = spacesCall(hs.spaces.allSpaces) or {}
    if spaces[screenUUID] and spaces[screenUUID][index] then
        return spaces[screenUUID][index]
    end
    return nil
end

-- Capture current window layout
function obj.captureLayout(profileName)
    -- Use default filter but allow all spaces
    local screens = obj.screenRecords()
    local configId = obj.getDisplayConfigId(screens)
    local wins = obj.knownWindows()
    local layout = {}
    
    local spaceMap, _, spaceTypes, userIndexes = obj.getSpaceMap()
    local unknownSpaces = 0
    
    for _, win in ipairs(wins) do
        local app = win:application()
        if app and win:isStandard() then
            local f = win:frame()
            local winScreen = win:screen()
            assert(win:id() and winScreen, "Window disappeared during capture; retry save")
            local screenUUID = winScreen and winScreen:getUUID() or "Unknown"
            
            -- Determine Space Index
            local winSpaces = spacesCall(hs.spaces.windowSpaces, win)
            local spaceIndex, spaceId
            if winSpaces and #winSpaces == 1 then
                local sid = winSpaces[1]
                if spaceMap[sid] and spaceTypes[sid] == "user" then
                    spaceIndex = spaceMap[sid]
                    spaceId = sid
                end
            end
            if not spaceId then unknownSpaces = unknownSpaces + 1 end
            
            local winData = {
                app = app:name(),
                bundle_id = app:bundleID(),
                pid = app:pid(),
                title = win:title(),
                frame = {x=f.x, y=f.y, w=f.w, h=f.h},
                unit_frame = winScreen and geometry.unitFrame(plainFrame(f), plainFrame(winScreen:frame())),
                screen = winScreen and winScreen:name() or "Unknown",
                screen_uuid = screenUUID,
                space_index = spaceIndex,
                space_id = spaceId,
                space_session = spaceId and obj.spaceSession,
                space_user_index = spaceId and userIndexes[spaceId],
                id = win:id(),
                isStandard = win:isStandard()
            }
            
            if winData.isStandard then
                table.insert(layout, winData)
            end
        end
    end
    
    assert(#layout > 0, "No standard windows discovered; existing profiles were preserved")
    -- Do not save a transient dock/undock capture under the wrong setup.
    assert(displays.configId(obj.screenRecords()) == configId, "Displays changed during capture; retry save")
    local targetName = obj.store:saveLayout(configId, profileName, layout, #screens)
    obj.lastReport = { operation = "capture", config = configId, profile = targetName,
        captured = #layout, unknown_spaces = unknownSpaces }
    obj.logEvent("capture_complete", obj.lastReport)

    local message = string.format("Saved Profile: %s (%d windows)", targetName, #layout)
    if unknownSpaces > 0 then message = message .. string.format("\nUnknown Space: %d", unknownSpaces) end
    hs.alert.show(message)
    obj.updateMenubarTitle()
    return obj.lastReport
end

function obj.chooseProfile()
    local names = obj.store:profileNames(obj.getDisplayConfigId())
    if #names == 0 then hs.alert.show("No profiles for this display setup"); return end
    obj.profileChooser = hs.chooser.new(function(choice)
        if choice then obj.switchProfile(choice.text) end
    end)
    local choices = {}
    for _, name in ipairs(names) do choices[#choices + 1] = { text = name } end
    obj.profileChooser:choices(choices)
    obj.profileChooser:show()
end

-- Prompt user for new profile name
function obj.saveAsNewProfile()
    local button, name = hs.dialog.textPrompt("New Profile", "Enter name for new layout profile:", "", "Save", "Cancel")
    if button == "Save" and name and name ~= "" then
        obj.captureLayout(name)
    end
end

-- Switch to a different profile. Only known names are accepted — a typo in
-- a Stream Deck URL would otherwise activate a brand-new empty profile
function obj.switchProfile(name)
    local configId = obj.getDisplayConfigId()
    local exists = false
    for _, n in ipairs(obj.store:profileNames(configId)) do
        if n == name then exists = true end
    end
    if not exists then
        hs.alert.show("No profile named '" .. tostring(name) .. "' for this display setup")
        return
    end
    if obj.store:setActive(configId, name) then
        obj.updateMenubarTitle()
        obj.restoreLayout() -- Auto-restore on switch
    end
end

-- Restore window layout for current display config
function obj.restoreLayout()
    local screens = obj.screenRecords()
    local configId = obj.getDisplayConfigId(screens)
    local activeName = obj.store:activeProfileName(configId)
    local layoutData = obj.store:activeLayout(configId)
    if not layoutData then
        obj.lastReport = { operation = "restore", config = configId, profile = activeName,
            reason = "no_saved_layout" }
        obj.logEvent("restore_unavailable", obj.lastReport)
        hs.alert.show("No saved layout for this profile/display setup")
        return obj.lastReport
    end

    local candidates = {}
    for _, win in ipairs(obj.knownWindows()) do
        local app = win:application()
        if app and win:isStandard() and win:id() then
            table.insert(candidates, { id = win:id(), app = app:name(), bundle_id = app:bundleID(),
                pid = app:pid(), title = win:title(), win = win })
        end
    end
    assert(displays.configId(obj.screenRecords()) == configId, "Displays changed during restore; retry")
    local _, allSpaces, spaceTypes = obj.getSpaceMap()
    local matches, unmatched = matcher.assign(layoutData.windows, candidates)
    local report = { operation = "restore", config = configId, profile = activeName,
        saved = #layoutData.windows, candidates = #candidates, matched = #matches,
        moved = 0, unmatched = #unmatched, skipped = 0, frame_failures = 0,
        space_failures = 0, unknown_spaces = 0, matches = { ID=0, Exact=0, Fuzzy=0, Slot=0 },
        windows = {} }
    obj.lastReport = report

    for _, m in ipairs(matches) do
        local saved, win = m.saved, m.candidate.win
        report.matches[m.matchType] = report.matches[m.matchType] + 1
        local result = { saved_id = saved.id, id = m.candidate.id,
            app = saved.bundle_id or saved.app, match = m.matchType }
        local screen, screenReason = displays.resolve(saved, screens)
        result.screen = screenReason
        if not screen then
            report.skipped = report.skipped + 1
            result.status = "skipped"
        else
            local ok, err = pcall(function()
                local frame = geometry.restoreFrame(saved, screen.usable)
                -- Apply explicit global coordinates computed on the target
                -- display; an absolute rect passed to :move ignores screen.
                win:setFrame(frame, 0)
                local target, reason = spaceTargets.resolve(saved, allSpaces[screen.uuid], spaceTypes, obj.spaceSession)
                if target then
                    local function inSpace(ids)
                        for _, id in ipairs(ids or {}) do if id == target then return true end end
                        return false
                    end
                    local current = spacesCall(hs.spaces.windowSpaces, win)
                    if inSpace(current) then
                        result.space = "already_present"
                    else
                        local moved, moveError = spacesCall(hs.spaces.moveWindowToSpace, win, target)
                        local observed = moved and spacesCall(hs.spaces.windowSpaces, win)
                        if moved and inSpace(observed) then result.space = "moved"
                        else
                            result.space = "failed"
                            result.space_error = moveError or "membership_unverified"
                            report.space_failures = report.space_failures + 1
                        end
                    end
                elseif reason == "unknown_space" then
                    result.space = reason
                    report.unknown_spaces = report.unknown_spaces + 1
                else
                    result.space = reason
                    report.space_failures = report.space_failures + 1
                end
                -- Observe geometry after the last move, including Space moves.
                if geometry.framesMatch(plainFrame(win:frame()), frame, 6) then
                    report.moved = report.moved + 1
                    result.status = "moved"
                else
                    report.frame_failures = report.frame_failures + 1
                    result.status = "frame_rejected"
                end
            end)
            if not ok then
                report.frame_failures = report.frame_failures + 1
                result.status, result.error = "window_failed", tostring(err)
            end
        end
        table.insert(report.windows, result)
        obj.logEvent("restore_window", result)
    end
    for _, saved in ipairs(unmatched) do
        local result = { saved_id = saved.id, app = saved.bundle_id or saved.app, status = "unmatched" }
        table.insert(report.windows, result)
        obj.logEvent("restore_window", result)
    end

    -- Keep the summary compact; per-window details remain in lastReport.
    local summary = {}
    for key, value in pairs(report) do if key ~= "windows" then summary[key] = value end end
    obj.logEvent("restore_complete", summary)
    local msg = string.format("Restored '%s': %d/%d frames", activeName, report.moved, report.saved)
    if report.unmatched + report.skipped + report.frame_failures > 0 then
        msg = msg .. string.format("\nUnmatched: %d, skipped: %d, frame failures: %d",
            report.unmatched, report.skipped, report.frame_failures)
    end
    if report.matches.Fuzzy + report.matches.Slot > 0 then
        msg = msg .. string.format("\nFuzzy: %d, Slot: %d", report.matches.Fuzzy, report.matches.Slot)
    end
    if report.space_failures + report.unknown_spaces > 0 then
        msg = msg .. string.format("\nSpaces failed: %d, unknown: %d", report.space_failures, report.unknown_spaces)
    end
    hs.alert.show(msg)
    return report
end

-- Stream Deck / URL Handler
function obj.handleUrlEvent(eventName, params)
    obj.logger.i("URL Event Received: " .. tostring(eventName))
    obj.logger.i("Params: " .. hs.inspect(params))

    if eventName ~= "snapback" and eventName ~= "windowlayout" then return end
    
    local action = params.action
    local profile = params.profile
    
    if action == "save" then
        obj.captureLayout(profile) -- If profile is nil, saves to active
    elseif action == "restore" then
        if profile then
            obj.logger.i("Triggering Restore Specific Profile from URL: " .. profile)
            obj.switchProfile(profile)
        else
            obj.logger.i("Triggering Restore Active from URL...")
            obj.restoreLayout()
        end
    elseif action == "switch" and profile then
        obj.switchProfile(profile)
    elseif action == "list" then
        local names = obj.store:profileNames(obj.getDisplayConfigId())
        if #names > 0 then
            local doc = "Available Profiles:\n"
            for _, name in ipairs(names) do
                doc = doc .. "- " .. name .. "\n"
            end
            hs.alert.show(doc)
            obj.logger.i(doc)
        else
            hs.alert.show("No profiles found")
        end
    else
        hs.alert.show("SnapBack: Unknown URL action")
        obj.logger.e("Unknown URL Action: " .. tostring(action))
    end
end

function obj.updateMenubarTitle()
    if obj.menubar then
        local active = obj.store:activeProfileName(obj.getDisplayConfigId())
        obj.menubar:setTitle("SB: " .. active)
    end
end

-- Handle screen configuration changes (dock/undock, display sleep/wake).
-- macOS fires several watcher events while the displays settle, so debounce
-- and only act once the configuration has been stable for a few seconds.
function obj.handleScreenChanged()
    obj.logger.i("Display configuration changed")
    obj.updateMenubarTitle()

    if obj.restoreTimer then obj.restoreTimer:stop() end
    obj.restoreTimer = hs.timer.doAfter(3, obj.restoreAfterScreenChange)
end

function obj.restoreAfterScreenChange()
    local mode = obj.store:autoRestoreMode()
    if mode == "disabled" then return end

    local configId = obj.getDisplayConfigId()
    if not obj.store:hasConfig(configId) then
        obj.logger.i("No saved profile for display config: " .. configId)
        return
    end

    if mode == "auto" then
        obj.restoreLayout()
    elseif mode == "prompt" then
        local active = obj.store:activeProfileName(configId)
        local button = hs.dialog.blockAlert("SnapBack",
            string.format("Display setup changed. Restore layout '%s'?", active),
            "Restore", "Not Now")
        if button == "Restore" then obj.restoreLayout() end
    end
end

-- Reveal the profiles/settings folder in Finder
function obj.openStorageFolder()
    obj.ensureStorageExists()
    hs.execute(string.format("open %q", obj.storagePath))
end

-- Show Hotkeys Cheat Sheet — derives from the Action Registry
function obj.showHotkeys()
    hs.alert.show(actions.cheatSheet(obj.store:baseModifiers()), 5)
end

-- Minimap image: the current display arrangement with the active profile's
-- saved windows ghosted in — the dropdown's picture of what "snap back" means
function obj.minimapImage(configId)
    local screens = {}
    for _, s in ipairs(hs.screen.allScreens()) do
        local f = s:fullFrame()
        table.insert(screens, {
            x = f.x, y = f.y, w = f.w, h = f.h,
            name = s:name(), uuid = s:getUUID(),
            usable = plainFrame(s:frame()),
        })
    end
    local layoutData = obj.store:activeLayout(configId)
    local windows = layoutData and layoutData.windows or {}
    return minimap.render(minimap.layout(screens, windows))
end

-- Helper to build the menu table (extracted for refreshing)
function obj.buildMenu()
    local configId = obj.getDisplayConfigId()
    local active = obj.store:activeProfileName(configId)
    local profileNames = obj.store:profileNames(configId)
    local restoreMode = obj.store:autoRestoreMode()
    local base = obj.store:baseModifiers()

    local menuTable = {}

    -- Minimap at the top; profiles are the product, so the first thing the
    -- dropdown shows is this setup and where windows will land. Guarded so a
    -- drawing failure can never take the whole menu down with it.
    local okMap, mapImage = pcall(obj.minimapImage, configId)
    if okMap and mapImage then
        table.insert(menuTable, {
            image = mapImage,
            title = "",
            tooltip = "Current displays with the active profile's saved windows — click to restore",
            fn = obj.restoreLayout,
        })
        table.insert(menuTable, { title = "-" })
    end

    -- Registry row -> menu item with its shortcut label
    local function add(row)
        table.insert(menuTable, {
            title = row.label .. actions.shortcutLabel(base, row.key),
            fn = actionFn(row)
        })
    end

    -- Snap sections derive from the Action Registry
    for _, section in ipairs(actions.menuSections) do
        for _, row in ipairs(actions.list) do
            if row.section == section then add(row) end
        end
        table.insert(menuTable, { title = "-" })
    end

    -- Profiles & Config
    table.insert(menuTable, { title = "Active: " .. active, disabled = true })

    if #profileNames > 0 then
        local profileMenu = {}
        for _, name in ipairs(profileNames) do
            table.insert(profileMenu, {
                title = name,
                checked = (name == active),
                fn = function() obj.switchProfile(name) end
            })
        end
        table.insert(menuTable, { title = "Switch Profile ▶", menu = profileMenu })
    end

    add(actions.byId("save"))
    add(actions.byId("saveAs"))
    add(actions.byId("chooseProfile"))

    table.insert(menuTable, { title = "-" })
    
    -- Auto-Restore Submenu
    table.insert(menuTable, {
        title = "Auto-Restore Mode ▶",
        menu = {
            { title = "Automatic", checked = (restoreMode == "auto"), fn = function() obj.setAutoRestoreMode("auto") end },
            { title = "Prompt", checked = (restoreMode == "prompt"), fn = function() obj.setAutoRestoreMode("prompt") end },
            { title = "Disabled", checked = (restoreMode == "disabled"), fn = function() obj.setAutoRestoreMode("disabled") end }
        }
    })
    
    table.insert(menuTable, { title = "⌨  Hotkeys Cheat Sheet", fn = obj.showHotkeys })
    table.insert(menuTable, { title = "⚙  Set Base Modifiers...", fn = obj.configureModifiers })
    table.insert(menuTable, { title = "Open Data Folder...", fn = obj.openStorageFolder })
    table.insert(menuTable, { title = "Reload Config", fn = hs.reload })

    return menuTable
end

-- Setup Menubar (Standard Style)
function obj.setupMenubar()
    if obj.menubar then return end
    
    obj.menubar = hs.menubar.new()
    obj.menubar:setTooltip("SnapBack — window layout manager")
    obj.updateMenubarTitle()
    
    obj.menubar:setMenu(obj.buildMenu)
end

-- Bind Hotkeys — every registry row, one bind each. Note: this fixes an
-- old divergence where Up/Down maximized/minimized while the menu's
-- Top/Bottom snapped to halves; both now snap to halves.
function obj.bindHotkeys()
    local base = obj.store:baseModifiers()
    for _, row in ipairs(actions.list) do
        hs.hotkey.bind(base, row.key, actionFn(row))
    end
end

-- SNAP & GRID HELPERS
-- Track last snap for cycle detection
obj.lastSnap = {
    winId = nil,
    direction = nil,
    time = 0
}

function obj.snapWindow(direction)
    local win = hs.window.focusedWindow()
    if not win then return end

    if direction == "minimize" then
        win:minimize()
        return
    end

    -- Sub-second clock: os.time()'s 1s resolution made the 2s cycle window
    -- effectively 1-3s depending on where in a second the presses landed
    local now = hs.timer.secondsSinceEpoch()
    local winId = win:id()
    local target = geometry.frameFor(direction, win:screen():frame())
    if not target then return end

    -- Pressing the same direction twice on an already-snapped window walks
    -- it to the adjacent screen, landing on the near column so repeated
    -- presses traverse the whole display setup half-by-half
    local cycle = geometry.cycle[direction]
    if cycle and geometry.isCycle(obj.lastSnap, winId, direction, now)
       and geometry.framesMatch(win:frame(), target) then
        local nextScreen = cycle.toward == "west" and win:screen():toWest()
                                                   or win:screen():toEast()
        if nextScreen then
            win:setFrame(geometry.frameFor(cycle.landing, nextScreen:frame()))
            hs.alert.show(cycle.toward == "west" and "◨ Prev Screen" or "◧ Next Screen")
            -- Keep lastSnap armed so the walk continues press by press
            obj.lastSnap = { winId = winId, direction = direction, time = now }
        end
        return
    end

    win:setFrame(target)

    obj.lastSnap = {
        winId = winId,
        direction = direction,
        time = now
    }
end

-- Init
function obj.start()
    obj.ensureStorageExists()

    -- Performance: Disable window animations for instant snapping
    hs.window.animationDuration = 0

    obj.setupMenubar()
    obj.bindHotkeys()
    obj.knownWindows()

    -- Watch for display changes
    obj.screenWatcher = hs.screen.watcher.new(obj.handleScreenChanged)
    obj.screenWatcher:start()
    
    -- Bind URL Events ("windowlayout" kept for pre-rename Stream Deck setups)
    hs.urlevent.bind("snapback", obj.handleUrlEvent)
    hs.urlevent.bind("windowlayout", obj.handleUrlEvent)

    obj.logger.i("SnapBack started (profiles, auto-restore & snapping)")
end

-- Commands may be invoked by a menu, shortcut, URL, or watcher. Report an
-- operation failure consistently at those boundaries without claiming success.
local function guarded(name, fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        obj.lastReport = { operation = name, error = tostring(result) }
        obj.logEvent("operation_failed", obj.lastReport)
        hs.alert.show("SnapBack " .. name .. " failed: " .. tostring(result))
        return nil, tostring(result)
    end
end

for _, name in ipairs({"captureLayout", "restoreLayout", "switchProfile", "chooseProfile",
    "configureModifiers", "setAutoRestoreMode", "handleScreenChanged", "restoreAfterScreenChange",
    "handleUrlEvent", "buildMenu", "updateMenubarTitle", "start"}) do
    obj[name] = guarded(name, obj[name])
end

return obj
