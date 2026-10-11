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
            })
        end
    end
    if previous then target:set("deps", names) end
    return dependencies
end

local function compilation(target, dependencies)
    local native = target:compiler("cxx")
    -- A temporary native configuration view has no jobs or project identity.
    -- PCH changes compilation cost, so preserve its header as a normal include.
    local view = target:clone()
    local generated = path.absolute(path.join(target:autogendir(), "rules", "carven"))
    local includedirs = {}
    for _, directory in ipairs(table.wrap(view:get("includedirs"))) do
        if path.absolute(directory) ~= generated then table.insert(includedirs, directory) end
    end
    view:set("includedirs", includedirs)
    view:set("pcxxheader", {})
    local pcheader = target:data("carven.pcheader")
    if pcheader then view:add("forceincludes", pcheader) end
    local flags = native:compflags({target = view, targetkind = "shared"})

    local identity = {
        target:data("carven.program"), target:data("carven.installed_sources"),
        target:plat(), target:arch(), native:name(), native:program(),
    }
    for _, toolchain in ipairs(target:toolchains()) do
        table.insert(identity, toolchain:fullname())
    end
    local environments = native:runenvs() or {}
    local names = table.keys(environments)
    table.sort(names)
    for _, name in ipairs(names) do
        table.insert(identity, encode({name, encode(table.wrap(environments[name]))}))
    end
    -- Sharing also preserves the native prerequisite graph. Merging consumers'
    -- dependencies can make a library depend on one of its own consumers.
    for _, dependency in ipairs(dependencies) do
        table.insert(identity, encode({dependency.name, tostring(dependency.links)}))
    end
    table.join2(identity, flags)
    return hash.uuid4(encode(identity)):lower(), flags, native
end

local function create_target(consumer, name, domain, flags, native, dependencies, opt)
    -- Native target scopes carry the constructor's API metadata. Any declared
    -- target supplies it; producer settings and hooks start empty.
    local scope = table.values(project.scope("target"))[1]
    local info = assert(scope, "carven: project has no target scope"):clone()
    for key in pairs(info:info()) do info:set(key, nil) end
    local node = target_api.new(name, info)
    node:set("kind", "object")
    node:set("default", false)
    node:set("group", "carven/stdlib")
    node:set("plat", consumer:plat())
    node:set("arch", consumer:arch())
    for _, toolchain in ipairs(table.wrap(consumer:get("toolchains"))) do
        node:add("toolchains", toolchain, table.clone(consumer:extraconf("toolchains", toolchain) or {}))
    end
    node:set("toolset.cxx", native:name() .. "@" .. native:program())
    node:add("cxxflags", flags, {force = true})
    for _, dependency in ipairs(dependencies) do
        node:add("deps", dependency.name, {inherit = false, links = dependency.links})
    end
    node:values_set("carven.program", consumer:data("carven.program"))
    node:values_set("carven.craftsdir", path.directory(consumer:data("carven.installed_sources")))
    node:data_set("carven.stdlib_node", true)
    node:data_set("carven.library_domain", domain)
    local rule = assert(consumer:rule("@carven/carven"))
    node:rule_add(rule)
    for _, dependency in ipairs(rule:orderdeps()) do node:rule_add(dependency) end
    project.target_add(node)
    -- Registration does not load a dynamically added target. Use Xmake's
    -- lifecycle before its native configuration runner.
    assert(node:_load())
    assert(node:_load_after())
    target_utils.config_target(node, opt)
    return node
end

function attach(target, opt)
    if target:data("carven.stdlib_node") then return end
    local dependencies = prerequisites(target)
    local key, flags, native = compilation(target, dependencies)
    local name = "carven-stdlib-" .. key
    local domain = "carven-installed-stdlib:" .. key
    local node = project.target(name)
    if not node then node = create_target(target, name, domain, flags, native, dependencies, opt) end
    target:add("deps", node:fullname(), {inherit = false})
    target:data_set("carven.library_domain", domain)
    target:data_set("carven.stdlib_target", node:fullname())
end
