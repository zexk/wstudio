-- Real-plugin validation config for packages supplied by the Nix devShell.
dofile("examples/init.lua")
wstudio.o.clap_plugin_path = assert(os.getenv("WSTUDIO_TEST_CLAP_PATH"))
wstudio.o.vst3_plugin_path = assert(os.getenv("WSTUDIO_TEST_VST3_PATH"))
