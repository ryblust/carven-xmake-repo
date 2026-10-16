local function rule_option(target, name)
    return target:extraconf("rules", "@carven/carven", name)
end

local rule_file = path.join(os.scriptdir(), "xmake.lua")

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

rule("carven.build")
    set_extensions(".cv")

    before_config(function (target)
        import("generation", {rootdir = path.directory(rule_file)}).reset(target)
    end)

    on_config(function (target, opt)
        import("core.project.project")
        local generation = import("generation", {rootdir = path.directory(rule_file)})

        local timings = rule_option(target, "timings")
        if timings ~= nil and type(timings) ~= "boolean" then
            raise("carven: timings must be a boolean")
        end
        local tests = rule_option(target, "tests")
        if type(tests) == "table" then
            if tests.entry ~= nil and type(tests.entry) ~= "boolean" then
                raise("carven: tests.entry must be a boolean")
            end
            tests = tests.entry ~= false and true or "runner"
        elseif tests ~= nil and type(tests) ~= "boolean" then
            raise("carven: tests must be a boolean or a table with an entry option")
        end
        target:data_set("carven.tests", tests)
        if not has_cpp_language(target) then
            target:add("languages", "c++20")
        end

        local carven_package = assert(project.required_package("carven"), "carven package is required")
        local carven_program, craftsdir
        if carven_package:requireconf("configs", "rules_only") then
            local compiler = assert(project.target("carven"), "rules_only requires a local compiler target")
            carven_program = compiler:targetfile()
            craftsdir = path.join(os.projectdir(), "crafts")
        else
            local filename = is_host("windows") and "carven.exe" or "carven"
            carven_program = path.join(carven_package:installdir(), "bin", filename)
            craftsdir = path.join(carven_package:installdir(), "crafts")
        end
        carven_program = path.absolute(carven_program, os.projectdir())

        target:data_set("carven.program", carven_program)
        local installed_sources = path.join(craftsdir, "carven")
        target:data_set("carven.installed_sources", installed_sources)
        local project_crafts = path.join(os.projectdir(), "crafts")
        local standard_sources = generation.inventory(installed_sources).cv
        assert(#standard_sources > 0,
            "carven: installed standard library has no Carven sources: " .. installed_sources)
        target:data_set("carven.standard_sources", standard_sources)
        target:data_set("carven.timings", timings)

        local live_root = path.absolute(path.join(target:autogendir(), "rules", "carven"), os.projectdir())

        for _, root in ipairs(table.unique({craftsdir, project_crafts})) do
            if os.isdir(root) then
                target:add("includedirs", root, {public = true})
            end
        end
        local craft_files = {}
        for _, extension in ipairs({"cv", "cpp"}) do
            for _, source in ipairs(generation.inventory(project_crafts)[extension]) do
                local installed = path.unix(path.absolute(source, os.projectdir()))
                    :startswith(path.unix(installed_sources) .. "/")
                if not installed then
                    table.insert(craft_files, source)
                end
            end
        end
        if #craft_files > 0 then
            target:add("files", craft_files)
        end

        local generated_files, sources, arguments = {}, {}, {}
        for _, sourcefile_cv in ipairs(target:sourcefiles()) do
            if path.extension(sourcefile_cv) == ".cv" then
                local source_config = target:fileconfig(sourcefile_cv) or {}
                local input = generation.source_input(sourcefile_cv, installed_sources, os.projectdir())
                table.insert(arguments, "--source=" .. input.module .. "=" .. input.path)
                -- Register generated implementations before native scanning.
                local sourcefile_cpp = path.relative(path.join(live_root, input.implementation), os.projectdir())
                if path.unix(path.absolute(sourcefile_cv, os.projectdir()))
                    :startswith(path.unix(installed_sources) .. "/") then
                    raise("carven: installed standard source is already owned by the shared library build: "
                        .. sourcefile_cv)
                end
                table.insert(sources, sourcefile_cv)
                local native_config = table.clone(source_config)
                -- Source-selection rules belong to .cv; native per-file
                -- settings belong to the implementation it generates.
                native_config.rule = nil
                native_config.rules = nil
                native_config.sourcekind = nil
                native_config.always_added = true
                target:add("files", sourcefile_cpp, native_config)
                table.insert(generated_files, sourcefile_cpp)
            end
        end
        if #sources > 0 then
            target:add("includedirs", live_root, {public = true})
        end
        if tests == true and #sources > 0 then
            local entry = path.relative(
                path.join(live_root, "carven", "generated", "carven-test-main.cpp"),
                os.projectdir()
            )
            target:add("files", entry, {always_added = true})
            table.insert(generated_files, entry)
        end
        table.sort(sources)
        table.sort(arguments)
        target:data_set("carven.sources", sources)
        target:data_set("carven.source_arguments", arguments)
        target:data_set("carven.compile_dependfile",
            path.absolute(target:dependfile(target:autogenfile("carven.compile")), os.projectdir()))
        target:data_set("carven.generated_files", generated_files)
        target:data_set("carven.generated_root", live_root)
    end)

    before_prepare_files(function (target, jobgraph)
        import("batches", {rootdir = path.directory(rule_file)}).generate(target, jobgraph)
    end, {jobgraph = true})

rule("carven")
    after_config(function (target, opt)
        if #(target:data("carven.sources") or {}) > 0 then
            local batches = import("batches", {rootdir = path.directory(rule_file)})
            local standard = batches.standard(target, opt)
            batches.attach(target, standard, opt)
            import("stdlib", {rootdir = path.directory(rule_file)}).attach(target, standard, opt)
        end
        import("generation", {rootdir = path.directory(rule_file)}).refresh_dependencies(target)
        import("testing", {rootdir = path.directory(rule_file)}).discover(target, opt)
    end)
    add_deps("@carven/carven.build")
    add_deps("c++")
