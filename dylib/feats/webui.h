// WebUI route registration for routes the macOS client does not serve.
// Needed since the October 13th 2026 Steam client update (1791918634), which has a new UI.
#ifndef NOTPROTON_FEATS_WEBUI_H
#define NOTPROTON_FEATS_WEBUI_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

// The Compatibility page in the new UI needs GetCompatTools and SpecifyCompatTool,
// neither of which are served on the macOS client, rudely.
int np_webui_init(const struct mach_header_64 *mh, intptr_t slide,
                  uintptr_t register_fn, uintptr_t dispatch_fn,
                  uintptr_t send_response);

uintptr_t np_webui_registry(void);

// Logs every route the client serves. Runs with NOTPROTON_WEBUI_ROUTES set.
void np_webui_dump_routes(void);

// The instruction where the dispatcher looks up a route, or 0.
uintptr_t np_webui_lookup_site(uintptr_t register_fn, uintptr_t dispatch_fn);

// Fills `message` from protobuf bytes through the client's own parser,
// returns 1 on success.
int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len);

// Builds a message of the type `vptr` names. Only the client's own message
// classes produce objects it will accept.
uintptr_t np_webui_new_message(uintptr_t vptr);

// Invalidates a route so the page refetches rather than showing stale data.
int np_webui_notify(const char *name, uintptr_t message);

// Runs `fn` at the start of every route job, on the client's job thread.
void np_webui_on_job(int (*fn)(void));

// Fills `response` from `request`. The return value is the result the page sees,
// where 1 is success.
typedef int (*np_webui_handler_fn)(uintptr_t request, uintptr_t response);

// Serves `name` from `handler`. The vptrs name the client's constructors
// (vtable slot 3 is no-argument New). Routes may share message types. Returns 1
// once the route is live.
int np_webui_register_route(const char *name, uintptr_t request_vptr,
                           uintptr_t response_vptr, np_webui_handler_fn handler);

#endif // NOTPROTON_FEATS_WEBUI_H
