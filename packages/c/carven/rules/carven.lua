local function rule_option(target, name)
    return target:extraconf("rules", "@carven/carven", name)
end

local artifact_receipt_name = ".carven-artifacts"
local artifact_receipt_header = "carven-artifacts\t1"
local rule_file = path.join(os.scriptdir(), "carven.lua")

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

local function parse_artifact_receipt(receipt_file, file_io)
    if not os.exists(receipt_file) then
        return nil, "carven: artifact receipt does not exist: " .. receipt_file
    end
    if not os.isfile(receipt_file) then
        return nil, "carven: artifact receipt is not a file: " .. receipt_file
    end
    local content, read_error = file_io.readfile(receipt_file)
    if not content then
        return nil, "carven: cannot read artifact receipt: " .. tostring(read_error)
    end
    if content:sub(-1) ~= "\n" then
        return nil, "carven: artifact receipt must end with a newline"
    end
    local lines = {}
    for line in content:gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    if lines[1] ~= artifact_receipt_header then
        return nil, "carven: invalid artifact receipt header"
    end

    local artifacts = {}
    local previous_path = nil
    local accepted_paths = {}
    for index = 2, #lines do
        local logical_path = lines[index]
        if logical_path:find("\t", 1, true) then
            return nil, "carven: artifact receipt path contains a tab"
        end
        local path_error = validate_relative_path(logical_path, "artifact logical path")
        if path_error then
            return nil, path_error
        end
        if logical_path == artifact_receipt_name or
            logical_path:sub(1, #artifact_receipt_name + 1) == artifact_receipt_name .. "/"
        then
            return nil, "carven: artifact receipt cannot own itself"
        end
        if previous_path ~= nil and previous_path >= logical_path then
            return nil, "carven: artifact receipt paths are not sorted and unique"
        end
        local separator = logical_path:find("/", 1, true)
        while separator do
            if accepted_paths[logical_path:sub(1, separator - 1)] then
                return nil, "carven: artifact receipt contains a path below an owned file"
            end
            separator = logical_path:find("/", separator + 1, true)
        end
        accepted_paths[logical_path] = true
        previous_path = logical_path
        table.insert(artifacts, logical_path)
    end
    return artifacts
end

local function make_invocation(target, sourcebatch, path_api)
    local sourcefiles = table.copy(sourcebatch.sourcefiles)
    if #sourcefiles == 0 then
        return nil
    end
    table.sort(sourcefiles)

    local source_arguments = {}
    local projectdir = os.projectdir()
    for _, sourcefile_cv in ipairs(sourcefiles) do
        local source_argument = path_api.unix(path_api.relative(
            path_api.absolute(sourcefile_cv, projectdir),
            projectdir
        ))
        local source_error = validate_relative_path(source_argument, "Carven source path")
        if source_error then
            return nil, source_error .. ": " .. tostring(sourcefile_cv)
        end
        table.insert(source_arguments, source_argument)
    end
    table.sort(source_arguments)

    local outputdir = target:autogendir()
    local program = target:data("carven.program")
    if not program then
        return nil, "carven rule was not configured"
    end
    local tests = target:data("carven.tests")
    local argv = {
        "--reconcile-output",
        tostring(path_api(outputdir)),
    }
    if tests == "default" then
        table.insert(argv, "--tests=default")
    elseif tests == "external" then
        table.insert(argv, "--tests=external")
    end
    for _, source_argument in ipairs(source_arguments) do
        table.insert(argv, source_argument)
    end

    local depvalues = {artifact_receipt_header, tostring(program)}
    for _, argument in ipairs(argv) do
        table.insert(depvalues, argument)
    end

    return {
        program = program,
        outputdir = outputdir,
        receipt_file = path_api.join(outputdir, artifact_receipt_name),
        sourcefiles = sourcefiles,
        rule_file = rule_file,
        argv = argv,
        depvalues = depvalues,
        dependfile = target:dependfile(target:autogenfile("carven.compile")),
    }
end

local function invocation_depfiles(invocation, artifact_paths, path_api)
    local depfiles = {}
    table.join2(depfiles, invocation.sourcefiles)
    table.insert(depfiles, invocation.receipt_file)
    for _, logical_path in ipairs(artifact_paths) do
        table.insert(depfiles, path_api.join(invocation.outputdir, logical_path))
    end
    table.insert(depfiles, invocation.program)
    table.insert(depfiles, invocation.rule_file)
    return depfiles
end

rule("carven.build")
    set_extensions(".cv")

    on_config(function (target)
        import("lib.detect.find_tool")

        local tests = rule_option(target, "tests")
        if tests ~= nil and tests ~= "default" and tests ~= "external" then
            raise("carven: tests must be 'default' or 'external'")
        end

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
        target:data_set("carven.tests", tests)

        target:add("includedirs", includedir)
        target:add("includedirs", target:autogendir())

        for _, sourcefile_cv in ipairs(target:sourcefiles()) do
            if path.extension(sourcefile_cv) == ".cv" then
                local sourcefile_cpp = target:autogenfile((sourcefile_cv:gsub("%.cv$", ".cpp")))
                target:add("files", sourcefile_cpp, {always_added = true})
            end
        end
        if tests == "default" then
            target:add("files", path.join(target:autogendir(), "carven-test-main.cpp"), {
                always_added = true,
            })
        end
    end)

    before_prepare_files(function (target, jobgraph, sourcebatch, opt)
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
            if not os.isfile(invocation.program) then
                raise(string.format(
                    "carven: compiler executable does not exist: %s; build or install Carven before building this target",
                    invocation.program
                ))
            end
            os.mkdir(invocation.outputdir)
            os.vrunv(invocation.program, invocation.argv, {curdir = os.projectdir()})

            local current_artifact_paths, receipt_error =
                parse_artifact_receipt(invocation.receipt_file, io)
            if not current_artifact_paths then
                raise(receipt_error)
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
