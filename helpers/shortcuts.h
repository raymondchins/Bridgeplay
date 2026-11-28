#ifndef NP_SHORTCUTS_H
#define NP_SHORTCUTS_H

// Replaces shortcut.icns in the app's Steam shortcuts that still hold a copy of stock_path.
void np_shortcuts_icons(const char *home, const char *app_id, const char *icon_path, const char *stock_path);

// Files the app's Steam shortcuts in ~/Applications with games (LSApplicationCategoryType), so
// Spotlight and the Games app list them as games. Calls changed() with each bundle it edits.
void np_shortcuts_games(const char *home, const char *app_id, void (*changed)(const char *path));

#endif
