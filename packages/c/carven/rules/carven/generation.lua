import("core.base.json")

-- A build observes one source snapshot. Share its hashes across consumers of the
-- same compiler and Crafts without persisting timestamp-only content guesses.
function signatures(files, opt)
    opt = opt or {}
    _g.signatures = _g.signatures or {}
    local values = {}
    for _, file in ipairs(files) do
        local absolute = path.absolute(file)
        table.insert(values, absolute)
        if not os.isfile(absolute) then
            assert(opt.optional, "carven: missing generation input: " .. absolute)
            table.insert(values, "missing")
        else
            local mtime, size = os.mtime(absolute), os.filesize(absolute)
            local cached = _g.signatures[absolute]
            if opt.refresh or not cached or cached.mtime ~= mtime or cached.size ~= size then
                cached = {mtime = mtime, size = size, digest = hash.xxhash128(absolute)}
                _g.signatures[absolute] = cached
            end
            table.insert(values, cached.digest)
        end
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

function manifest(filename, staging_root, implementations)
    local facts = assert(json.loadfile(filename), "carven: compiler did not write its artifact manifest")
    assert(type(facts.artifacts) == "table", "carven: compiler manifest has no artifact inventory")
    local paths, seen = {}, {}
    local native = table.copy(implementations)
    for _, artifact in ipairs(facts.artifacts) do
        local logical = artifact.path
        assert(type(logical) == "string" and #logical > 0 and not path.is_absolute(logical)
            and not logical:find("\\", 1, true) and not logical:find(":", 1, true),
            "carven: invalid manifest artifact path")
        for component in logical:gmatch("[^/]+") do
            assert(component ~= "." and component ~= "..", "carven: nonlocal manifest artifact path")
        end
        assert(path.unix(path.normalize(logical)) == logical and not seen[logical],
            "carven: noncanonical or duplicate manifest artifact")
        assert(os.isfile(path.join(staging_root, logical)), "carven: missing staged artifact: " .. logical)
        if path.extension(logical) == ".cpp" then
            local source = native[logical]
            assert(source ~= nil, "carven: compiler emitted an unregistered native source: " .. logical)
            if source == false then
                assert(artifact.source == nil or artifact.source == json.null,
                    "carven: generated entry unexpectedly belongs to an input")
            else
                assert(type(artifact.source) == "string"
                    and path.absolute(artifact.source, os.projectdir()) == path.absolute(source, os.projectdir()),
                    "carven: implementation belongs to a different source input: " .. logical)
            end
            native[logical] = nil
        end
        seen[logical] = true
        table.insert(paths, logical)
    end
    assert(#table.keys(native) == 0, "carven: compiler omitted a registered native source")
    table.sort(paths)
    return paths
end
