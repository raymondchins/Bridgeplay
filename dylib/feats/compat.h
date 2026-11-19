// Compatibility tool support
#ifndef NOTPROTON_FEATS_COMPAT_H
#define NOTPROTON_FEATS_COMPAT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Manager tool array: base pointer at TOOL_ARRAY_OFF, count at TOOL_COUNT_OFF,
// fixed per-entry stride from np_compat_tool_stride.
#define COMPAT_MANAGER_TOOL_ARRAY_OFF  0x320
#define COMPAT_MANAGER_TOOL_COUNT_OFF  0x330
#define COMPAT_TOOL_NAME_OFF           0x40  // reference; live through np_compat_tool_off

#define COMPAT_MANAGER_TOOLS_HEADROOM  32

// Platform bits GetValidPlatforms reports.
#define COMPAT_PLATFORM_WINDOWS  0x1
#define COMPAT_PLATFORM_MACOS    0x2

// Every offset below is the reference layout. Clients have grown the entry at two points:
// ahead of the "unlisted" field (COMPAT_TOOL_HEAD_OFF, beta 1795048523 added 8 bytes there)
// and ahead of the install dir (COMPAT_TOOL_INSTALL_OFF). Read live values through
// np_compat_tool_off, which applies whichever shifts sit below a field.
#define COMPAT_TOOL_HEAD_OFF        0x24
#define COMPAT_TOOL_GATE_FLAGS_OFF  0x24
#define COMPAT_TOOL_GATE_HIDDEN     0x1
#define COMPAT_TOOL_PRIORITY_OFF    0x38
#define COMPAT_TOOL_DISPLAY_OFF     0x50
#define COMPAT_TOOL_INSTALL_OFF     0x58
#define COMPAT_TOOL_APPID_OFF       0x60
#define COMPAT_TOOL_PLATFORM_OFF    0x80

// Reads the name's live offset from YldRegisterTool, whose first load through the tool
// argument is the name, and from it the shift at COMPAT_TOOL_HEAD_OFF. Returns 0 when the
// load is not found, which leaves the layout unverified (np_compat_layout_known).
int np_compat_probe_tool_head(uintptr_t yld_register_tool);

// Reads live field offsets from the appid and install-dir gates. Returns 0 when
// the two disagree about how far the struct shifted. The oslist gate is optional
// and corroborates the result at the far end.
int np_compat_probe_tool_layout(uintptr_t appid_gate, uintptr_t oslist_gate);

// 1 once both probes agreed on a layout. Writing a tool entry into the manager is only
// safe then; a wrong layout hands the client an entry it crashes on.
int np_compat_layout_known(void);

// Reads the enabled-flag offset from BIsCompatibilityToolEnabled. Returns 0
// when the flag cannot be located, leaving the baseline in place.
int np_compat_probe_enabled_off(uintptr_t bis_enabled);
uint32_t np_compat_enabled_off(void);

// Reads the windows-only table's offset out of the lookup call in GetWildcardMapping,
// returns 0 when the call is not found.
int  np_compat_probe_windows_only_off(uintptr_t get_wildcard_mapping, uintptr_t lookup);
bool np_compat_is_windows_only_table(const void *compat_mgr, const void *map);

void *np_compat_user(const void *compat_mgr);

// Live position of a field by its reference offset. Fields ahead of
// COMPAT_TOOL_HEAD_OFF come back unchanged.
uint32_t np_compat_tool_off(uint32_t reference_off);

// Live stride of the manager's tool array.
size_t np_compat_tool_stride(void);

// A tool entry's name, or NULL when the slot holds no plausible pointer.
const char *np_compat_tool_name(const void *tool);

// Exports STEAM_EXTRA_COMPAT_TOOLS_PATHS. Must run before any thread but the
// initial one exists (setenv can free the environ the client is reading).
void np_compat_export_tools_path(void);

// Reads the app's tool list into g_tools, skipping lines that do not parse. Returns the
// number of tools kept.
int  np_compat_load_tool_list(const char *path, const char *tools_dir);

