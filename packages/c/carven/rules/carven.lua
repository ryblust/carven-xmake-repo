local function rule_option(target, name)
    local value = target:extraconf("rules", "@carven/carven", name)
    if value == nil then
        value = target:extraconf("rules", "carven", name)
    end
    return value
end

local artifacts_manifest_name = ".carven-artifacts"
local artifacts_manifest_schema = "carven-artifacts-v1"

local cpp_standards = {
    ["20"] = "c++20",
    ["2a"] = "c++20",
    ["23"] = "c++23",
    ["2b"] = "c++23",
    ["26"] = "c++26",
    ["2c"] = "c++26",
    ["latest"] = "c++26",
}

local function normalize_cpp_language(language)
    local suffix =
        language:match("^c%+%+(.*)$")
        or language:match("^cxx(.*)$")
        or language:match("^gnu%+%+(.*)$")
        or language:match("^gnuxx(.*)$")
    if not suffix then
        return nil
    end
    local normalized = cpp_standards[suffix]
    if not normalized then
        return nil, string.format(
            "carven: unsupported C++ target language '%s'; expected C++20, C++23, or C++26",
            language
        )
    end
    return normalized
end

local function split_tabs(line)
    local fields = {}
    local offset = 1
    while true do
        local separator = line:find("\t", offset, true)
        if not separator then
            table.insert(fields, line:sub(offset))
            return fields
        end
        table.insert(fields, line:sub(offset, separator - 1))
        offset = separator + 1
    end
end

local function validate_relative_path(value, description)
    if #value == 0 then
        return "carven: " .. description .. " is empty"
    end
    if value:sub(1, 1) == "/" or value:sub(-1) == "/" or
        value:find("\\", 1, true) or value:match("^[A-Za-z]:")
    then
        return "carven: " .. description .. " is not a normalized relative path"
    end
    if value:find("[%z\1-\31\127]") then
        return "carven: " .. description .. " contains a control character"
    end
    for component in value:gmatch("[^/]+") do
        if component == "." or component == ".." then
            return "carven: " .. description .. " contains '.' or '..'"
        end
    end
    if value:find("//", 1, true) then
        return "carven: " .. description .. " contains an empty component"
    end
    return nil
end

local function parse_artifacts_manifest(artifacts_manifest_file, file_io)
    if not os.exists(artifacts_manifest_file) then
        return nil, "carven: artifacts manifest does not exist: " .. artifacts_manifest_file
    end
    if not os.isfile(artifacts_manifest_file) then
        return nil, "carven: artifacts manifest is not a file: " .. artifacts_manifest_file
    end
    local content, read_error = file_io.readfile(artifacts_manifest_file)
    if not content then
        return nil, "carven: cannot read artifacts manifest: " .. tostring(read_error)
    end
    if content:sub(-1) ~= "\n" then
        return nil, "carven: artifacts manifest must end with a newline"
    end
    local lines = {}
    for line in content:gmatch("([^\n]*)\n") do
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        table.insert(lines, line)
    end
    local header = split_tabs(lines[1] or "")
    if #header ~= 2 or header[1] ~= "carven-artifacts" or header[2] ~= "1" then
        return nil, "carven: invalid or unsupported artifacts manifest header"
    end

    local artifacts = {}
    local paths = {}
    local previous_path = nil
    for index = 2, #lines do
        local fields = split_tabs(lines[index])
        if #fields ~= 2 then
            return nil, "carven: artifacts manifest record must have two fields"
        end
        if fields[1] ~= "artifact" then
            return nil, "carven: unknown artifacts manifest record"
        end
        local logical_path = fields[2]
        local path_error = validate_relative_path(logical_path, "artifact logical path")
        if path_error then
            return nil, path_error
        end
        if paths[logical_path] then
            return nil, "carven: duplicate artifact logical path: " .. logical_path
        end
        if previous_path ~= nil and previous_path >= logical_path then
            return nil, "carven: artifacts manifest records are not sorted"
        end
        paths[logical_path] = true
        previous_path = logical_path
        table.insert(artifacts, logical_path)
    end
    return artifacts
end

local function make_invocation(target, sourcebatch, path_api)
    local sourcefiles = table.copy(sourcebatch.sourcefiles)
    table.sort(sourcefiles)
    if #sourcefiles == 0 then
        return nil
    end

    local outputdir = target:autogendir()
    local program = target:data("carven.program")
    if not program then
        return nil, "carven rule was not configured"
    end
    local emit_tests = target:data("carven.emit_tests")
    local emit_test_main = target:data("carven.emit_test_main")
    local argv = {
        "-o",
        tostring(path_api(outputdir)),
        "--artifacts-manifest",
        artifacts_manifest_name,
    }
    if emit_tests then
        table.insert(argv, "--emit-tests")
        if not emit_test_main then
            table.insert(argv, "--no-test-main")
        end
    end
    for _, sourcefile_cv in ipairs(sourcefiles) do
        table.insert(argv, tostring(path_api.unix(sourcefile_cv)))
    end

    local depvalues = {artifacts_manifest_schema, tostring(program)}
    for _, argument in ipairs(argv) do
        table.insert(depvalues, argument)
    end

    return {
        program = program,
        outputdir = outputdir,
        artifacts_manifest_file = path_api.join(outputdir, artifacts_manifest_name),
        sourcefiles = sourcefiles,
        argv = argv,
        depvalues = depvalues,
        dependfile = target:dependfile(target:autogenfile("carven.compile")),
    }
