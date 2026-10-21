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
    local files = table.copy(generation.inventory(target:data("carven.installed_sources")).cpp)
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

-- A consumer owns its source implementations. Published C++ interfaces are also
-- callable roots: their callers can live outside the generated Carven program.
function select_implementations(target)
    local option = import("core.base.option")
    if option.get("dry-run") then return end
    local standard_root = target:data("carven.standard_root")
    local graph, roots = {}, {}
    for _, root in ipairs({standard_root, target:data("carven.generated_root")}) do
        local standard = root == standard_root
        local manifest = generation.read_manifest(path.join(root, "carven", "manifest.json"))
        for _, artifact in ipairs(manifest.artifacts) do
            if artifact.role == "module-implementation" or artifact.role == "test-entry" then
                assert(not graph[artifact.path], "carven: duplicate implementation: " .. artifact.path)
                graph[artifact.path] = {file = path.join(root, artifact.path),
                    dependencies = artifact.link_dependencies, standard = standard}
                if not standard then table.insert(roots, artifact.path) end
            elseif standard and artifact.role == "cpp-api-header" then
                table.join2(roots, artifact.link_dependencies)
            end
        end
    end
    local files = table.copy(generation.inventory(target:data("carven.installed_sources")).cpp)
    local seen, next_root = {}, 1
    while next_root <= #roots do
        local name = roots[next_root]
        next_root = next_root + 1
        if not seen[name] then
            seen[name] = true
            local implementation = assert(graph[name], "carven: missing implementation: " .. name)
            if implementation.standard then
                target:extraconf_set("files", implementation.file, {always_added = true})
                table.insert(files, implementation.file)
            end
            table.join2(roots, implementation.dependencies)
        end
    end
    table.sort(files)
    target:set("files", generation.without_paths(target:get("files"), target:data("carven.standard_files")))
    target:add("files", files)
    target:data_set("carven.standard_files", files)
end
