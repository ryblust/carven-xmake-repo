import("core.project.project")
import("core.project.target", {alias = "target_api"})
import("private.utils.target", {alias = "target_utils"})

local function encode(values)
    local encoded = {}
    for _, value in ipairs(values) do
        table.insert(encoded, #value .. ":" .. value)
    end
    return table.concat(encoded)
end

local function prerequisites(target)
    local previous = target:data("carven.stdlib_target")
    local names, dependencies = {}, {}
    for _, name in ipairs(table.wrap(target:get("deps"))) do
        local dependency = assert(target:dep(name))
        if dependency:fullname() ~= previous then
            table.insert(names, name)
            table.insert(dependencies, {
                name = dependency:fullname(),
                links = target:extraconf("deps", name, "links"),
                inherit = target:extraconf("deps", name, "inherit"),
            })
        end
    end
    if previous then target:set("deps", names) end
    return dependencies
end

-- Configure the producer itself before deciding whether its native work can be
-- shared. Retain native settings as Xmake values, including grouped flags and
-- explicit false policies; no resolved argv is replayed as raw flags.
local function library_producer(consumer, name, dependencies, opt)
    local scope = assert(table.values(project.scope("target"))[1])
    local info = scope:clone()
    for key in pairs(info:info()) do info:set(key, nil) end
    for key, value in pairs(table.clone(consumer:info(), 3)) do
        info:set(key, value)
    end
    local excluded = {}
    for _, key in ipairs({"rules", "deps", "values", "tests", "pcxxheader", "pcheader",
                          "filename", "basename", "configvar", "filegroups", "runargs", "runenv", "runenvs"}) do
        excluded[key] = true
    end
    -- Xmake's target APIs identify source/output paths and lifecycle scripts.
    -- Native include paths and compilation settings belong to its common APIs.
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
    local node = target_api.new(name, info)
    node:set("kind", "object")
    node:set("default", false)
    node:set("group", "carven/stdlib")
    if not node:is_plat("windows", "mingw") then
        node:add("cxflags", "-fPIC", {tools = {"gcc", "clang"}})
    end
    local generated = path.absolute(path.join(consumer:autogendir(), "rules", "carven"), os.projectdir())
    local includedirs = {}
    for _, directory in ipairs(table.wrap(node:get("includedirs"))) do
        if path.absolute(directory, os.projectdir()) ~= generated then table.insert(includedirs, directory) end
    end
    node:set("includedirs", includedirs)
    local pcheader = consumer:data("carven.pcheader")
    if pcheader then node:add("forceincludes", pcheader) end
    for _, dependency in ipairs(dependencies) do
        node:add("deps", dependency.name, {inherit = dependency.inherit, links = dependency.links})
    end
    node:values_set("carven.program", consumer:data("carven.program"))
    node:values_set("carven.craftsdir", path.directory(consumer:data("carven.installed_sources")))
    node:data_set("carven.stdlib_node", true)
    local rule = assert(consumer:rule("@carven/carven"))
    node:rule_add(rule)
    for _, dependency in ipairs(rule:orderdeps()) do node:rule_add(dependency) end
    assert(node:_load())
    assert(node:_load_after())
    target_utils.config_target(node, opt)
    return node
end

local function compilation_identity(node, dependencies)
    local native = node:compiler("cxx")
    local identity = {
        node:data("carven.program"), node:data("carven.installed_sources"),
        node:plat(), node:arch(), native:name(), native:program(),
    }
    for _, toolchain in ipairs(node:toolchains()) do table.insert(identity, toolchain:fullname()) end
    local environments = native:runenvs() or {}
    for _, name in ipairs(table.orderkeys(environments)) do
        table.insert(identity, encode({name, encode(table.wrap(environments[name]))}))
    end
    for _, dependency in ipairs(dependencies) do
        table.insert(identity, encode({dependency.name, tostring(dependency.links), tostring(dependency.inherit)}))
    end
    -- The producer's own generated include directory contains the same library
    -- interface for a shared domain. Normalize only this location in its argv.
    local generated = path.join(node:autogendir(), "rules", "carven")
    for _, flag in ipairs(native:compflags({target = node})) do
        flag = flag:replace(path.absolute(generated, os.projectdir()), "<carven-library>", {plain = true})
        flag = flag:replace(generated, "<carven-library>", {plain = true})
        table.insert(identity, flag)
    end
    return hash.uuid4(encode(identity)):lower()
end

function attach(target, opt)
    if target:data("carven.stdlib_node") then return end
    local dependencies = prerequisites(target)
    local candidate = library_producer(target, "carven-stdlib-candidate", dependencies, opt)
    local key = compilation_identity(candidate, dependencies)
    local name = "carven-stdlib-" .. key
    local node = project.target(name)
    local domain = "carven-installed-stdlib:" .. key
    if not node then
        -- Configure under the permanent name so Xmake owns stable source,
        -- object and dependency paths independently of the first consumer.
        node = library_producer(target, name, dependencies, opt)
        node:data_set("carven.library_domain", domain)
        project.target_add(node)
    end
    target:add("deps", node:fullname(), {inherit = false})
    target:data_set("carven.library_domain", domain)
    target:data_set("carven.stdlib_target", node:fullname())
end
