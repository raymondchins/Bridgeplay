// Build version string
#ifndef NOTPROTON_VERSION_H
#define NOTPROTON_VERSION_H

#define NOTPROTON_VERSION "1.2.0"

// Bridgeplay's own version, independent of the NotProton release above, which stays
// exactly as upstream ships it so merging upstream never conflicts here.
//   BRIDGEPLAY_VERSION  semver people see, kept slow: patch for normal releases, minor for milestones
//                       (CFBundleShortVersionString, sparkle:shortVersionString)
//   BRIDGEPLAY_BUILD    +1 on every release, continuing the old "-ray.N" counter; Sparkle
//                       orders updates by it (CFBundleVersion, sparkle:version)
// Both are committed as they are for a stable release: a plain X.Y.Z and the next build. A beta
// build stamps its X.Y.Z-beta.N label, build number and channel in at build time
// (scripts/stamp-beta.sh); those are never committed.
// Change both with scripts/bump-version.sh, see docs/RELEASING.md.
#define BRIDGEPLAY_VERSION "0.7.60"
#define BRIDGEPLAY_BUILD 77

#endif // NOTPROTON_VERSION_H
