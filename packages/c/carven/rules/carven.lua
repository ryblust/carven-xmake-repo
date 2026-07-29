local function rule_option(target, name)
    local value = target:extraconf("rules", "@carven/carven", name)
    if value == nil then
        value = target:extraconf("rules", "carven", name)
    end
    return value
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
        assert(
            emit_tests or emit_test_main_option ~= false,
            "carven: emit_test_main = false requires emit_tests = true"
        )
        local emit_test_main = emit_test_main_option ~= false

        local standards = {
            ["20"] = "c++20",
            ["2a"] = "c++20",
            ["23"] = "c++23",
            ["2b"] = "c++23",
            ["26"] = "c++26",
            ["2c"] = "c++26",
            ["latest"] = "c++26",
        }

        local cpp_standard
        for _, language in ipairs(table.wrap(target:get("languages"))) do
            local suffix =
                language:match("^c%+%+(.*)$")
                or language:match("^cxx(.*)$")
                or language:match("^gnu%+%+(.*)$")
                or language:match("^gnuxx(.*)$")

            if suffix then
                local normalized = standards[suffix]
                assert(
                    normalized,
                    string.format(
                        "carven: unsupported C++ target language '%s'; expected C++20, C++23, or C++26",
                        language
                    )
                )
                assert(
                    not cpp_standard or cpp_standard == normalized,
                    string.format(
                        "carven: conflicting C++ target languages normalize to '%s' and '%s'",
                        cpp_standard,
                        normalized
                    )
                )
                cpp_standard = normalized
            end
        end

        if not cpp_standard then
            target:add("languages", "c++20")
            cpp_standard = "c++20"
        end
        target:data_set("carven.cpp_standard", cpp_standard)

        local carven_program = target:values("carven.program")
        local includedir = target:values("carven.includedir")
        if not carven_program or not includedir then
            local carven_package = assert(
                target:pkg("carven"),
                "please add_packages(\"carven\") or set local Carven program and include values"
            )
            if not carven_program then
                local envs = os.joinenvs(target:pkgenvs(), os.getenvs())
                local carven_tool = assert(
                    find_tool("carven", {envs = envs, force = true, norun = true}),
                    "carven: executable not found in package or system PATH"
                )
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

    on_preparecmd_files(function (target, batchcmds, sourcebatch, opt)
        local carven_program = target:data("carven.program")
        local includedir = target:data("carven.includedir")
        local cpp_standard = target:data("carven.cpp_standard")
        local emit_tests = target:data("carven.emit_tests")
        local emit_test_main = target:data("carven.emit_test_main")
        assert(carven_program and includedir and cpp_standard, "carven rule was not configured")
        local outputdir = target:autogendir()
        local sourcefiles = table.copy(sourcebatch.sourcefiles)
        table.sort(sourcefiles)

        if #sourcefiles > 0 then
            local argv = {
                "-std=" .. cpp_standard,
                "-o",
                path(outputdir),
            }
            local generated_cppfiles = {}

            if emit_tests then
                table.insert(argv, "--emit-tests")
                if not emit_test_main then
                    table.insert(argv, "--no-test-main")
                end
            end

            for _, sourcefile_cv in ipairs(sourcefiles) do
                table.insert(argv, path.unix(sourcefile_cv))
                table.insert(
                    generated_cppfiles,
                    target:autogenfile((sourcefile_cv:gsub("%.cv$", ".cpp")))
                )
            end

            if emit_tests and emit_test_main then
                table.insert(generated_cppfiles, path.join(outputdir, "carven-test-main.cpp"))
            end

            batchcmds:show_progress(opt.progress, "${color.build.object}compiling.cv %s", target:name())
            batchcmds:mkdir(outputdir)
            batchcmds:vrunv(carven_program, argv, {curdir = os.projectdir()})

            local depfiles = {}
            table.join2(depfiles, sourcefiles)
            table.join2(depfiles, generated_cppfiles)
            table.insert(depfiles, carven_program)
            batchcmds:add_depfiles(table.unpack(depfiles))
            batchcmds:add_depvalues(cpp_standard, emit_tests, emit_test_main)
            batchcmds:set_depcache(target:dependfile(target:autogenfile("carven.compile")))
        end
    end)

rule("carven")
    add_deps("@carven/carven.build")
    add_deps("utils.compiler.runtime")
    add_deps("utils.inherit.links")
    add_deps("utils.merge.object", "utils.merge.archive")
    add_deps("utils.symbols.extract")
