// Google's mirror of Maven Central is asked first. Shared runners are rate-limited by Central, and
// Gradle treats a 429 as a failure rather than a miss, so the build would stop before trying the next.
pluginManagement {
    repositories {
        maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        gradlePluginPortal()
    }
}

// The catalog is gradle/libs.versions.toml, which Gradle picks up as `libs` with nothing declared.
// It is this build's own: a consumer's catalog does not reach an included build.
dependencyResolutionManagement {
    repositories {
        maven("https://maven-central.storage-download.googleapis.com/maven2/") { name = "MavenCentralMirror" }
        mavenCentral()
        gradlePluginPortal()
    }
}

rootProject.name = "gradle-plugins"
