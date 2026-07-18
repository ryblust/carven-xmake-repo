rule("carven.build")
    set_extensions(".cv")

    on_config(function (target)
        local sourcekinds = target:sourcekinds()
        if #sourcekinds == 0 then
            table.insert(sourcekinds, "cxx")
        end

        local includedir = target:values("carven.includedir")
        if not includedir then
            local carven_package = assert(
                target:pkg("carven"),
                "please add_packages(\"carven\") or set_values(\"carven.includedir\", <path>)"
            )
            includedir = path.join(carven_package:installdir(), "include")
        end
        target:add("includedirs", includedir)
        target:add("includedirs", target:autogendir())
    end)

    on_buildcmd_file(function (target, batchcmds, sourcefile_cv, opt)
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
        local workdir = path.absolute(target:values("carven.workdir") or os.projectdir(), os.projectdir())
        local source_input = path.relative(sourcefile_cv, workdir)
        local sourcefile_cpp = path.join(target:autogendir(), (source_input:gsub("%.cv$", ".cpp")))
        local objectfile = target:objectfile(sourcefile_cpp)

        table.insert(target:objectfiles(), objectfile)

        batchcmds:show_progress(opt.progress, "${color.build.object}transpiling.cv %s", sourcefile_cv)
        batchcmds:mkdir(path.directory(sourcefile_cpp))
        batchcmds:vrunv(
            carven_program,
            {
                "transpile",
                "-o",
                path(path.absolute(target:autogendir(), os.projectdir())),
                path(source_input),
            },
            {curdir = workdir}
        )
        batchcmds:compile(sourcefile_cpp, objectfile)

        batchcmds:add_depfiles(
            sourcefile_cv,
            carven_program,
            path.join(includedir, "carven", "runtime.hpp")
        )
        batchcmds:add_depvalues(carven_program)
        batchcmds:set_depmtime(os.mtime(objectfile))
        batchcmds:set_depcache(target:dependfile(objectfile))
    end)

rule("carven")
    add_deps("@carven/carven.build")
    add_deps("utils.compiler.runtime")
    add_deps("utils.inherit.links")
    add_deps("utils.merge.object", "utils.merge.archive")
    add_deps("utils.symbols.extract")
