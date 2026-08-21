package("carven")
    set_kind("toolchain")
    set_homepage("https://github.com/ryblust/carven")
    set_description("The Carven source-to-C++ compiler")

    add_configs("rules_only", {
        description = "Install only the Carven xmake rules",
        default = false,
        type = "boolean",
    })

    on_source(function (package)
        if not package:config("rules_only") then
            local carven_source_dir = os.getenv("CARVEN_SOURCE_DIR")
            if carven_source_dir and #carven_source_dir > 0 then
                carven_source_dir = path.absolute(carven_source_dir, os.projectdir())
                package:set("sourcedir", carven_source_dir)
            else
                package:add("urls", "https://github.com/ryblust/carven.git")
            end
        end
    end)

    on_install(function (package)
        if not package:config("rules_only") then
            import("package.tools.xmake").install(
                package,
                {kind = "binary", build_tests = "n"},
                {target = "carven"}
            )
        end
    end)

    on_test(function (package)
        if not package:config("rules_only") then
            os.vrunv("carven", {"--version"})
        end
    end)
