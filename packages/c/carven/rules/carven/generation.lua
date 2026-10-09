import("core.base.json")

-- A build observes one source snapshot. Share its hashes across consumers of the
-- same compiler and Crafts without persisting timestamp-only content guesses.
function signatures(files)
    _g.signatures = _g.signatures or {}
    local values = {}
    for _, file in ipairs(files) do
        local absolute = path.absolute(file)
        assert(os.isfile(absolute), "carven: missing generation input: " .. absolute)
        local mtime, size = os.mtime(absolute), os.filesize(absolute)
        local cached = _g.signatures[absolute]
        if not cached or cached.mtime ~= mtime or cached.size ~= size then
            cached = {mtime = mtime, size = size, digest = hash.sha256(absolute)}
            _g.signatures[absolute] = cached
        end
        table.insert(values, absolute)
        table.insert(values, cached.digest)
    end
    return values
end

function inventory(root)
    _g.inventories = _g.inventories or {}
    local absolute = path.absolute(root)
    local cached = _g.inventories[absolute]
    if not cached then
        cached = {cv = os.files(path.join(absolute, "**.cv")), cpp = os.files(path.join(absolute, "**.cpp"))}
        table.sort(cached.cv)
        table.sort(cached.cpp)
        _g.inventories[absolute] = cached
    end
    return cached
end

function manifest(filename, staging_root, inputs, implementations)
    local facts = assert(json.loadfile(filename), "carven: compiler did not write its artifact manifest")
    assert(facts.version == 1 and type(facts.inputs) == "table" and type(facts.artifacts) == "table",
        "carven: unsupported compiler artifact manifest")
    assert(type(facts.workspace) == "table" and type(facts.workspace.root) == "string"
        and path.absolute(facts.workspace.root) == os.curdir(), "carven: manifest workspace does not match the project")
    local function source_key(source, root)
        local absolute = path.absolute(source, root)
        local relative = path.unix(path.relative(absolute, os.projectdir()))
        if relative ~= ".." and relative:sub(1, 3) ~= "../" and not path.is_absolute(relative) then
            absolute = path.absolute(relative, facts.workspace.root)
        end
        return absolute
    end
    local expected = {}
    for _, source in ipairs(inputs) do expected[source_key(source.path, os.projectdir())] = source.module end
    for _, input in ipairs(facts.inputs) do
        assert(type(input.path) == "string" and type(input.module) == "string",
            "carven: invalid manifest input")
        local absolute = source_key(input.path, facts.workspace.root)
        assert(expected[absolute] == input.module, "carven: unexpected or duplicate manifest input: " .. input.path)
        expected[absolute] = nil
    end
    -- The compiler deduplicates physical files. Selected symlink aliases may
    -- therefore be absent from its actual input inventory; all selected
    -- spellings still participate in the generation content signatures.

    local extensions = {
        ["interface"] = ".hpp", ["cpp-api-header"] = ".hpp",
        ["module-implementation"] = ".cpp", ["test-runner-header"] = ".hpp", ["test-entry"] = ".cpp",
    }
    local paths, seen, native = {}, {}, {}
    for _, logical in ipairs(implementations) do native[logical] = true end
    for _, artifact in ipairs(facts.artifacts) do
        local logical = artifact.path
        assert(type(logical) == "string" and #logical > 0 and not path.is_absolute(logical)
            and not logical:find("\\", 1, true) and not logical:find(":", 1, true),
            "carven: invalid manifest artifact path")
        for component in logical:gmatch("[^/]+") do
            assert(component ~= "." and component ~= "..", "carven: nonlocal manifest artifact path")
        end
        assert(not logical:find("//", 1, true) and not seen[logical]
            and extensions[artifact.role] == path.extension(logical), "carven: invalid manifest artifact")
        assert(artifact.source_mapping == "stable-interface" or artifact.source_mapping == "source-attributed",
            "carven: invalid manifest source mapping")
        assert(os.isfile(path.join(staging_root, logical)), "carven: missing staged artifact: " .. logical)
        if artifact.role == "module-implementation" or artifact.role == "test-entry" then
            assert(native[logical], "carven: compiler emitted an unregistered native source: " .. logical)
            native[logical] = nil
        end
        seen[logical] = true
        table.insert(paths, logical)
    end
    assert(#table.keys(native) == 0, "carven: compiler omitted a registered native source")
    table.sort(paths)
    return facts, paths
end
