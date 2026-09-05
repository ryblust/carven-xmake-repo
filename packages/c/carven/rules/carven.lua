local function rule_option(target, name)
    return target:extraconf("rules", "@carven/carven", name)
end

local rule_file = path.join(os.scriptdir(), "carven.lua")

local function has_cpp_language(target)
    for _, language in ipairs(table.wrap(target:get("languages"))) do
        if language:match("^c%+%+") or language:match("^cxx") or
            language:match("^gnu%+%+") or language:match("^gnuxx")
        then
            return true
        end
    end
    return false
end

local function project_source_argument(sourcefile, path_api)
    local projectdir = os.projectdir()
    local source_argument = path_api.unix(path_api.relative(
        path_api.absolute(sourcefile, projectdir),
        projectdir
    ))
    if path_api.is_absolute(source_argument) or
        source_argument == ".." or source_argument:sub(1, 3) == "../"
    then
        return nil, "carven: source path is outside the Xmake project: " .. tostring(sourcefile)
    end
    return source_argument
end

local function scan_artifacts(root, path_api, os_api)
    local logical_paths = {}
    if not os_api.isdir(root) then
        return logical_paths
    end
    for _, artifact_file in ipairs(os_api.files(path_api.join(root, "**"))) do
        if os_api.isfile(artifact_file) then
            local logical_path = path_api.unix(path_api.relative(artifact_file, root))
            table.insert(logical_paths, logical_path)
        end
    end
    table.sort(logical_paths)
    return logical_paths
end

local function equal_paths(left, right)
    if #left ~= #right then
        return false
    end
    for index, left_path in ipairs(left) do
        if left_path ~= right[index] then
            return false
        end
    end
    return true
end

local function sync_artifacts(staging_root, live_root, path_api, os_api)
    local desired_paths = scan_artifacts(staging_root, path_api, os_api)
    local current_paths = scan_artifacts(live_root, path_api, os_api)
    if not equal_paths(desired_paths, current_paths) then
        os_api.tryrm(live_root)
    end
    os_api.mkdir(live_root)

    for _, logical_path in ipairs(desired_paths) do
        local source_file = path_api.join(staging_root, logical_path)
        local destination_file = path_api.join(live_root, logical_path)
        os_api.mkdir(path_api.directory(destination_file))
        os_api.cp(source_file, destination_file, {copy_if_different = true})
    end
    return desired_paths
end

local function make_invocation(target, sourcebatch, path_api)
    local sourcefiles = table.copy(sourcebatch.sourcefiles)
    if #sourcefiles == 0 then
        return nil
    end
    table.sort(sourcefiles)

    local source_arguments = {}
    for _, sourcefile_cv in ipairs(sourcefiles) do
        local source_argument, source_error = project_source_argument(sourcefile_cv, path_api)
        if source_error then
            return nil, source_error
        end
        table.insert(source_arguments, source_argument)
    end
    table.sort(source_arguments)

    local live_root = path_api.join(target:autogendir(), "rules", "carven")
    local staging_root = path_api.join(target:autogendir(), "rules", "carven.staging")
    local program = target:data("carven.program")
    if not program then
        return nil, "carven rule was not configured"
    end
    local tests = target:data("carven.tests")
    local linkage_domain = target:data("carven.linkage_domain")
    local argv = {
        "--output-dir",
        tostring(path_api(staging_root)),
        "--linkage-domain=" .. linkage_domain,
    }
    if tests == "default" then
        table.insert(argv, "--tests=default")
    elseif tests == "external" then
        table.insert(argv, "--tests=external")
    end
    for _, source_argument in ipairs(source_arguments) do
        table.insert(argv, source_argument)
    end

    local depvalues = {tostring(program)}
    for _, argument in ipairs(argv) do
        table.insert(depvalues, argument)
    end

    return {
        program = program,
        live_root = live_root,
        staging_root = staging_root,
        sourcefiles = sourcefiles,
        argv = argv,
        depvalues = depvalues,
        dependfile = target:dependfile(target:autogenfile("carven.compile")),
    }
end

local function invocation_depfiles(invocation, artifact_paths, path_api)
    local depfiles = {}
    table.join2(depfiles, invocation.sourcefiles)
    for _, logical_path in ipairs(artifact_paths) do
        table.insert(depfiles, path_api.join(invocation.live_root, logical_path))
    end
    table.insert(depfiles, invocation.program)
    table.insert(depfiles, rule_file)
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
        local linkage_domain = rule_option(target, "linkage_domain")
        if linkage_domain ~= nil and type(linkage_domain) ~= "string" then
            raise("carven: linkage_domain must be a string")
        end
        linkage_domain = linkage_domain
                    or (path.absolute(os.projectdir()) .. ":" .. target:fullname())

        if not has_cpp_language(target) then
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
        target:data_set("carven.linkage_domain", linkage_domain)

        local live_root = path.join(target:autogendir(), "rules", "carven")
        target:add("includedirs", includedir)
        target:add("includedirs", live_root)

        for _, sourcefile_cv in ipairs(target:sourcefiles()) do
            if path.extension(sourcefile_cv) == ".cv" then
                local source_argument, source_error = project_source_argument(sourcefile_cv, path)
                if source_error then
                    raise(source_error)
                end
                local generated_argument = (source_argument:gsub("%.cv$", ".cpp"))
                local sourcefile_cpp = path.join(live_root, generated_argument)
                target:add("files", sourcefile_cpp, {always_added = true})
            end
        end
        if tests == "default" then
            target:add("files", path.join(
                live_root,
                "carven",
                "generated",
                "carven-test-main.cpp"
            ), {
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

            os.tryrm(invocation.dependfile)
            try
            {
                function ()
                    os.tryrm(invocation.staging_root)
                    os.mkdir(invocation.staging_root)
                    os.vrunv(invocation.program, invocation.argv, {curdir = os.projectdir()})
                    local desired_paths = sync_artifacts(
                        invocation.staging_root,
                        invocation.live_root,
                        path,
                        os
                    )
                    depend.save({
                        files = invocation_depfiles(invocation, desired_paths, path),
                        values = invocation.depvalues,
                    }, invocation.dependfile)
                end,
                finally
                {
                    function (ok, errors)
                        os.tryrm(invocation.staging_root)
                        if not ok then
                            raise(errors)
                        end
                    end
                }
            }
        end)
    end, {jobgraph = true})

rule("carven")
    add_deps("@carven/carven.build")
    add_deps("utils.compiler.runtime")
    add_deps("utils.inherit.links")
    add_deps("utils.merge.object", "utils.merge.archive")
    add_deps("utils.symbols.extract")
