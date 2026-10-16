import("core.base.json")

local function without_paths(values, removed)
    local paths, kept = {}, {}
    for _, value in ipairs(removed) do paths[path.absolute(value, os.projectdir())] = true end
    for _, value in ipairs(table.wrap(values)) do
        if not paths[path.absolute(value, os.projectdir())] then table.insert(kept, value) end
    end
    return kept
end

-- Reconfigure rule-owned inputs and edges when Xmake clones a target.
function reset(target)
    local generated = target:data("carven.generated_files") or {}
    if #generated > 0 then target:set("files", without_paths(target:get("files"), generated)) end
    local root = target:data("carven.generated_root")
    if root then target:set("includedirs", without_paths(target:get("includedirs"), {root})) end
    local batch, stdlib = target:data("carven.batch_target"), target:data("carven.stdlib_target")
    if batch or stdlib then
        local dependencies = table.copy(table.wrap(target:get("deps")))
        table.remove_if(dependencies, function (_, name) return name == batch or name == stdlib end)
        target:set("deps", dependencies)
        target:data_set("carven.batch_target", nil)
        target:data_set("carven.stdlib_target", nil)
    end
end

function source_input(sourcefile, installed_sources, projectdir)
    local physical = path.unix(path.absolute(sourcefile, projectdir))
    local argument = path.unix(path.relative(physical, projectdir))
    local prefix = path.unix(installed_sources) .. "/"
    local logical
    if physical:startswith(prefix) then
        logical = "crafts/carven/" .. physical:sub(#prefix + 1)
    elseif not path.is_absolute(argument) and argument ~= ".." and not argument:startswith("../") then
        logical = argument
    else
        raise("carven: source path is outside the project and crafts: " .. tostring(sourcefile))
    end
    local module = logical:sub(1, -4):gsub("/", ".")
    return {path = argument, module = module, implementation = module:gsub("%.", "/") .. ".cpp"}
end

-- Share input reads within one build, but hash fresh bytes in each new process.
-- Timestamps and sizes cannot identify content after a preserved-mtime edit.
function signatures(files)
    _g.signatures = _g.signatures or {}
    local values = {}
    for _, file in ipairs(files) do
        local absolute = path.absolute(file, os.projectdir())
        table.insert(values, absolute)
        local digest = _g.signatures[absolute]
        if not digest then
            assert(os.isfile(absolute), "carven: missing generation input: " .. absolute)
            digest = hash.xxhash128(absolute)
            _g.signatures[absolute] = digest
        end
        table.insert(values, digest)
    end
    return values
end

function invalidate_signatures(files)
    for _, file in ipairs(files) do
        if _g.signatures then _g.signatures[path.absolute(file, os.projectdir())] = nil end
    end
end

function inventory(root)
    _g.inventories = _g.inventories or {}
    local absolute = path.absolute(root, os.projectdir())
    local cached = _g.inventories[absolute]
    if not cached then
        cached = {cv = os.files(path.join(absolute, "**.cv")), cpp = os.files(path.join(absolute, "**.cpp"))}
        table.sort(cached.cv)
        table.sort(cached.cpp)
        _g.inventories[absolute] = cached
    end
    return cached
end

function input_paths(files)
    local result, seen = {}, {}
    for _, file in ipairs(files) do
        local absolute = path.absolute(file, os.projectdir())
        if not seen[absolute] then
            seen[absolute] = true
            table.insert(result, absolute)
        end
    end
    table.sort(result)
    return result
end

function read_manifest(filename)
    return assert(json.loadfile(filename))
end

function semantic_inputs(root)
    local manifest = path.join(root, "carven", "manifest.json")
    local files = {manifest}
    for _, artifact in ipairs(read_manifest(manifest).artifacts) do
        if artifact.role == "semantic-ir" then table.insert(files, path.join(root, artifact.path)) end
    end
    return files
end

function refresh_dependencies(target)
    local project = import("core.project.project")
    -- Refresh dependent targets once after configuring all generated dependencies.
    for _, consumer in pairs(project.targets()) do
        if consumer ~= target and (consumer:dep(target:name()) == target
            or consumer:dep(target:fullname()) == target) then
            consumer:set("deps", consumer:get("deps"))
        end
    end
end

function run(program, argv, timings, label)
    local stderr_file = timings and os.tmpfile() or nil
    try {
        function ()
            os.vrunv(program, argv, {curdir = os.projectdir(), stderr = stderr_file})
        end,
        finally {
            function (ok, errors)
                if stderr_file then
                    local output = io.readfile(stderr_file) or ""
                    if output ~= "" then
                        io.stderr:write("\ncarven target: " .. label .. "\n" .. output:gsub("^\r?\n", ""))
                        io.stderr:flush()
                    end
                    os.tryrm(stderr_file)
                end
                if not ok then raise(errors) end
            end
        }
    }
end

-- Each consumer owns its native realization of the shared checked program.
function generate(target, request, opt)
    local option = import("core.base.option")
    local depend = import("core.project.depend")
    local progress = import("utils.progress")
    if option.get("dry-run") then
        print(os.args(table.join(request.program, request.argv)))
        return
    end
    local inputs = request.inputs or table.join(semantic_inputs(request.batch), {request.program})
    inputs = input_paths(inputs)
    local values = table.join(request.argv, signatures(inputs))
    local manifest = path.join(request.root, "carven", "manifest.json")
    local facts = os.isfile(manifest) and read_manifest(manifest) or nil
    local files = {}
    for _, artifact in ipairs(facts and facts.artifacts or {}) do
        table.insert(files, path.join(request.root, artifact.path))
    end
    table.insert(files, manifest)
    depend.on_changed(function ()
        progress.set_target(opt.progress, target)
        progress.show(opt.progress or 0, request.analysis and "${color.build.object}compiling.cv %s"
            or "${color.build.object}generating.cpp %s", target:name())
        try {
            function ()
                os.tryrm(request.staging)
                os.mkdir(request.staging)
                run(request.program, request.argv, request.timings, target:fullname())
                local facts = read_manifest(path.join(request.staging, "carven", "manifest.json"))
                local paths = {}
                for _, artifact in ipairs(facts.artifacts) do table.insert(paths, artifact.path) end
                table.insert(paths, "carven/manifest.json")
                local desired = {}
                table.clear(files)
                for _, logical in ipairs(paths) do
                    local destination = path.join(request.root, logical)
                    desired[logical] = true
                    os.mkdir(path.directory(destination))
                    os.cp(path.join(request.staging, logical), destination, {copy_if_different = true})
                    table.insert(files, destination)
                end
                for _, file in ipairs(os.files(path.join(request.root, "**"))) do
                    if not desired[path.unix(path.relative(file, request.root))] then os.tryrm(file) end
                end
                invalidate_signatures(files)
            end,
            finally {
                function (ok, errors)
                    os.tryrm(request.staging)
                    if not ok then raise(errors) end
                end
            }
        }
    end, {
        dependfile = request.dependfile,
        files = files,
        values = values,
        changed = opt.rebuild or target:is_rebuilt() or request.analysis and facts and not facts.cacheable,
    })
end
