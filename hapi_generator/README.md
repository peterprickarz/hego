This script is really janky and ugly, hacked together in a very short time with AI...

It generates the `src/hapi/houdini_api.h` and `src/hapi/houdini_api.cpp` files by parsing the HAPI headers from your Houdini install. If you want to build against a different version of Houdini, run the script and copy paste the resulting files into `src/hapi`

To use it, open a terminal in this folder and run this - replace the version if you want to build against a newer version
```
python generate_houdini_api.py
"C:\Program Files\Side Effects Software\Houdini 20.5.487\toolkit\include\HAPI\HAPI.h"
"C:\Program Files\Side Effects Software\Houdini 20.5.487\toolkit\include\HAPI\HAPI_Common.h"
"C:\Program Files\Side Effects Software\Houdini 20.5.487\toolkit\include\HAPI\HAPI_Helpers.h"
"C:\Program Files\Side Effects Software\Houdini 20.5.487\toolkit\include\HAPI\HAPI_Version.h"
```
