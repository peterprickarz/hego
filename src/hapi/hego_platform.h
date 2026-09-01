#ifndef HEGO_PLATFORM_H
#define HEGO_PLATFORM_H

class HEGoPlatform
{
public:
	static void set_env_vars();
	static void *initialize_hapi();
	static bool free_lib_hapil(void *libHAPIL);
	static void *get_dll_export(void *library_handle, const char *export_name);
	static void *load_lib_hapil();

	// Houdini install to use: the hego/houdini_installation_path project setting,
	// then $HFS, then get_default_houdini_path().
	static const char *get_houdini_path();

	// Stock install location of the Houdini version HEGo is built against, for the
	// platform this build runs on.
	static const char *get_default_houdini_path();
};

#endif // HEGO_PLATFORM_H