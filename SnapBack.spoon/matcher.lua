--- === SnapBack.matcher ===
--- Modified 2026-11-06: application-safe IDs and global match-tier priority.
---
--- Smart Matching: pairs saved windows with currently-open ones. Operates on
--- plain records — {id, app, title} — never live hs.window objects, so the
--- whole cascade (ID → exact title → fuzzy title → app slot) is testable
--- under plain Lua. Callers snapshot live windows into records; extra fields
--- on a record (like a reference to the live window) pass through untouched.

local matcher = {}

local function sameApp(a, b)
    if a.bundle_id and b.bundle_id then return a.bundle_id == b.bundle_id end
    return a.app ~= nil and a.app == b.app
end

--- Normalize title for fuzzy matching (remove " - AppName", numbers, special chars)
function matcher.normalizeTitle(title)
    if not title then return "" end
    local s = string.lower(title)
    -- Remove common browser suffixes
    s = s:gsub(" %- google chrome$", "")
    s = s:gsub(" %- visual studio code$", "")
    -- Remove notification counters like "(1)"
    s = s:gsub("%s?%d+%s?", "")
    -- Remove special chars
    s = s:gsub("[%p%c]", "")
    return s
end

--- Calculate string similarity (0.0 to 1.0) — substring containment
function matcher.similarity(s1, s2)
    local longer = #s1 > #s2 and s1 or s2
    local shorter = #s1 > #s2 and s2 or s1
    -- A title that normalizes to nothing ("12:34", "(3)") would substring-
    -- match anything; empty means "no signal", not "perfect match" — let
    -- these fall through to app slotting instead of stealing a window
    if #shorter == 0 then return 0.0 end

    -- Exact substring check is usually good enough for windows
    if string.find(longer, shorter, 1, true) then
        return 0.9 -- High score for substring match
    end

    return 0.0
end

--- Find the best candidate for one saved window.
--- savedWin: {id, app, title}; candidates: array of {id, app, title};
--- usedIds: set of candidate ids already assigned.
--- Returns candidate, matchType ("ID" | "Exact" | "Fuzzy" | "Slot") or nil.
function matcher.findBestMatch(savedWin, candidates, usedIds, tier)
    -- 1. ID Match (same application and process, when available)
    for _, cand in ipairs(candidates) do
        if (not tier or tier == "ID") and not usedIds[cand.id] and cand.id == savedWin.id
           and sameApp(savedWin, cand)
           and (not savedWin.pid or not cand.pid or savedWin.pid == cand.pid) then
            return cand, "ID"
        end
    end

    -- 2. Exact Title Match (Good)
    for _, cand in ipairs(candidates) do
        if (not tier or tier == "Exact") and not usedIds[cand.id] and sameApp(savedWin, cand)
           and cand.title == savedWin.title then
            return cand, "Exact"
        end
    end

    -- 3. Fuzzy Title Match (Okay)
    local best = nil
    local bestScore = 0
    local savedNorm = matcher.normalizeTitle(savedWin.title)

    for _, cand in ipairs(candidates) do
        if (not tier or tier == "Fuzzy") and not usedIds[cand.id] and sameApp(savedWin, cand) then
            local score = matcher.similarity(savedNorm, matcher.normalizeTitle(cand.title))
            if score > 0.5 and score > bestScore then
                bestScore = score
                best = cand
            end
        end
    end

    if best then return best, "Fuzzy" end

    -- 4. App Slotting (Last Resort) — any unused window of the same app
    for _, cand in ipairs(candidates) do
        if (not tier or tier == "Slot") and not usedIds[cand.id] and sameApp(savedWin, cand) then
            return cand, "Slot"
        end
    end

    return nil, nil
end

--- Pair every saved window with a candidate. Assignment bookkeeping lives
--- here — stronger tiers are reserved across the whole layout before fallback.
--- Results remain in saved-window order, each candidate used at most once.
--- Returns:
---  * matches   - array of {saved, candidate, matchType}
---  * unmatched - array of saved windows with no candidate left
function matcher.assign(savedWindows, candidates)
    local usedIds = {}
    local matches, unmatched = {}, {}
    local assigned = {}
    for _, tier in ipairs({"ID", "Exact", "Fuzzy", "Slot"}) do
        for index, saved in ipairs(savedWindows) do
            if not assigned[index] then
                local cand, matchType = matcher.findBestMatch(saved, candidates, usedIds, tier)
                if cand then
                    usedIds[cand.id] = true
                    assigned[index] = { saved = saved, candidate = cand, matchType = matchType }
                end
            end
        end
    end
    for index, saved in ipairs(savedWindows) do
        if assigned[index] then table.insert(matches, assigned[index])
        else table.insert(unmatched, saved) end
    end

    return matches, unmatched
end

return matcher
