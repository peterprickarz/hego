#include "hapi/hego_platform.h"
#include "hapi/houdini_api.h"
#include "util/log/log.h"
#include <cstdlib>
#include <godot_cpp/classes/project_settings.hpp>
#include <string>

#ifdef _WIN32
#include <tchar.h>
#include <windows.h>

#else
#include <dlfcn.h>
#endif

const char *HAPI_LIB_OBJECT_WINDOWS = "libHAPIL.dll";
const char *HAPI_LIB_OBJECT_LINUX = "libHAPIL.so";
const char *HAPI_LIB_OBJECT_MAC = "libHAPIL.dylib";

const char *HEGoPlatform::get_default_houdini_path()
{
	// Keep in sync with SConstruct's default_hfs and with hego.gd, which seeds the
	// project setting with the same per-platform defaults.
#if defined(_WIN32)
	return "C:/Program Files/Side Effects Software/Houdini 22.0.368";
#elif defined(__APPLE__)
	return "/Applications/Houdini/Houdini22.0.368/Frameworks/Houdini.framework/Versions/Current/Resources";
#else
	return "/opt/hfs22.0.368";
#endif
}

const char *HEGoPlatform::get_houdini_path()
{
	static std::string cached_path;

	// First try to get from Godot project settings
	godot::ProjectSettings *project_settings = godot::ProjectSettings::get_singleton();
	if (project_settings && project_settings->has_setting("hego/houdini_installation_path"))
	{
		godot::String setting_path = project_settings->get_setting("hego/houdini_installation_path");
		if (!setting_path.is_empty())
		{
			cached_path = setting_path.utf8().get_data();
			return cached_path.c_str();
		}
	}

	// Fall back to environment variable
	const char *env_path = std::getenv("HFS");
	if (env_path)
	{
		cached_path = env_path;
		return cached_path.c_str();
	}

	// Final fallback: wherever this platform's installer puts Houdini by default.
	// A Windows path would be useless on Linux and macOS.
	cached_path = get_default_houdini_path();
	return cached_path.c_str();
}

void HEGoPlatform::set_env_vars()
{
	HEGo::Util::Log::debug(HEGo::Util::Log::Category::PLATFORM, "Setting in process environment variables...");

	// Get Houdini path from project setting first, then environment variable, then fallback
	const char *houdiniBasePath = get_houdini_path();

	std::string houdiniBinPath = std::string(houdiniBasePath) + "/bin";

#ifdef _WIN32
	_putenv(("HFS=" + std::string(houdiniBasePath)).c_str());
	_putenv((std::string("PATH=") + getenv("PATH") + ";" + houdiniBinPath).c_str());
#else
	setenv("HFS", houdiniBasePath, 1);
	std::string path = std::string(getenv("PATH")) + ":" + houdiniBinPath;
	setenv("PATH", path.c_str(), 1);
#endif

	HEGo::Util::Log::info(HEGo::Util::Log::Category::PLATFORM, godot::String("Using Houdini installation: ") + godot::String(houdiniBasePath));
}

void *HEGoPlatform::load_lib_hapil()
{
#if defined(_WIN32)
	const char *houdiniBasePath = get_houdini_path();
	std::string full_path = std::string(houdiniBasePath) + "\\bin\\libHAPIL.dll";

	HMODULE libHAPIL = LoadLibraryA(full_path.c_str());

	if (!libHAPIL)
	{
		DWORD err = GetLastError();

		// Log full path and exact Windows error code
		godot::String msg = godot::String("Failed to load libHAPIL.dll from:\n") + godot::String(full_path.c_str()) +
				"\nError code: " + godot::String(std::to_string(err).c_str());

		HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, msg);

		// Optional: fallback to old SetDllDirectory method
		std::string bin_dir = std::string(houdiniBasePath) + "\\bin";
		SetDllDirectoryA(bin_dir.c_str());
		libHAPIL = LoadLibraryA(HAPI_LIB_OBJECT_WINDOWS);

		if (!libHAPIL)
		{
			HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, "Fallback load also failed: " + godot::String(std::to_string(GetLastError()).c_str()));
		}
	}

	// Return as void* to match original API
	return static_cast<void *>(libHAPIL);

#else
	// On Linux and macOS the loader finds libHAPIL through the search path that
	// set_env_vars() prepared, so there is no full path to load from here.
#if defined(__linux__)
	const char *library_name = HAPI_LIB_OBJECT_LINUX;
#else
	const char *library_name = HAPI_LIB_OBJECT_MAC;
#endif

	void *libHAPIL = dlopen(library_name, RTLD_LAZY);
	if (!libHAPIL)
	{
		// dlerror() is the only place that says why, so surface it instead of
		// leaving the caller with a bare null.
		const char *dl_error = dlerror();
		HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, godot::String("Failed to load ") + library_name + " from " + get_houdini_path() + ": " + (dl_error ? dl_error : "unknown error"));
	}
	return libHAPIL;
#endif
}

bool HEGoPlatform::free_lib_hapil(void *libHAPIL)
{
#if defined(_WIN32)
	if (!libHAPIL)
		return false;
	BOOL result = FreeLibrary(static_cast<HMODULE>(libHAPIL));
	SetDllDirectoryA(nullptr); // Reset (optional, but harmless)
	return result != FALSE;
#else
	// On Linux / POSIX
	if (!libHAPIL)
	{
		return false;
	}

	int result = dlclose(libHAPIL);

	if (result != 0)
	{
		const char *dl_error = dlerror();
		HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, godot::String("Failed to unload libHAPIL: ") + (dl_error ? dl_error : "unknown error"));
		return false;
	}

	return true;
#endif
}

void *HEGoPlatform::get_dll_export(void *library_handle, const char *export_name)
{
#if defined(_WIN32)
	FARPROC proc = GetProcAddress(static_cast<HMODULE>(library_handle), export_name);
	return reinterpret_cast<void *>(proc);
#else
	return dlsym(library_handle, export_name);
#endif
}

void *HEGoPlatform::initialize_hapi()
{
	void *libHAPIL = load_lib_hapil();
	if (libHAPIL != nullptr)
	{
		HoudiniApi::initialize_hapi(libHAPIL);
	}

	if (!HoudiniApi::is_hapi_initialized())
	{
		HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, "Failed to load and initialize the Houdini Engine API from libHAPIL");
		return nullptr;
	}

	HEGo::Util::Log::info(HEGo::Util::Log::Category::PLATFORM, "Loaded and initialized libHAPIL.");

	return libHAPIL;
}