end

local function invocation_depfiles(invocation, artifacts_manifest_paths, path_api)
    local depfiles = {}
    table.join2(depfiles, invocation.sourcefiles)
    table.insert(depfiles, invocation.artifacts_manifest_file)
    for _, logical_path in ipairs(artifacts_manifest_paths) do
        table.insert(depfiles, path_api.join(invocation.outputdir, logical_path))
    end
    table.insert(depfiles, invocation.program)
    return depfiles
end

rule("carven.build")
    set_extensions(".cv")
    -- Generated C++ must exist before xmake scans ordinary C++ consumers of
    -- named modules. Both actions run in the prepare phase, so order the
    -- source-batch rule itself before the scanner.
    add_orders("@carven/carven.build", "c++.build.modules.scanner")

    on_config(function (target)
        import("lib.detect.find_tool")

        local emit_tests = rule_option(target, "emit_tests")
        local emit_test_main_option = rule_option(target, "emit_test_main")
        emit_tests = emit_tests == true
        if not emit_tests and emit_test_main_option == false then
            raise("carven: emit_test_main = false requires emit_tests = true")
        end
        local emit_test_main = emit_test_main_option ~= false

        local cpp_standard
        for _, language in ipairs(table.wrap(target:get("languages"))) do
            local normalized, language_error = normalize_cpp_language(language)
            if language_error then
                raise(language_error)
            end
            if normalized then
                if cpp_standard and cpp_standard ~= normalized then
                    raise(string.format(
                        "carven: conflicting C++ target languages normalize to '%s' and '%s'",
                        cpp_standard,
                        normalized
                    ))
                end
                cpp_standard = normalized
            end
        end
        if not cpp_standard then
            target:add("languages", "c++20")
        end

        local carven_program = target:values("carven.program")
        local includedir = target:values("carven.includedir")
        if not carven_program or not includedir then
            local carven_package = target:pkg("carven")
            if not carven_package then
                raise("please add_packages(\"carven\") or set local Carven program and include values")
            end
            if not carven_program then
                local envs = os.joinenvs(target:pkgenvs(), os.getenvs())
                local carven_tool = find_tool("carven", {envs = envs, force = true, norun = true})
                if not carven_tool then
                    raise("carven: executable not found in package or system PATH")
                end
                carven_program = carven_tool.program
            end
            includedir = includedir or path.join(carven_package:installdir(), "include")
        end

        carven_program = path.absolute(carven_program, os.projectdir())
        includedir = path.absolute(includedir, os.projectdir())

        target:data_set("carven.program", carven_program)
        target:data_set("carven.includedir", includedir)
        target:data_set("carven.emit_tests", emit_tests)
        target:data_set("carven.emit_test_main", emit_test_main)

        target:add("includedirs", includedir)
        target:add("includedirs", target:autogendir())

        for _, sourcefile_cv in ipairs(target:sourcefiles()) do
            if path.extension(sourcefile_cv) == ".cv" then
                local sourcefile_cpp = target:autogenfile((sourcefile_cv:gsub("%.cv$", ".cpp")))
                target:add("files", sourcefile_cpp, {always_added = true})
            end
        end
        if emit_tests and emit_test_main then
            target:add("files", path.join(target:autogendir(), "carven-test-main.cpp"), {
                always_added = true,
            })
        end
    end)

    on_prepare_files(function (target, jobgraph, sourcebatch, opt)
        import("core.base.option")
        import("core.project.depend")
        import("utils.progress")

        local invocation, invocation_error = make_invocation(target, sourcebatch, path)
        if invocation_error then
            raise(invocation_error)
        end
        if not invocation then
            return
        end
        if not target:data("carven.includedir") then
            raise("carven rule was not configured")
        end

        jobgraph:add(target:fullname() .. "/carven.generate", function (index, total, jobopt)
            local cached = depend.load(invocation.dependfile) or {}
            local changed = target:is_rebuilt() or depend.is_changed(cached, {
                values = invocation.depvalues,
                lastmtime = os.mtime(invocation.dependfile),
            })
            if not changed then
                return
            end

            progress.show(
                jobopt.progress or 0,
                "${color.build.object}compiling.cv %s",
                target:name()
            )
            if option.get("dry-run") then
                print(os.args(table.join(invocation.program, invocation.argv)))
                return
            end
            os.mkdir(invocation.outputdir)
            os.vrunv(invocation.program, invocation.argv, {curdir = os.projectdir()})

            local current_artifact_paths, current_artifacts_manifest_error =
                parse_artifacts_manifest(invocation.artifacts_manifest_file, io)
            if not current_artifact_paths then
                raise(current_artifacts_manifest_error)
            end
            depend.save({
                files = invocation_depfiles(invocation, current_artifact_paths, path),
                values = invocation.depvalues,
            }, invocation.dependfile)
        end)
    end, {jobgraph = true})

rule("carven")
    add_deps("@carven/carven.build")
    add_deps("utils.compiler.runtime")
    add_deps("utils.inherit.links")
    add_deps("utils.merge.object", "utils.merge.archive")
    add_deps("utils.symbols.extract")
