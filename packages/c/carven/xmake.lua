package("carven")
    set_kind("toolchain")
    set_homepage("https://github.com/ryblust/carven")
    set_description("The Carven language transpiler")

    local sourcedir = os.getenv("CARVEN_SOURCE_DIR")

    if sourcedir and #sourcedir > 0 then
        set_sourcedir(sourcedir) -- for local development
    else
        set_urls("https://github.com/ryblust/carven.git")
    end

    on_install(function (package)
        import("package.tools.xmake").install(package, {kind = "binary"}, {target = "carven"})
    end)

    on_test(function (package)
        os.vrunv("carven", {"--version"})
    end)
