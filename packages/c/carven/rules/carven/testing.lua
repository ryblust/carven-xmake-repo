local project = import("core.project.project")
local target_utils = import("private.utils.target")
local generation = import("generation", {rootdir = os.scriptdir()})

local function test_name(target)
    -- Xmake test IDs use short target names; include the namespace in the label.
    local namespace = target:namespace()
    return namespace and (namespace:gsub("::", "/") .. "/inline") or "inline"
end

local function register(target, opt)
    local name = target:fullname() .. ".tests"
    assert(not project.target(name), "carven: inline-test target already exists: " .. name)
    local suite = target:clone()
    suite:name_set(name)
    suite:set("kind", "binary")
    suite:set("default", false)
    -- The suite inherits compilation settings; executions belong to each entry.
    for _, field in ipairs({"tests", "test", "test_before", "test_after", "runargs", "filename", "basename"}) do
        suite:set(field, nil)
    end
    suite:extraconf_set("tests", {})
    suite:extraconf_set("rules", "@carven/carven", "tests", true)
    suite:add("tests", test_name(target))
    target_utils.config_target(suite, opt)
    local targets = project.targets()
    local previous = targets[suite:name()]
    project.target_add(suite)
    if suite:namespace() then
        -- target_add indexes by short name; dependency lookup uses full names.
        targets[suite:fullname()] = suite
        targets[suite:name()] = previous
    end
end

local function selection()
    local argv = xmake.argv()
    if argv[1] ~= "test" then return false end
    local option = import("core.base.option")
    -- Configuration runs inside a nested task. Parse the outer invocation once
    -- with Xmake's test menu, including its native group, name and job options.
    return option.raw_parse(table.slice(argv, 2), option.taskmenu("test").options,
        {populate_defaults = true})
end

local function matches(target, options)
    if options.group then
        local group = target:get("group")
        if not group or not group:match("^" .. path.pattern(options.group) .. "$") then return false end
    end
    if options.tests then
        local name = target:name() .. ".tests/" .. test_name(target)
        for _, pattern in ipairs(options.tests) do
            if name:match("^" .. path.pattern(pattern) .. "$") then return true end
        end
        return false
    end
    return true
end

function discover(target, opt)
    if _g.selection == nil then _g.selection = selection() end
    if not _g.selection then return end
    if not _g.pending then
        _g.pending, _g.candidates = {}, {}
        for _, original in ipairs(project.ordertargets()) do
            if original:is_enabled() and original:rule("@carven/carven")
                and original:extraconf("rules", "@carven/carven", "tests") == nil
                and matches(original, _g.selection) then
                _g.pending[original] = true
            end
        end
    end
    -- Collect only selected automatic suites. Later clones are not candidates.
    if not _g.pending[target] then return end
    _g.pending[target] = nil
    if #(target:data("carven.sources") or {}) > 0 then
        table.insert(_g.candidates, target)
    end
    if not table.empty(_g.pending) then return end
    local candidates = _g.candidates
    _g.candidates = nil

    -- Submit selected producers together so Xmake can prepare them in parallel.
    -- Their output paths are fixed at creation; later consumers only reuse them.
    local roots = {}
    for _, candidate in ipairs(candidates) do
        local producer = assert(project.target(candidate:data("carven.batch_target")))
        table.insert(roots, producer)
        if _g.selection.rebuild then
            producer:data_set("rebuilt", true)
            for _, dep in ipairs(producer:orderdeps()) do dep:data_set("rebuilt", true) end
        end
    end
    if #roots == 0 then return end
    import("private.action.build.target").run_targetjobs(roots, {
        job_kind = "prepare", jobs = tonumber(_g.selection.jobs) or os.default_njob(),
    })
    for _, candidate in ipairs(candidates) do
        local producer = project.target(candidate:data("carven.batch_target"))
        local manifest = path.join(producer:data("carven.batch_root"), "carven", "manifest.json")
        if generation.read_manifest(manifest).runtime_test_count > 0 then register(candidate, opt) end
    end
end
