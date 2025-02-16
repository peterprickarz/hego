#include "hapi/hego_platform.h"
#include "hapi/houdini_api.h"
#include "util/log/log.h"
#include <cstdlib>
#include <iostream>
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

void HEGoPlatform::set_env_vars()
{
	HEGo::Util::Log::message("Setting in process environment variables...");
	const char *houdiniBasePath = "C:/Program Files/Side Effects Software/Houdini 20.5.305";
	const char *houdiniBinPath = "C:/Program Files/Side Effects Software/Houdini 20.5.305/bin";

#ifdef _WIN32
	_putenv(("HFS=" + std::string(houdiniBasePath)).c_str());
	_putenv((std::string("PATH=") + getenv("PATH") + ";" + houdiniBinPath).c_str());
#else
	setenv("HFS", houdiniBasePath, 1);
	std::string path = std::string(getenv("PATH")) + ":" + houdiniBinPath;
	setenv("PATH", path.c_str(), 1);
#endif
}

void *HEGoPlatform::load_lib_hapil()
{
	void *libHAPIL = nullptr;

#if defined(_WIN32)
	char *buf;
	size_t len;
	if (_dupenv_s(&buf, &len, "HFS") == 0 && buf != nullptr)
	{
		std::string libHAPIL_dir(buf);
		free(buf);

		libHAPIL_dir.append("\\bin\\"); // Use backslashes for Windows paths
		if (SetDllDirectoryA(libHAPIL_dir.c_str()) != 0)
		{
			libHAPIL = LoadLibraryA(HAPI_LIB_OBJECT_WINDOWS);
		}
		else
		{
			std::cerr << "Failed to set DLL directory to " << libHAPIL_dir << std::endl;
		}
	}
	else
	{
		std::cerr << "Unable to retrieve the value of the HFS environment variable." << std::endl;
		return nullptr;
	}
#elif defined(__linux__)
	libHAPIL = dlopen(HAPI_LIB_OBJECT_LINUX, RTLD_LAZY);
#else
	libHAPIL = dlopen(HAPI_LIB_OBJECT_MAC, RTLD_LAZY);
#endif

	if (libHAPIL == nullptr)
	{
		std::cerr << "Failed to load the libHAPIL module." << std::endl;
	}

	return libHAPIL;
}

bool HEGoPlatform::free_lib_hapil(void *libHAPIL)
{
#if defined(_WIN32)
	BOOL result = FreeLibrary((HMODULE)libHAPIL);
	SetDllDirectoryA(nullptr); // Reset the DLL directory to default
	return result != 0;
#else
	return dlclose(libHAPIL) == 0;
#endif
}

void *HEGoPlatform::get_dll_export(void *library_handle, const char *export_name)
{
#if defined(_WIN32)
	return GetProcAddress((HMODULE)library_handle, export_name);
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
		HEGo::Util::Log::error("Failed to load and initialize the Houdini Engine API from libHAPIL");
		return nullptr;
	}

	HEGo::Util::Log::message("Loaded and initialized libHAPIL.");

	return libHAPIL;
}
