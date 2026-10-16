import("core.project.project")
import("core.project.target", {alias = "target_api"})
import("private.utils.target", {alias = "target_utils"})

local directory = os.scriptdir()
local generation = import("generation", {rootdir = directory})
local batches = import("batches", {rootdir = directory})

-- Standard linkage and C++ generation are independent of native build settings.
local function source_producer(consumer, standard, opt)
    local key = hash.uuid4(string.serialize({
        consumer:data("carven.program"), consumer:data("carven.installed_sources")
    })):lower()
    local name = "carven-standard-" .. key
    local node = project.target(name)
    if node then
        if consumer:data("carven.timings") then node:data_set("carven.timings", true) end
        return node
    end
    local info = assert(table.values(project.scope("target"))[1]):clone()
    for key in pairs(info:info()) do info:set(key, nil) end
    info:set("__scriptdir", os.projectdir())
    node = target_api.new(name, info)
    node:set("kind", "phony")
    node:set("default", false)
    node:set("group", "carven/generation")
    node._RULES = {}
    node:data_set("carven.program", consumer:data("carven.program"))
    node:data_set("carven.sources", consumer:data("carven.standard_sources"))
    node:data_set("carven.batch_target", standard:fullname())
    node:data_set("carven.timings", consumer:data("carven.timings"))
    node:data_set("carven.generated_root",
        path.absolute(path.join(node:autogendir(), "rules", "carven"), os.projectdir()))
    node:data_set("carven.compile_dependfile",
        path.absolute(node:dependfile(node:autogenfile("carven.compile")), os.projectdir()))
    node:add("deps", standard:fullname(), {inherit = false, links = false})
    node:set("prepare", function (target, jobgraph) batches.generate(target, jobgraph) end)
    node:extraconf_set("prepare", {jobgraph = true})
    assert(node:_load())
    assert(node:_load_after())
    target_utils.config_target(node, opt)
    project.target_add(node)
    return node
end

