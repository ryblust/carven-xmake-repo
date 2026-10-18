import("core.project.project")
import("core.project.target", {alias = "target_api"})
import("private.utils.target", {alias = "target_utils"})

local directory = os.scriptdir()
local generation = import("generation", {rootdir = directory})
local batches = import("batches", {rootdir = directory})

-- Share generated standard-library text; consumers retain their native settings.
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
    node:data_set("carven.progress_label", "Carven standard library")
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

-- The shared producer owns C++ generation. Consumers compile those sources
-- directly, so Xmake keeps their final settings, dependencies and object paths.
function attach(target, standard, opt)
    local sources = source_producer(target, standard, opt)
    local root = sources:data("carven.generated_root")
    local files = {}
    for _, source in ipairs(target:data("carven.standard_sources")) do
        local input = generation.source_input(source, target:data("carven.installed_sources"), os.projectdir())
        local implementation = path.join(root, input.implementation)
        target:extraconf_set("files", implementation, {always_added = true})
        table.insert(files, implementation)
    end
    table.join2(files, generation.inventory(target:data("carven.installed_sources")).cpp)
    target:add("files", files)
    target:add("includedirs", root, {public = true})
    if target:is_plat("windows", "mingw") then
        target:add("syslinks", "ws2_32", {public = true})
    end
    target:add("deps", sources:fullname(), {inherit = false, links = false})
    target:data_set("carven.standard_target", sources:fullname())
    target:data_set("carven.standard_files", files)
    target:data_set("carven.standard_root", root)
end
