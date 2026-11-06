return function(t, root)
    local displays = dofile(root .. "SnapBack.spoon/displays.lua")
    local geometry = dofile(root .. "SnapBack.spoon/geometry.lua")

    t.test("config keys survive display order and numeric ID changes", function()
        t.eq(displays.configId({{id=1,uuid="B"},{id=2,uuid="A"}}),
            displays.configId({{id=300,uuid="A"},{id=200,uuid="B"}}))
        t.eq(displays.legacyId({{id=200},{id=30}}), "30_200")
        t.eq(displays.configId({{id=1}}), "uuid:id:1")
        t.ok(displays.configId({{id=1,uuid="A"}}) ~= displays.configId({{id=2,uuid="B"}}))
    end)

    t.test("screen UUID wins; duplicate name or UUID fallbacks are rejected", function()
        local screens = {{uuid="A",name="Dell"},{uuid="B",name="Dell"}}
        t.eq(displays.resolve({screen_uuid="B",screen="Dell"}, screens), screens[2])
        local screen, reason = displays.resolve({screen_uuid="old",screen="Dell"}, screens)
        t.eq(screen, nil)
        t.eq(reason, "ambiguous_name")
        t.eq(displays.resolve({screen="Laptop"}, screens), nil)
        t.eq(displays.resolve({screen="Dell"}, {screens[1]}), screens[1])
        t.eq(displays.resolve({screen_uuid="A"}, {screens[1],screens[1]}), nil)
    end)

    t.test("relative geometry survives reordered, negative-origin and resized displays", function()
        local unit = geometry.unitFrame({x=1100,y=100,w=500,h=400}, {x=1000,y=0,w=1000,h=800})
        local frame = geometry.restoreFrame({unit_frame=unit}, {x=-2000,y=30,w=2000,h=1600})
        t.eq(frame, {x=-1800,y=230,w=1000,h=800})
    end)

    t.test("legacy and relative frames stay within the target usable screen", function()
        local screen = {x=-1000,y=30,w=1000,h=700}
        t.eq(geometry.restoreFrame({frame={x=3000,y=-100,w=2000,h=2000}},screen), screen)
        t.eq(geometry.restoreFrame({unit_frame={x=-1,y=2,w=0.5,h=0.5}},screen),
            {x=-1000,y=380,w=500,h=350})
        t.eq(pcall(geometry.restoreFrame, {frame={}},screen), false)
        t.eq(pcall(geometry.restoreFrame, {unit_frame={x=0,y=0,w=0/0,h=1}},screen), false)
    end)
end