-- Configure the producer itself before deciding whether its native work can be
-- shared. Retain native settings as Xmake values, including grouped flags and
-- explicit false policies; no resolved argv is replayed as raw flags.
local function library_producer(consumer, sources, name, opt)
    local info = assert(table.values(project.scope("target"))[1]):clone()
    for key in pairs(info:info()) do info:set(key, nil) end
    -- Reuse the consumer's own native context, without its downstream interface.
    -- This also keeps packages/options and grouped flag settings producer-private.
    for key, value in pairs(table.clone(consumer:info(), 3)) do
        if not key:startswith("__") then
            value = consumer:get(key)
            if type(value) == "table" then value = table.clone(value, 3) end
        elseif key:startswith("__extra_") then
            for _, config in pairs(value) do
                if type(config) == "table" then
                    config.public, config.interface = nil, nil
                end
            end
        end
        info:set(key, value)
    end
    local excluded = {}
    for _, key in ipairs({
        "rules", "deps", "values", "tests", "pcxxheader", "pcheader",
        "includedirs", "sysincludedirs", "forceincludes",
        "filename", "basename", "configvar", "filegroups", "runargs", "runenv", "runenvs",
    }) do
        excluded[key] = true
    end
    -- Xmake's target APIs identify source/output paths and lifecycle scripts.
    -- Other native compilation settings belong to its common APIs.
    for _, api in ipairs(target_api.apis().paths) do
        excluded[assert(api:match("^target%.[^_]+_(.+)$"))] = true
    end
    for _, api in ipairs(target_api.apis().script) do
        local stage, hook = api:match("^target%.([^_]+)_(.+)$")
        excluded[stage == "on" and hook or hook .. "_" .. stage] = true
    end
    for _, key in ipairs(table.keys(info:info())) do
        local name = key:gsub("^__extra_", ""):gsub("^__override_", ""):gsub("^__sourceinfo_", "")
        if excluded[name] or name:match("^values%.carven%.")
            or name:match("^configvar%.") or name:match("^runenvs?%.") then
            info:set(key, nil)
        end
    end
    -- The shared producer has a global name. Resolve the consumer's relative
    -- native references before leaving its namespace.
    if consumer:namespace() then
        local options, extras = {}, {}
        local configurations = info:get("__extra_options") or {}
        for _, reference in ipairs(table.wrap(info:get("options"))) do
            local option = project.option(reference, {namespace = consumer:namespace()})
            local resolved = option and option:fullname() or reference
            table.insert(options, resolved)
            extras[resolved] = configurations[reference]
        end
        info:set("options", options)
        info:set("__extra_options", extras)
        local toolchains, toolchain_extras = {}, {}
        local configured = consumer:toolchains()
        local configurations = info:get("__extra_toolchains") or {}
        for index, reference in ipairs(table.wrap(info:get("toolchains"))) do
            local resolved = reference
            -- Xmake resolves installed toolchains first, then global project
            -- toolchains, then the consumer's namespace.
            if not configured[index]:is_builtin() and not project.toolchain(reference) then
                resolved = consumer:namespace() .. "::" .. reference
            end
            table.insert(toolchains, resolved)
            toolchain_extras[resolved] = configurations[reference]
        end
        info:set("toolchains", toolchains)
        info:set("__extra_toolchains", toolchain_extras)
    end
    local node = target_api.new(name, info)
    node:set("kind", "static")
    node:set("default", false)
    node:set("group", "carven/stdlib")
    node:data_set("inherit.links.exportlinks", false)
    if not node:is_plat("windows", "mingw") then
        node:add("cxflags", "-fPIC", {tools = {"gcc", "clang"}})
    end
    local root = sources:data("carven.generated_root")
    -- Standard-library sources use their generated interfaces and installed Crafts.
    node:add("includedirs", root, path.directory(consumer:data("carven.installed_sources")))
    if node:is_plat("windows", "mingw") then
        node:add("syslinks", "ws2_32", {public = true})
    end
    for _, source in ipairs(consumer:data("carven.standard_sources")) do
        local input = generation.source_input(source, consumer:data("carven.installed_sources"), os.projectdir())
        node:add("files", path.join(root, input.implementation), {always_added = true})
    end
    for _, source in ipairs(generation.inventory(consumer:data("carven.installed_sources")).cpp) do
        node:add("files", source)
    end
    node:add("deps", sources:fullname(), {inherit = false, links = false})
    node:set("prepare_before", function (target, jobgraph)
        batches.add_job(target, jobgraph, {sources:fullname()}, function () end)
    end)
    node:extraconf_set("prepare_before", {jobgraph = true})
    node:data_set("carven.program", consumer:data("carven.program"))
    node:data_set("carven.installed_sources", consumer:data("carven.installed_sources"))
    local rule = assert(consumer:rule("c++"))
    node:rule_add(rule)
    for _, dependency in ipairs(rule:orderdeps()) do
        node:rule_add(dependency)
    end
    assert(node:_load())
    assert(node:_load_after())
    target_utils.config_target(node, opt)
    return node
end

local function compilation_identity(node)
    local native = node:compiler("cxx")
    local identity = {
        node:data("carven.program"),
        node:data("carven.installed_sources"),
        node:plat(),
        node:arch(),
        native:name(),
        native:program(),
    }
    for _, toolchain in ipairs(node:toolchains()) do
        table.insert(identity, toolchain:fullname())
    end
    local environments = native:runenvs() or {}
    for _, name in ipairs(table.orderkeys(environments)) do
        table.insert(identity, {name, table.wrap(environments[name])})
    end
    table.join2(identity, native:compflags({target = node}))
    return hash.uuid4(string.serialize(identity)):lower()
end

function attach(target, standard, opt)
    local sources = source_producer(target, standard, opt)
    local candidate = library_producer(target, sources, "carven-stdlib-candidate", opt)
    local key = compilation_identity(candidate)
    local name = "carven-stdlib-" .. key
    local node = project.target(name)
    if not node then
        -- Configure under the permanent name so Xmake owns stable source,
        -- object and dependency paths independently of the first consumer.
        node = library_producer(target, sources, name, opt)
        project.target_add(node)
    end
    target:add("deps", node:fullname())
    target:data_set("carven.stdlib_target", node:fullname())
end
