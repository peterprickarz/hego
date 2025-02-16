import sys

def parse_file(file_path):
    # List to store the matched substrings
    matched_substrings = []

    # Read the file and search for the pattern
    with open(file_path, 'r') as file:
        content = file.read()

    # Split the content into lines
    lines = content.splitlines()
    
    # Buffer to hold the current HAPI_DECL substring
    current_decl = ""
    inside_decl = False

    for line in lines:
        stripped_line = line.strip()
        if "HAPI_DECL" in stripped_line or "HAPI_DECL_RETURN" in stripped_line:
            inside_decl = True
            current_decl = stripped_line
            if ";" in stripped_line:
                matched_substrings.append(current_decl)
                current_decl = ""
                inside_decl = False
        elif inside_decl:
            current_decl += " " + stripped_line
            if ";" in stripped_line:
                matched_substrings.append(current_decl)
                current_decl = ""
                inside_decl = False

    # Clean the matched substrings by removing extra whitespaces
    cleaned_substrings = [' '.join(substring.split()) for substring in matched_substrings]

    # Create a list of dictionaries with type, func, and args
    parsed_entries = []
    for substring in cleaned_substrings:
        if "HAPI_DECL_DEPRECATED_REPLACE" in substring:
            continue
        elif "HAPI_DECL_RETURN" in substring:
            type_start = substring.find("(")+1
            type_end = substring.find(")", type_start)
            type_part = substring[type_start:type_end].strip()
            func_start = substring.find("HAPI_", type_end) + len("HAPI_")
        else:
            type_part = "HAPI_Result"
            func_start = substring.find("HAPI_", substring.find("HAPI_DECL")+len("HAPI_DECL")) + len("HAPI_")
        
        func_end = substring.find("(", func_start)
        func_part = substring[func_start:func_end].strip()

        args_start = func_end + 1
        args_end = substring.find(")", args_start)
        args_part = substring[args_start:args_end].strip()

        parsed_entry = {
            "type": type_part,
            "func": func_part,
            "args": args_part
        }
        parsed_entries.append(parsed_entry)

    return parsed_entries

def format_function_pointers(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_type = item.get('type', '')
        func_name = item.get('func', '')
        func_args = item.get('args', '')
        
        formatted_string = f"typedef {func_type}(*{func_name}FuncPtr)({func_args});"
        formatted_list.append(formatted_string)
    
    return formatted_list

def format_static_function_pointers(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_name = item.get('func', '')
        
        formatted_string = f"static {func_name}FuncPtr {func_name};"
        formatted_list.append(formatted_string)
    
    return formatted_list


def format_empty_stub_functions(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_type = item.get('type', '')
        func_name = item.get('func', '')
        func_args = item.get('args', '')
        
        formatted_string = f"static {func_type} {func_name}EmptyStub({func_args});"
        formatted_list.append(formatted_string)
    
    return formatted_list


def format_houdini_api_functions(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_name = item.get('func', '')
        
        formatted_string_1 = f"HoudiniApi::{func_name}FuncPtr"
        formatted_string_2 = f"HoudiniApi::{func_name} = &HoudiniApi::{func_name}EmptyStub;"
        
        formatted_list.append(formatted_string_1)
        formatted_list.append(formatted_string_2)
        formatted_list.append("")
    
    return formatted_list

def format_houdini_api_initialization(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_name = item.get('func', '')
        
        formatted_string = f'HoudiniApi::{func_name} = ({func_name}FuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_{func_name}");'
        formatted_list.append(formatted_string)
    
    return formatted_list

def format_houdini_api_stub_initialization(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_name = item.get('func', '')
        
        formatted_string = f"HoudiniApi::{func_name} = &HoudiniApi::{func_name}EmptyStub;"
        formatted_list.append(formatted_string)
    
    return formatted_list

def format_houdini_api_five_lines(dict_list):
    formatted_list = []
    
    for item in dict_list:
        func_type = item.get('type', '')
        func_name = item.get('func', '')
        func_args = item.get('args', '')

        formatted_list.append(f"{func_type}")
        formatted_list.append(f"HoudiniApi::{func_name}EmptyStub({func_args})")
        formatted_list.append("{")

        if func_type == "HAPI_Result":
            return_statement = " HAPI_RESULT_FAILURE;"
        elif func_type.startswith("HAPI_"):
            return_statement = f" {func_type}();"
        elif func_type == "int":
            return_statement = " -1;"
        else:
            return_statement = ";"

        formatted_list.append(f"    return{return_statement}")
        formatted_list.append("}")

    return formatted_list

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python parse_hapi.py <file_path1> <file_path2> ...")
        sys.exit(1)

    file_paths = sys.argv[1:]
    all_entries = []

    for file_path in file_paths:
        entries = parse_file(file_path)
        all_entries.extend(entries)
        
    typedefs = format_function_pointers(all_entries)
    function_declarations = format_static_function_pointers(all_entries)
    stub_declarations = format_empty_stub_functions(all_entries)
    initialize_as_stubs = format_houdini_api_functions(all_entries)
    initializations = format_houdini_api_initialization(all_entries)
    deinitializations = format_houdini_api_stub_initialization(all_entries)
    stub_definitions = format_houdini_api_five_lines(all_entries)
    # Print each dictionary entry
    for entry in typedefs:
        print(entry)
    print("-----------------------------")
    for entry in function_declarations:
        print(entry)
    print("-----------------------------")
    for entry in stub_declarations:
        print(entry)
    print("-----------------------------")
    for entry in initialize_as_stubs:
        print(entry)
    print("-----------------------------")
    for entry in initializations:
        print(entry)
    print("-----------------------------")
    for entry in deinitializations:
        print(entry)
    print("-----------------------------")
    for entry in stub_definitions:
        print(entry)
        
    header = """
#pragma once
#include "HAPI/HAPI.h"


struct HoudiniApi
{
public:

    static void initialize_hapi(void* library_handle);
    static void finalize_hapi();
    static bool is_hapi_initialized();

public:

"""
    for line in typedefs:
        header += """   """ + line + "\n"
    header += """

public:
    
"""
    for line in function_declarations:
        header += """   """ + line + "\n"
    
    header += """

public:
    
"""
    for line in stub_declarations:
        header += """   """ + line + "\n"
        
    header += """
};    
"""
    print(header)
    
    
    cpp = """

#include "houdini_api.h"
#include "hego_platform.h"    

"""

    for line in initialize_as_stubs:
        cpp += """  """ + line + "\n"
        
    cpp += """

void
HoudiniApi::initialize_hapi(void* library_handle)
{
	if(!library_handle) return;

"""
    for line in initializations:
        cpp += """  """ + line + "\n"

    cpp+= """

}


void
HoudiniApi::finalize_hapi()
{
    
"""

    for line in deinitializations:
        cpp += """  """ + line + "\n"


    cpp += """
}


bool
HoudiniApi::is_hapi_initialized()
{
	return ( HoudiniApi::IsInitialized != &HoudiniApi::IsInitializedEmptyStub );
}

    


"""
    for line in stub_definitions:
        cpp += line + "\n"
        
    print(cpp)
    
    with open('houdini_api.h' ,'w') as file:
        file.write(header)
        
    with open('houdini_api.cpp' ,'w') as file:
        file.write(cpp)