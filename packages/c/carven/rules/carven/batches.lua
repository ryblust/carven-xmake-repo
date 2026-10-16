import("core.project.config")
import("core.project.project")
import("core.project.target", {alias = "target_api"})
import("private.utils.target", {alias = "target_utils"})

local directory = os.scriptdir()
local generation = import("generation", {rootdir = directory})

function add_job(target, jobgraph, dependencies, run)
    local name = target:fullname() .. "/carven"
    jobgraph:add(name, function (_, _, opt) run(target, opt) end)
    -- Xmake may register consumers before producers. Keep unresolved edges in
    -- this preparation graph and connect them when the producer is registered.
    local pending = jobgraph.carven_pending or {}
    jobgraph.carven_pending = pending
    for _, consumer in ipairs(pending[name] or {}) do
        jobgraph:add_orders(name, consumer)
    end
    pending[name] = nil
    for _, dependency in ipairs(dependencies) do
        local producer = dependency .. "/carven"
        if jobgraph:has(producer) then
            jobgraph:add_orders(producer, name)
        else
            pending[producer] = pending[producer] or {}
            table.insert(pending[producer], name)
        end
    end
end

function invocation(target)
    if #(target:data("carven.sources") or {}) == 0 then return nil end
    local producer = assert(project.target(target:data("carven.batch_target")))
    local batch = producer:data("carven.batch_root")
    local root = target:data("carven.generated_root")
    local staging = root .. ".staging"
    local argv = {"compile", batch, "-o", staging}
    if target:data("carven.timings") then
        table.insert(argv, "--timings")
    end
    local tests = target:data("carven.tests")
    if tests == true then
        table.insert(argv, "--tests")
    elseif tests == "runner" then
        table.insert(argv, "--tests=runner")
    end
    return {
        program = target:data("carven.program"),
        batch = batch,
        root = root,
        staging = staging,
        argv = argv,
        dependfile = target:data("carven.compile_dependfile"),
        timings = target:data("carven.timings"),
    }
end

function generate(target, jobgraph)
    local request = invocation(target)
    if not request then return end
    add_job(target, jobgraph, {target:data("carven.batch_target")}, function (target, opt)
        generation.generate(target, request, opt)
    end)
end

local function prepare(node, opt)
    -- Discovery and build use separate job graphs in one invocation. Reuse this
    -- successful preparation even when the batch cannot be cached across commands.
    if node:data("carven.prepared") then return end
    local option = import("core.base.option")
    local root = node:data("carven.batch_root")
    local staging = root .. ".staging"
    local argv = {"check"}
    local inputs = table.join(node:data("carven.sources"), {node:data("carven.program")})
    for _, name in ipairs(table.wrap(node:get("deps"))) do
        local dependency = assert(project.target(name)):data("carven.batch_root")
        table.insert(argv, dependency)
        if not option.get("dry-run") then
            inputs = table.join(inputs, generation.semantic_inputs(dependency))
        end
    end
    table.join2(argv, node:data("carven.source_arguments"))
    table.join2(argv, {"-o", staging})
    if node:data("carven.timings") then
        table.insert(argv, "--timings")
    end
    generation.generate(node, {
        program = node:data("carven.program"),
        root = root,
        staging = staging,
        argv = argv,
        inputs = inputs,
        analysis = true,
        dependfile = root .. ".depend",
        timings = node:data("carven.timings"),
    }, opt)
    node:data_set("carven.prepared", true)
end

local function producer(consumer, sources, arguments, dependencies, opt)
    local program = consumer:data("carven.program")
    local identity = table.join({program}, arguments)
    for _, dependency in ipairs(dependencies) do
        table.insert(identity, dependency:fullname())
    end
    local key = hash.uuid4(string.serialize(identity)):lower()
    local name = "carven-batch-" .. key
    local node = project.target(name)
    if node then
        if consumer:data("carven.timings") then
            node:data_set("carven.timings", true)
        end
        return node
    end
    local info = assert(table.values(project.scope("target"))[1]):clone()
    for key in pairs(info:info()) do info:set(key, nil) end
    info:set("__scriptdir", os.projectdir())
    node = target_api.new(name, info)
    node:set("kind", "phony")
    node:set("default", false)
    node:set("group", "carven/generation")
    -- Match Xmake's target loader for a target with no source or target rules.
    node._RULES = {}
    node:set("prepare", function (target, jobgraph)
        add_job(target, jobgraph, table.wrap(target:get("deps")), prepare)
    end)
    node:extraconf_set("prepare", {jobgraph = true})
    node:data_set("carven.program", program)
    node:data_set("carven.sources", sources)
    node:data_set("carven.source_arguments", arguments)
    node:data_set("carven.timings", consumer:data("carven.timings"))
    node:data_set("carven.batch_root",
        path.absolute(path.join(config.builddir(), ".carven", "batches", key), os.projectdir()))
    for _, dependency in ipairs(dependencies) do
        node:add("deps", dependency:fullname(), {inherit = false, links = false})
    end
    assert(node:_load())
    assert(node:_load_after())
    target_utils.config_target(node, opt)
    project.target_add(node)
    return node
end

function standard(target, opt)
    local sources = target:data("carven.standard_sources")
    local arguments = {}
    for _, source in ipairs(sources) do
        local input = generation.source_input(source, target:data("carven.installed_sources"), os.projectdir())
        table.insert(arguments, "--source=" .. input.module .. "=" .. input.path)
    end
    table.sort(arguments)
    return producer(target, sources, arguments, {}, opt)
end

function attach(target, standard, opt)
    local node = producer(
        target,
        target:data("carven.sources"),
        target:data("carven.source_arguments"),
        {standard},
        opt
    )
    target:add("deps", node:fullname(), {inherit = false, links = false})
    target:data_set("carven.batch_target", node:fullname())
end
