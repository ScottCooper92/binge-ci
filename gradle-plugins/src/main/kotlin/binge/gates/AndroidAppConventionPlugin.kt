package binge.gates

import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmCompilerOptions
import org.jetbrains.kotlin.gradle.tasks.KotlinCompilationTask
import java.util.Properties

/** Configuration for `binge.conventions.android-app`. Everything an app does differently stays in its own `android {}` block. */
abstract class AndroidAppConventionExtension {
    /**
     * The committed debug keystore, with AOSP's own debug credentials. Committed rather than left to AGP's implicit one,
     * which generates a different key on every machine and runner, so installing one debug build over another signed by
     * an earlier key fails as a signature mismatch. Unset, it is `app/debug.keystore` at the root; with no file at the path,
     * the debug build type keeps AGP's own.
     */
    abstract val debugKeystore: RegularFileProperty

    /** The Java and Kotlin target. Unset, it is 17. */
    abstract val jvmVersion: Property<Int>
}

/**
 * Configures what the Android apps share in their `android {}` block, once AGP's application plugin is applied: the Java and
 * Kotlin target, the lint checks that make a translation complete or absent, the locale config, the debug and release build
 * types, the committed debug signing key and the release signing from the environment, and the version from the environment.
 * What an app differs in stays in its own block: its namespace, id, SDK levels, instrumentation runner, build config fields
 * and managed devices.
 */
class AndroidAppConventionPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val convention = project.extensions.create("androidAppConvention", AndroidAppConventionExtension::class.java)

        project.pluginManager.withPlugin("com.android.application") {
            project.extensions.configure(ApplicationExtension::class.java) { configure(project) }
            // The plugin is applied from the `plugins {}` block, before the app's own `androidAppConvention {}` block runs, so
            // the two settings are read once the whole DSL is final. An app's own `android {}` values are set by then, and a
            // setting here wins over a value it gave for the same thing.
            project.extensions.getByType(ApplicationAndroidComponentsExtension::class.java).finalizeDsl { dsl ->
                dsl.applyJvmVersion(convention)
                dsl.applyDebugKeystore(project, convention)
            }
        }
        project.tasks.withType(KotlinCompilationTask::class.java).configureEach {
            (compilerOptions as? KotlinJvmCompilerOptions)?.jvmTarget?.set(
                convention.jvmVersion.orElse(DEFAULT_JVM_VERSION).map { JvmTarget.fromTarget(it.toString()) },
            )
        }
    }
}

private val TRANSLATION_LINTS =
    setOf(
        "MissingTranslation",
        "ExtraTranslation",
        "MissingQuantity",
        "UnusedQuantity",
        "StringFormatMatches",
        "StringFormatCount",
        "UnusedResources",
    )

private const val DEFAULT_JVM_VERSION = 17

/** The extension's `jvmVersion`, when the app set one, over the default the plugin gave `compileOptions`. */
private fun ApplicationExtension.applyJvmVersion(convention: AndroidAppConventionExtension) {
    val version = convention.jvmVersion.orNull ?: return
    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(version)
        targetCompatibility = JavaVersion.toVersion(version)
    }
}

/** The committed debug keystore, from the extension's path or `app/debug.keystore` at the root, when the file is there. */
private fun ApplicationExtension.applyDebugKeystore(
    project: Project,
    convention: AndroidAppConventionExtension,
) {
    val keystore = (convention.debugKeystore.orNull?.asFile ?: project.rootDir.resolve("app/debug.keystore"))
    if (!keystore.exists()) return
    signingConfigs.getByName("debug") {
        storeFile = keystore
        storePassword = "android"
        keyAlias = "androiddebugkey"
        keyPassword = "android"
    }
}

private fun ApplicationExtension.configure(project: Project) {
    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(DEFAULT_JVM_VERSION)
        targetCompatibility = JavaVersion.toVersion(DEFAULT_JVM_VERSION)
    }

    // A locale is complete or it does not exist: the alternative is not English, it is Android's per-string fallback
    // rendering half a screen in each. UnusedResources is pinned too, so a removed call site cannot leave its string and
    // its translations behind with a green build.
    lint { error += TRANSLATION_LINTS }
    // Generates the locale config from the values-<lang> directories present, so Android 13+ offers the app in the
    // per-app language picker and adding a locale is one directory.
    androidResources { generateLocaleConfig = true }
    buildFeatures { buildConfig = true }
    // Robolectric screens built from dimensionResource and stringResource need the merged resources on the unit-test classpath.
    testOptions { unitTests.isIncludeAndroidResources = true }

    // Both from the tag a release workflow builds; a local build keeps the placeholders.
    defaultConfig {
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "0.1.0"
    }

    configureSigning(project)

    buildTypes {
        getByName("debug") {
            // A package of its own, so a debug build installs beside a release one instead of over it: the two are signed
            // with different keys, and replacing one with the other means an uninstall that takes the app's data with it.
            applicationIdSuffix = ".debug"
            // en-XA lengthens and accents every string, ar-XB mirrors the layout: truncation and RTL bugs found with no
            // translation written. Debug only; they must never ship.
            isPseudoLocalesEnabled = true
            // Opt-in (`-PminifyDebug`): the minified debug build a device lane runs, so a keep rule that goes stale fails
            // there rather than on a user. It must stay identical to the release switch below, or the lane stops proving
            // what release ships.
            if (project.hasProperty("minifyDebug")) optimization.enable = true
        }
        getByName("release") {
            // One switch for code shrinking, resource shrinking and the default keep rules.
            optimization.enable = true
        }
    }
}

/**
 * The release keystore is never in the repository: its values come from `keystore.properties` at the root (gitignored) for a
 * local signed build, or from the environment in a release workflow. With none, the release build type gets no signing config at
 * all, so it still builds everywhere and its output is unsigned.
 */
private fun ApplicationExtension.configureSigning(project: Project) {
    val root = project.rootDir
    val keystoreProperties =
        Properties().apply {
            val file = root.resolve("keystore.properties")
            if (file.exists()) file.inputStream().use { load(it) }
        }

    fun signingValue(key: String): String? = keystoreProperties.getProperty(key) ?: System.getenv(key)
    val releaseStoreFile = signingValue("RELEASE_STORE_FILE")

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = root.resolve(releaseStoreFile)
                storePassword = signingValue("RELEASE_STORE_PASSWORD")
                keyAlias = signingValue("RELEASE_KEY_ALIAS")
                keyPassword = signingValue("RELEASE_KEY_PASSWORD")
            }
            buildTypes.getByName("release").signingConfig = signingConfigs.getByName("release")
        }
    }
}
