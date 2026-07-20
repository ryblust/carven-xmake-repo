rule("carven.build")
    set_extensions(".cv")

    on_config(function (target)
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
            carven_program = carven_program or path.join(
                carven_package:installdir(),
                "bin",
                is_host("windows") and "carven.exe" or "carven"
            )
            includedir = includedir or path.join(carven_package:installdir(), "include")
        end

        carven_program = path.absolute(carven_program, os.projectdir())
        includedir = path.absolute(includedir, os.projectdir())
        local workdir = path.absolute(target:values("carven.workdir") or os.projectdir(), os.projectdir())
        local outputdir = path.absolute(target:autogendir(), os.projectdir())

        target:data_set("carven.program", carven_program)
        target:data_set("carven.includedir", includedir)
        target:data_set("carven.workdir", workdir)
        target:data_set("carven.outputdir", outputdir)

        target:add("includedirs", includedir)
        target:add("includedirs", target:autogendir())

        for _, sourcefile_cv in ipairs(target:sourcefiles()) do
            if path.extension(sourcefile_cv) == ".cv" then
                local sourcefile_absolute = path.absolute(sourcefile_cv, os.projectdir())
                local source_input = path.unix(path.relative(sourcefile_absolute, workdir))
                assert(
                    source_input ~= ".." and not source_input:startswith("../"),
                    string.format(
                        "carven: source '%s' is outside work directory '%s'",
                        sourcefile_cv,
                        workdir
                    )
                )
                local sourcefile_cpp = path.join(
                    target:autogendir(),
                    (source_input:gsub("%.cv$", ".cpp"))
                )
                target:add("files", sourcefile_cpp, {always_added = true})
            end
        end
    end)

    before_buildcmd_files(function (target, batchcmds, sourcebatch, opt)
        local carven_program = assert(target:data("carven.program"))
        local includedir = assert(target:data("carven.includedir"))
        local workdir = assert(target:data("carven.workdir"))
        local outputdir = assert(target:data("carven.outputdir"))
        local cpp_standard = assert(target:data("carven.cpp_standard"))
        local source_inputs = {}

        for _, sourcefile_cv in ipairs(sourcebatch.sourcefiles) do
            local sourcefile_absolute = path.absolute(sourcefile_cv, os.projectdir())
            table.insert(source_inputs, path.unix(path.relative(sourcefile_absolute, workdir)))
        end
        table.sort(source_inputs)

        if #source_inputs > 0 then
            local argv = {
                "transpile",
                "-std=" .. cpp_standard,
                "-o",
                path(outputdir),
            }
            local sourcefiles = {}
            local generated_cppfiles = {}

            for _, source_input in ipairs(source_inputs) do
                table.insert(argv, path(source_input))
                table.insert(sourcefiles, path.absolute(source_input, workdir))
                table.insert(
                    generated_cppfiles,
                    path.join(outputdir, (source_input:gsub("%.cv$", ".cpp")))
                )
            end

            batchcmds:show_progress(opt.progress, "${color.build.object}transpiling.cv %s", target:name())
            batchcmds:mkdir(outputdir)
            batchcmds:vrunv(carven_program, argv, {curdir = workdir})

            batchcmds:add_depfiles(
                sourcefiles,
                generated_cppfiles,
                carven_program,
                path.join(includedir, "carven", "runtime.hpp")
            )
            batchcmds:add_depvalues(carven_program, workdir, outputdir, cpp_standard, source_inputs)
            batchcmds:set_depcache(target:dependfile(path.join(outputdir, "carven.transpile")))
        end
    end)

rule("carven")
    add_deps("@carven/carven.build")
    add_deps("utils.compiler.runtime")
    add_deps("utils.inherit.links")
    add_deps("utils.merge.object", "utils.merge.archive")
    add_deps("utils.symbols.extract")
