/// Build metadata — overwritten by build.sh / install.sh with the actual git commit hash.
/// If you see "dev", the app was built directly with `swift build` without the build scripts.
enum BuildInfo {
    static let commitHash = "dev"
}
