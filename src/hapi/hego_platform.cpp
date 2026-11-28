#include "hapi/hego_platform.h"
#include "hapi/houdini_api.h"
#include "util/log/log.h"
#include <cstdlib>
#include <godot_cpp/classes/project_settings.hpp>
#include <string>

#ifdef _WIN32
#include <tchar.h>
#include <vector>
#include <windows.h>

#else
#include <dlfcn.h>
#include <godot_cpp/classes/os.hpp>
#endif

const char *HAPI_LIB_OBJECT_WINDOWS = "libHAPIL.dll";
const char *HAPI_LIB_OBJECT_LINUX = "libHAPIL.so";
const char *HAPI_LIB_OBJECT_MAC = "libHAPIL.dylib";

#ifdef _WIN32
namespace
{
DWORD start_houdini(const godot::String &executable, const godot::String &command, LPPROC_THREAD_ATTRIBUTE_LIST attributes)
{
	STARTUPINFOEXW startup{};
	startup.StartupInfo.cb = attributes ? sizeof(startup) : sizeof(STARTUPINFOW);
	startup.lpAttributeList = attributes;
	const DWORD flags = CREATE_NO_WINDOW | (attributes ? EXTENDED_STARTUPINFO_PRESENT : CREATE_BREAKAWAY_FROM_JOB);
	PROCESS_INFORMATION process{};
	auto command_line = command.wide_string();
	if (!CreateProcessW(executable.wide_string().get_data(), command_line.ptrw(), nullptr, nullptr, FALSE, flags,
				nullptr, nullptr, &startup.StartupInfo, &process))
		return GetLastError();

	CloseHandle(process.hThread);
	CloseHandle(process.hProcess);
	return ERROR_SUCCESS;
}
} // namespace
#endif

bool HEGoPlatform::open_hip_snapshot(const godot::String &executable, const godot::String &path, bool indie)
{
#ifdef _WIN32
	// Both quoted arguments are Windows filenames, and the snapshot always ends in a HIP extension.
	const godot::String command = "\"" + executable + "\" " + (indie ? "-indie " : "") + "\"" + path + "\"";
	const DWORD error = start_houdini(executable, command, nullptr);
	if (error != ERROR_ACCESS_DENIED)
		return error == ERROR_SUCCESS;

	// Godot 4.7's console wrapper disallows breakaway. Use the desktop shell as the parent
	// so Houdini inherits its job while keeping the editor's Houdini environment and working directory.
	BOOL in_job = FALSE;
	if (!IsProcessInJob(GetCurrentProcess(), nullptr, &in_job) || !in_job)
		return false;
	DWORD shell_pid = 0;
	if (!GetWindowThreadProcessId(GetShellWindow(), &shell_pid))
		return false;
	SIZE_T size = 0;
	InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
	std::vector<char> storage(size);
	auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
	if (!size || !InitializeProcThreadAttributeList(attributes, 1, 0, &size))
		return false;

	bool started = false;
	HANDLE shell = OpenProcess(PROCESS_CREATE_PROCESS, FALSE, shell_pid);
	if (shell)
	{
		if (UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS, &shell, sizeof(shell), nullptr, nullptr))
			started = start_houdini(executable, command, attributes) == ERROR_SUCCESS;
		CloseHandle(shell);
	}
	DeleteProcThreadAttributeList(attributes);
	return started;
#else
	// Godot creates the child in a new POSIX session.
	godot::PackedStringArray arguments;
	if (indie)
		arguments.push_back("-indie");
	arguments.push_back(path);
	return godot::OS::get_singleton()->create_process(executable, arguments) > 0;
#endif
}

const char *HEGoPlatform::get_default_houdini_path()
{
	// Keep in sync with SConstruct's default_hfs and with hego.gd, which seeds the
	// project setting with the same per-platform defaults.
	//
	// Linux points at the hfs22.0 symlink SideFX maintains, so a new production build
	// of the same major version is picked up without a code change. Windows and macOS
	// install into a directory named after the exact build and have no such symlink,
	// so those have to name one.
#if defined(_WIN32)
	return "C:/Program Files/Side Effects Software/Houdini 22.0.429";
#elif defined(__APPLE__)
	return "/Applications/Houdini/Houdini22.0.429/Frameworks/Houdini.framework/Versions/Current/Resources";
#else
	return "/opt/hfs22.0";
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
	if (env_path && env_path[0] != '\0')
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
	const char *current_path = std::getenv("PATH");
	std::string path = current_path ? current_path : "";

	// HAPI_CLIENT_NAME=godot lets Houdini Engine accept a Houdini Indie license for this
	// client (Houdini 22.0.510 and later; older builds ignore it). Servers HEGo starts
	// inherit it; a server that was already running keeps its own environment.
#ifdef _WIN32
	_putenv("HAPI_CLIENT_NAME=godot");
	_putenv(("HFS=" + std::string(houdiniBasePath)).c_str());
	if (!path.empty())
		path += ";";
	path += houdiniBinPath;
	_putenv(("PATH=" + path).c_str());
#else
	setenv("HAPI_CLIENT_NAME", "godot", 1);
	setenv("HFS", houdiniBasePath, 1);
	if (!path.empty())
		path += ":";
	path += houdiniBinPath;
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
	// PATH locates Houdini's executables, not shared libraries. Load the selected
	// installation explicitly so this also works when Godot is launched from Finder
	// and when the build machine's Houdini path does not exist on this machine.
	const std::string houdini_base_path = get_houdini_path();
#if defined(__APPLE__)
	const char *library_name = HAPI_LIB_OBJECT_MAC;
	// HFS is Houdini.framework/Resources (or Versions/Current/Resources).
	const std::string full_path = houdini_base_path + "/../Libraries/" + library_name;
#else
	const char *library_name = HAPI_LIB_OBJECT_LINUX;
	const std::string full_path = houdini_base_path + "/dsolib/" + library_name;
#endif

	void *libHAPIL = dlopen(full_path.c_str(), RTLD_LAZY);
	if (!libHAPIL)
	{
		const char *dl_error = dlerror();
		const std::string path_error = dl_error ? dl_error : "unknown error";
		// Preserve support for installations configured through the process's
		// loader search path before Godot starts.
		libHAPIL = dlopen(library_name, RTLD_LAZY);
		if (!libHAPIL)
		{
			dl_error = dlerror();
			HEGo::Util::Log::error(HEGo::Util::Log::Category::PLATFORM, godot::String("Failed to load ") + full_path.c_str() + ": " + path_error.c_str() +
					"\nFallback loader search for " + library_name + " also failed: " + (dl_error ? dl_error : "unknown error"));
		}
		else
		{
			HEGo::Util::Log::warning(HEGo::Util::Log::Category::PLATFORM, godot::String("Could not load ") + full_path.c_str() + ": " + path_error.c_str() +
					". Loaded " + library_name + " through the system loader search path instead.");
		}
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
