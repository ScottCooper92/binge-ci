# Shared Gradle gates

Gradle plugins for the build checks the consumers share. Each one wires its task into `check`, so a
consumer's `./gradlew build` runs it with nothing else to remember.

They used to be copied between repositories, like the bots were. This is the one copy.

This is a Gradle included build, not a published artifact. A consumer already pins binge-ci by
commit, so the gates arrive at that commit with no new repository and no new pin.

## The plugins

| Plugin id | Task | Fails when |
| --- | --- | --- |
| `binge.gates.translation-staleness` | `checkTranslationStaleness` | A translated source string changed and its translations were not re-confirmed. |
| `binge.gates.detekt` | `detekt` | detekt finds a new violation. The plugin is the wiring; the rules are the consumer's. |
| `binge.gates.baseline-staleness` | `checkBaselineStaleness` | The detekt baseline holds an entry the code no longer produces. |
| `binge.gates.tv-material-separation` | `checkTvMaterialSeparation` | TV source imports Material 3, or phone source imports tv-material. |

### Translation staleness

Lint catches a missing translation, an extra one and a drifted placeholder. It does not catch a
reworded source string, because the translation is still there and still well-formed. So the hash
of every translated source string is committed, and the check fails when one moves.

The fix is to read the translation it names, then run `./gradlew updateTranslationHashes` and
commit the hash file. There is no allowlist: re-stamping is the record that someone looked.

Apply it to the project at the repository root, or to the one module that holds the strings.

```kotlin
translationStaleness {
    hashFile = layout.settingsDirectory.file("translation-hashes.txt") // the default
    excludes.add("shared-ui/**") // an included build that checks its own strings
}
```

`rootDirectory` (default: the settings directory) is what paths and module keys are relative to.
`includes` and `excludes` are globs under it, and `stringFiles` adds files by hand.

### detekt

Applies `io.gitlab.arturbosch.detekt` at the version in this build's catalog, so a consumer applies
`binge.gates.detekt` in its place. It does three things a bare detekt setup does not.

- **Production source only.** Every detekt task reads `src/main`, minus files named `…PreviewData.kt`.
- **Type resolution.** A detekt task carries no classpath by default, and without one the rules
  that need types load and never fire. `UnsafeCallOnNullableType`, the `!!` ban, is one. The plugin
  wires the compile classpath of one Kotlin compilation onto every detekt task: `main` on a JVM
  project, `debug` on an Android one.
- **An optional baseline**, so the gate can be zero new findings rather than zero total.

```kotlin
detektGate {
    baselineFile = layout.settingsDirectory.file("detekt-baseline.xml") // unset means no baseline
    customRulesProject = ":detekt-rules" // unset means none
}
```

`configFile` defaults to `detekt.yml` in the settings directory. `sourceDirectory`, `excludes`,
`jvmTarget` (`17`), `buildUponDefaultConfig` (true), `parallel` (true) and
`typeResolutionCompilation` cover the rest. The custom rules stay in the consumer; only the wiring
is shared.

### Baseline staleness

detekt passes on a baseline entry that matches nothing. An orphaned entry reads as debt still owed,
and it absorbs the next real finding of that rule in that file. This plugin runs detekt once more
with no baseline, as `detektWithoutBaseline`, and fails on any baselined rule and file the run no
longer reports.

It applies `binge.gates.detekt` and reads the same config, source and `baselineFile`, so the two runs
agree on which rules are on. With no baseline set, or none on disk, both tasks skip.

### tv-material separation

`androidx.tv.material3` and `androidx.compose.material3` each ship a `MaterialTheme`. The symbols
share a simple name, so the wrong import compiles and renders subtly wrong. The check reads import
lines only, so the package names can still appear in prose.

A file is **TV source** if it sits under one of `tvModulePaths`, or has a `tvPackage` segment in its
path. A file under one of `neutralPackages` may import neither library. Everything else is **phone
source**. The one sanctioned crossing is a token adapter, named in `allowlist`.

```kotlin
tvMaterialSeparation {
    sources.from(fileTree(".") { include("**/src/**/*.kt"); exclude("**/build/**") })
    tvModulePaths.add("ui-tv")
    tvPackage = "tv" // the default
    neutralPackages.add("catalog/registry")
    allowlist.add("ui-tv/src/main/kotlin/com/example/tv/theme/Tokens.kt")
    themeTypeNames.addAll("AppColors", "AppShapes") // quoted in the failure message
}
```

`sources` is required: a check that finds no files fails rather than passing. Paths are relative to
`rootDirectory`, which defaults to the settings directory. To keep the allowlist in a file, read it
into the property: `allowlist.addAll(file("tv-allowlist.txt").readLines().filter { it.isNotBlank() })`.

## Using them

Include the build in `settings.gradle.kts`, at the path where the consumer has binge-ci checked out:

```kotlin
pluginManagement {
    includeBuild("binge-ci/gradle-plugins")
}
```

Then apply a plugin by id, with no version:

```kotlin
plugins {
    id("binge.gates.detekt")
    id("binge.gates.baseline-staleness")
}
```

Each consumer adopts the gates in a PR of its own, replacing its copy of the check in the same PR.
Nothing here changes a consumer's build until it does.

## Versions

`gradle/libs.versions.toml` pins detekt, the Kotlin Gradle plugin and JUnit to the consumers'
versions. The Kotlin plugin is compiled against and never shipped: the consumer's build supplies it.
The Gradle wrapper matches the consumers' too.

## Its own gate

`./gradlew build` in this directory compiles the plugins, validates them and runs the tests. Every
gate is tested against a case it must pass and a case it must fail, because a gate that breaks
usually breaks by passing everything. CI runs it as the `gradle-plugins` job.
