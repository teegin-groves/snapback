-- Smart Matching spec: the full cascade (ID → exact → fuzzy → slot) over
-- Modified 2026-11-06: identity reuse and global match-priority regressions.
-- plain records — the part test_suite.lua could never reach when the
-- matcher demanded live hs.window objects.

return function(t, root)
    local matcher = dofile(root .. "SnapBack.spoon/matcher.lua")

    local function saved(id, app, title)
        return { id = id, app = app, title = title }
    end

    t.test("normalizeTitle strips suffixes, counters, punctuation", function()
        t.eq(matcher.normalizeTitle("My Doc - Google Chrome"), matcher.normalizeTitle("my doc"))
        t.eq(matcher.normalizeTitle("init.lua - Visual Studio Code"), matcher.normalizeTitle("initlua"))
        -- Counter is stripped; the space before "(2)" survives (quirk kept
        -- from the original — substring similarity still matches "inbox")
        t.eq(matcher.normalizeTitle("Inbox (2)"), "inbox ")
        t.ok(matcher.similarity(matcher.normalizeTitle("Inbox (2)"),
                                matcher.normalizeTitle("Inbox")) > 0.5)
        t.eq(matcher.normalizeTitle(nil), "")
    end)

    t.test("similarity: substring containment scores 0.9", function()
        t.ok(matcher.similarity("short", "longer with short inside") > 0.8)
        t.eq(matcher.similarity("abc", "xyz"), 0.0)
    end)

    t.test("similarity: empty normalized titles carry no signal", function()
        t.eq(matcher.similarity("", "anything"), 0.0)
        t.eq(matcher.similarity("anything", ""), 0.0)
        t.eq(matcher.similarity("", ""), 0.0)
    end)

    t.test("cascade: digit-only title slots instead of fuzzy-stealing", function()
        -- "14:32" normalizes to "" — it must NOT fuzzy-match the busy
        -- document window; app slotting picks the first free candidate
        local cand, matchType = matcher.findBestMatch(
            saved(1, "Terminal", "14:32"),
            { saved(7, "Terminal", "important long-running job"),
              saved(8, "Terminal", "scratch") },
            {})
        t.eq(matchType, "Slot")
        t.eq(cand.id, 7)
    end)

    t.test("cascade: ID match wins even when titles changed", function()
        local cand, matchType = matcher.findBestMatch(
            saved(42, "Chrome", "Old Title"),
            { saved(41, "Chrome", "Old Title"), saved(42, "Chrome", "Totally New") },
            {})
        t.eq(cand.id, 42)
        t.eq(matchType, "ID")
    end)

    t.test("cascade: exact app+title match when the ID is gone", function()
        local cand, matchType = matcher.findBestMatch(
            saved(42, "Chrome", "Docs"),
            { saved(7, "Chrome", "Docs"), saved(8, "Chrome", "Other") },
            {})
        t.eq(cand.id, 7)
        t.eq(matchType, "Exact")
    end)

    t.test("cascade: fuzzy title match within the same app", function()
        local cand, matchType = matcher.findBestMatch(
            saved(42, "Chrome", "Project Plan - Google Chrome"),
            { saved(7, "Chrome", "Project Plan v2"), saved(8, "Safari", "Project Plan") },
            {})
        t.eq(cand.id, 7, "same-app fuzzy candidate")
        t.eq(matchType, "Fuzzy")
    end)

    t.test("cascade: app slot as last resort", function()
        local cand, matchType = matcher.findBestMatch(
            saved(42, "Terminal", "zsh — 80x24"),
            { saved(7, "Terminal", "completely unrelated telemetry 9000") },
            {})
        t.eq(cand.id, 7)
        t.eq(matchType, "Slot")
    end)

    t.test("cascade: no candidate from another app", function()
        local cand = matcher.findBestMatch(
            saved(42, "Terminal", "zsh"),
            { saved(7, "Safari", "zsh") },
            {})
        t.eq(cand, nil)
    end)

    t.test("used candidates are skipped at every tier", function()
        local cands = { saved(42, "Chrome", "Docs") }
        local cand = matcher.findBestMatch(saved(42, "Chrome", "Docs"), cands, { [42] = true })
        t.eq(cand, nil)
    end)

    t.test("assign: each candidate used at most once, in saved order", function()
        local savedWins = {
            saved(1, "Chrome", "Docs"),
            saved(2, "Chrome", "Docs"), -- same title: must take the other window
        }
        local cands = { saved(10, "Chrome", "Docs"), saved(11, "Chrome", "Docs") }
        local matches, unmatched = matcher.assign(savedWins, cands)
        t.eq(#matches, 2)
        t.eq(#unmatched, 0)
        t.ok(matches[1].candidate.id ~= matches[2].candidate.id, "distinct candidates")
    end)

    t.test("assign: reports unmatched saved windows", function()
        local matches, unmatched = matcher.assign(
            { saved(1, "Chrome", "Docs"), saved(2, "Figma", "Board") },
            { saved(10, "Chrome", "Docs") })
        t.eq(#matches, 1)
        t.eq(#unmatched, 1)
        t.eq(unmatched[1].app, "Figma")
    end)

    t.test("assign: extra record fields pass through untouched", function()
        local liveWin = { marker = "live" }
        local matches = matcher.assign(
            { saved(1, "Chrome", "Docs") },
            { { id = 1, app = "Chrome", title = "Docs", win = liveWin } })
        t.eq(matches[1].candidate.win.marker, "live")
    end)

    t.test("reused window IDs cannot match another application", function()
        local cand, kind = matcher.findBestMatch(saved(42, "Terminal", "job"),
            {saved(42, "Safari", "job"), saved(7, "Terminal", "job")}, {})
        t.eq(cand.id, 7)
        t.eq(kind, "Exact")
    end)

    t.test("bundle identity survives renamed apps and rejects same-name apps", function()
        local a = {id=1, app="Editor", bundle_id="app.editor", title="Doc"}
        local wrong = {id=1, app="Editor", bundle_id="other.editor", title="Doc"}
        local right = {id=3, app="Renamed Editor", bundle_id="app.editor", title="Doc"}
        local cand, kind = matcher.findBestMatch(a, {wrong, right}, {})
        t.eq(cand, right)
        t.eq(kind, "Exact")
    end)

    t.test("ID confidence requires the same process when both PIDs are known", function()
        local a = {id=1, app="Terminal", pid=100, title="job"}
        local b = {id=1, app="Terminal", pid=200, title="job"}
        local _, kind = matcher.findBestMatch(a, {b}, {})
        t.eq(kind, "Exact")
    end)

    t.test("global priority reserves a later ID match before an earlier slot", function()
        local matches = matcher.assign({saved(1,"Terminal","old"), saved(9,"Terminal","important")},
            {saved(9,"Terminal","changed"), saved(8,"Terminal","scratch")})
        t.eq(matches[1].candidate.id, 8)
        t.eq(matches[2].candidate.id, 9)
        t.eq(matches[2].matchType, "ID")
    end)

    t.test("global priority reserves exact titles before fuzzy matches", function()
        local matches = matcher.assign({saved(1,"Browser","Project"), saved(2,"Browser","Project Plan")},
            {saved(9,"Browser","Project Plan"), saved(8,"Browser","Project scratch")})
        t.eq(matches[1].candidate.id, 8)
        t.eq(matches[2].candidate.id, 9)
        t.eq(matches[2].matchType, "Exact")
    end)
end