// Writes a directory for every tool in the app's list and removes the directories of tools
// no longer in it.
int  np_compat_ensure_tool_manifest(void);
void np_compat_force_enable(void *compat_mgr);

// Platform bitmask for an app. Reports 0 when the function was not resolved,
// which reads as "cannot say" rather than as every platform at once.
void     np_compat_set_valid_platforms_fn(uintptr_t get_valid_platforms);
uint32_t np_compat_valid_platforms(void *compat_mgr, uint32_t appid);

// The tool an app will run under: user mapping if present, CrossOver default
// otherwise. Goes through the same function the launch path uses.
void  np_compat_set_find_tool_fn(uintptr_t find_tool_for_target_app);
void *np_compat_tool_for_app(void *compat_mgr, uint32_t appid);

// The tool from the client's own mapping alone, without the CrossOver default.
// The properties page needs the two apart to show absence vs. choice.
void  np_compat_set_chosen_tool_fn(uintptr_t find_tool_for_target_app);
void *np_compat_chosen_tool(void *compat_mgr, uint32_t appid);

// Whether an app gets the CrossOver default: windows-only with no macOS.
//
// Deliberately blind to whether a macOS build can actually run. A 32-bit macOS
// build cannot run on a current system, but moving it onto a tool means fetching
// the windows build in full -- a choice to be offered, not taken.
bool np_compat_would_force(void *compat_mgr, uint32_t appid);

// The wildcard (global default) mapping as it applies to one app, or NULL. Asked
// rather than reconstructed because the client scopes it by architecture as well
// as platform, which diverges from the default on a 32-bit macOS build.
void        np_compat_set_wildcard_fn(uintptr_t get_wildcard_mapping);
const char *np_compat_wildcard_mapping(void *compat_mgr, uint32_t appid);

// The app's own mapping entry, or NULL. A live pointer into the client's mapping
// table (not a copy). This is what the user chose, not what the client resolved:
// the two diverge when the named tool is not installed, which resolves to nothing
// and is how an app is taken off tools. Refuses appid zero.
void        np_compat_set_app_mapping_fn(uintptr_t find_mapping);
const char *np_compat_app_mapping(void *compat_mgr, uint32_t appid);

// Maps an app to a tool (what the dropdown does). Empty `tool_name` clears back
// to the client default. Appid zero sets the global default at lower priority.
void np_compat_set_mapping_fn(uintptr_t set_compat_tool_mapping);
void np_compat_map_tool(void *compat_mgr, uint32_t appid, const char *tool_name);

// CCompatManager::YldRegisterTool, resolved at install time.
void np_compat_set_register_fn(uintptr_t yld_register_tool);

// Registers every tool in the app's list into the given manager once. The local
// compatibilitytools.d scan uses a different instance than the dropdown reads
// and does not run on every launch, so this registers into the right one.
void np_compat_register_crossover(void *compat_mgr);

// The manager the properties page enumerates, or NULL before the first compat
// query. Captured at registration, not construction (the compatibilitytools.d
// scan builds a different instance).
void *np_compat_manager(void);

// The first tool in the app's list the manager holds, or NULL.
// Manager-owned. Callers read fields without taking ownership.
void *np_compat_registered_tool(void *compat_mgr);

// Name of the first tool in the app's list, which unmapped Windows games run under.
const char *np_compat_fallback_tool_name(void);

// Names of the listed tools whose flavor is fex, up to max. Returns how many it wrote.
size_t np_compat_fex_tools(const char **names, size_t max);

uint32_t np_compat_manager_tools_max(void);

// Absolute path to the directory of the first tool in the app's list, or NULL.
const char *np_compat_tool_dir(void);

// True when the launch command runs a Bridgeplay compatibility tool.
int np_compat_runs_tool(const char *cmd);

// True when the app is set to run with a Bridgeplay compatibility tool.
int np_compat_app_runs_tool(uint32_t appid);

// Command line template for the tool's toolmanifest.vdf commandline value.
const char *np_compat_tool_commandline(void);

#endif // NOTPROTON_FEATS_COMPAT_H
