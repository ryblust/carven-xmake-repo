rule("carven.build")
    set_extensions(".cv")

    on_config(function (target)
        local sourcekinds = target:sourcekinds()
        if #sourcekinds == 0 then
            table.insert(sourcekinds, "cxx")
        end

        local carven_package = target:pkg("carven")
        target:add("includedirs", path.join(carven_package:installdir(), "include"))
    end)

    on_buildcmd_file(function (target, batchcmds, sourcefile_cv, opt)
        local carven_package = target:pkg("carven")
        local carven_program = path.join(carven_package:installdir(), "bin", is_host("windows") and "carven.exe" or "carven")
        local sourcefile_cpp = target:autogenfile((sourcefile_cv:gsub("%.cv$", ".cpp")))
        local objectfile = target:objectfile(sourcefile_cpp)

        table.insert(target:objectfiles(), objectfile)

        batchcmds:show_progress(opt.progress, "${color.build.object}transpiling.cv %s", sourcefile_cv)
        batchcmds:mkdir(path.directory(sourcefile_cpp))
        batchcmds:vrunv(carven_program, {"transpile", "-o", path(target:autogendir()), path(sourcefile_cv)})
        batchcmds:compile(sourcefile_cpp, objectfile)

        batchcmds:add_depfiles(sourcefile_cv)
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
