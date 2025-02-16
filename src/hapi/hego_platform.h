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
};

#endif // HEGO_PLATFORM_H