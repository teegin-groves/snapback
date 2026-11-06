--- === SnapBack.store ===
--- Modified 2026-11-06: checked writes, validation and UUID-key migration.
---
--- Profile Store: everything SnapBack persists — profiles, layouts, and
--- settings — behind one interface that speaks in Profiles and Layouts.
--- Callers never see the JSON shape; schema migration happens in here, once.
---
--- Pure Lua. Side effects (JSON read/write, directory creation) are injected
--- via `deps`, so tests can run against in-memory adapters without Hammerspoon.

local Store = {}
Store.__index = Store

local DEFAULT_PROFILE = "Default"
local DEFAULT_MODIFIERS = {"cmd", "alt", "ctrl"}
local DEFAULT_AUTO_RESTORE = "auto"

--- Store.new(deps) -> store
--- deps:
---  * profilesFile  - path passed to readJson/writeJson for profile data
---  * settingsFile  - path passed to readJson/writeJson for settings
---  * readJson(path) -> table|nil
---  * writeJson(data, path) -> true on success, otherwise throws/returns false
---  * ensureStorage() - optional; called before any read/write
function Store.new(deps)
    assert(deps and deps.readJson and deps.writeJson, "store: readJson/writeJson deps required")
    local self = setmetatable({}, Store)
    self.deps = deps
    self._settings = nil -- lazy snapshot; settings are read from disk once
    return self
end

function Store:_ensure()
    if self.deps.ensureStorage then self.deps.ensureStorage() end
end

-- ============ Settings ============
-- Loaded once into a snapshot; setters persist and refresh the snapshot.

function Store:settings()
    if not self._settings then
        self:_ensure()
        local settings = self.deps.readJson(self.deps.settingsFile) or {}
        assert(type(settings) == "table", "Invalid settings data")
        self._settings = settings
    end
    return self._settings
end

function Store:saveSettings(settings)
    self:_ensure()
    assert(self.deps.writeJson(settings, self.deps.settingsFile) == true, "Settings write failed")
    self._settings = settings
end

function Store:setSetting(key, value)
    local settings = {}
    for k, v in pairs(self:settings()) do settings[k] = v end
    settings[key] = value
    self:saveSettings(settings)
end

function Store:baseModifiers()
    return self:settings().baseModifiers or DEFAULT_MODIFIERS
end

function Store:autoRestoreMode()
    return self:settings().autoRestoreMode or DEFAULT_AUTO_RESTORE
end

-- ============ Profiles ============
-- On-disk shape (after migration):
--   { [configId] = { active = name, layouts = { [name] = { windows, timestamp, display_count } } } }
-- Legacy shape (pre-profiles): { [configId] = { windows = {...}, timestamp = ... } }
-- Migration is normalize-on-load: callers only ever see the current shape.

local function normalize(profiles)
    assert(type(profiles) == "table", "Invalid profiles data")
    for configId, entry in pairs(profiles) do
        assert(type(configId) == "string", "Invalid configuration key")
        assert(type(entry) == "table", "Invalid display configuration")
        if entry.windows ~= nil then
            assert(type(entry.windows) == "table", "Invalid legacy windows")
            entry.layouts = {
                [DEFAULT_PROFILE] = {
                    windows = entry.windows,
                    timestamp = entry.timestamp
                }
            }
            entry.windows = nil
            entry.timestamp = nil
            entry.active = DEFAULT_PROFILE
        end
        if entry.layouts == nil then entry.layouts = {} end
        if entry.active == nil then entry.active = DEFAULT_PROFILE end
        assert(type(entry.layouts) == "table" and type(entry.active) == "string", "Invalid profile entry")
        for name, layout in pairs(entry.layouts) do
            assert(type(name) == "string" and type(layout) == "table"
                and type(layout.windows) == "table", "Invalid saved layout")
        end
    end
    return profiles
end

function Store:_load()
    self:_ensure()
    return normalize(self.deps.readJson(self.deps.profilesFile) or {})
end

function Store:_save(profiles)
    self:_ensure()
    assert(self.deps.writeJson(profiles, self.deps.profilesFile) == true, "Profiles write failed")
end

--- Copy the currently recognizable legacy key without deleting its data.
function Store:migrateConfig(configId, legacyId)
    local profiles = self:_load()
    if not profiles[configId] and profiles[legacyId] then
        profiles[configId] = profiles[legacyId]
        self:_save(profiles)
        return true
    end
    return false
end

--- Is there anything saved for this display configuration?
function Store:hasConfig(configId)
    return self:_load()[configId] ~= nil
end

function Store:activeProfileName(configId)
    local entry = self:_load()[configId]
    if not entry then return DEFAULT_PROFILE end
    return entry.active
end

--- Layout of the active profile for this display configuration, or nil.
function Store:activeLayout(configId)
    local entry = self:_load()[configId]
    if not entry then return nil end
    return entry.layouts[entry.active]
end

--- Sorted profile names for this display configuration.
function Store:profileNames(configId)
    local names = {}
    local entry = self:_load()[configId]
    if entry then
        for name in pairs(entry.layouts) do
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

--- Save a layout under `name` (nil = the active profile) and make it active.
--- Returns the resolved profile name.
function Store:saveLayout(configId, name, windows, displayCount)
    assert(name == nil or (type(name) == "string" and name:match("%S")
        and not name:find("%c")), "Profile name must contain text and no control characters")
    local profiles = self:_load()
    local entry = profiles[configId]
    if not entry then
        entry = { active = DEFAULT_PROFILE, layouts = {} }
        profiles[configId] = entry
    end

    local targetName = name or entry.active
    entry.layouts[targetName] = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        windows = windows,
        display_count = displayCount
    }
    entry.active = targetName

    self:_save(profiles)
    return targetName
end

--- Make `name` the active profile. Returns false if this display
--- configuration/name has nothing saved yet.
function Store:setActive(configId, name)
    local profiles = self:_load()
    if not profiles[configId] or not profiles[configId].layouts[name] then return false end
    profiles[configId].active = name
    self:_save(profiles)
    return true
end

return Store
