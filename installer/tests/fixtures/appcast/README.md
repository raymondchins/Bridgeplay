# Appcast fixtures

Feeds signed by Sparkle 2.10.0's own `generate_appcast`, with a throwaway Ed25519 key that was
never used for anything else and is not kept. They cover what the stable feed will carry once
it is signed and has the `bridgeplay:containsBetas` element. The native installer's parser must
read them exactly as it reads an unsigned feed, and so must the parser shipped in 0.7.63
(`7ebae5f`).

- `signed.xml`: a signed feed with one stable item (3.5.0, build 35).
- `signed-betas-empty.xml`: the same, with an empty `<bridgeplay:containsBetas/>`.
- `signed-betas-list.xml`: the same, with `81-85,87`.

To regenerate: build a dummy arm64 app (`CFBundleShortVersionString` 3.5.0, `CFBundleVersion` 35,
`LSMinimumSystemVersion` 26.0, `SUPublicEDKey` of the throwaway key, `SURequireSignedFeed` true),
zip it as `Bridgeplay.zip`, and run `generate_appcast --ed-key-file <throwaway> --maximum-versions 1
--download-url-prefix https://github.com/raymondchins/Bridgeplay/releases/download/v3.5.0/`. For the
element variants add the namespace and element to the generated feed and run `generate_appcast`
again to sign it. Do not use the release key.
