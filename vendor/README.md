# Vendored dependencies

## cJSON

`cJSON.c` and `cJSON.h`, version 1.7.19 (`CJSON_VERSION_*` in `cJSON.h`), MIT licensed, used
by the signature database loader. When updating, compare with the current cJSON release and
its security fixes.

## Ed25519

`ed25519/`: Orson Peters' Ed25519 (SUPERCOP ref10), zlib licensed (`LICENSE.orlp-ed25519`), as
Sparkle 2.10.1 vendors it (sparkle-project/ed25519 at `7fa6712ef5d581a6981ec2b08ee623314cd1d1c4`,
Sparkle's `Vendor/ed25519-sparkle/src`). Files are unchanged; `seed.c`, `add_scalar.c` and
`key_exchange.c` are left out. The dylib builds only the verification files (`ED25519_SRCS` in
the Makefile) to check the pause list; `sign.c` and `keypair.c` are for `pauselistcheck`.

## JsonCpp

`steam-shim/jsoncpp.cpp` and `steam-shim/json/`, the amalgamated JsonCpp 1.6.5
(`JSONCPP_VERSION_STRING`), public domain / MIT, used by steam-shim.

## Dobby

Apache 2.0 licensed, isn't tracked in repo, clone it at the commit used by this project:

    git clone https://github.com/jmpews/Dobby.git vendor/dobby
    git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7

Then run `make dobby`, which builds it into `build/dobby/`. If you change the commit, check that the hooks still install, and update
`DOBBY_COMMIT` in `.github/workflows/app.yml` to match.
