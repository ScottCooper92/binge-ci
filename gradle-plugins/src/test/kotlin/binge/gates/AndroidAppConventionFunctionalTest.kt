package binge.gates

import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.internal.PluginUnderTestMetadataReading
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

/** Applies `binge.conventions.android-app` next to AGP's application plugin and reads back what it set. */
class AndroidAppConventionFunctionalTest {
    @TempDir
    lateinit var root: File

    private fun write(
        path: String,
        text: String,
    ) {
        File(root, path).apply {
            parentFile.mkdirs()
            writeText(text)
        }
    }

    private fun build(extra: String = "") {
        val sdk =
            checkNotNull(System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")) {
                "This test needs an Android SDK: set ANDROID_HOME."
            }
        write("settings.gradle.kts", "rootProject.name = \"sample\"\n")
        write(
            "build.gradle.kts",
            """
            plugins {
                id("com.android.application")
                id("binge.conventions.android-app")
            }
            repositories {
                maven("https://maven-central.storage-download.googleapis.com/maven2/")
                google()
                mavenCentral()
            }
            android {
                namespace = "sample"
                compileSdk = 37
                defaultConfig {
                    applicationId = "sample.app"
                    minSdk = 26
                }
            }
            $extra
            tasks.register("print") {
                val android = project.extensions.getByType<com.android.build.api.dsl.ApplicationExtension>()
                doLast {
                    println("lint=" + android.lint.error.toSortedSet())
                    println("localeConfig=" + android.androidResources.generateLocaleConfig)
                    println("buildConfig=" + android.buildFeatures.buildConfig)
                    println("unitResources=" + android.testOptions.unitTests.isIncludeAndroidResources)
                    println("java=" + android.compileOptions.sourceCompatibility.majorVersion + "/" + android.compileOptions.targetCompatibility.majorVersion)
                    println("versionName=" + android.defaultConfig.versionName + " versionCode=" + android.defaultConfig.versionCode)
                    val debug = android.buildTypes.getByName("debug")
                    val release = android.buildTypes.getByName("release")
                    println("debugSuffix=" + debug.applicationIdSuffix + " pseudo=" + debug.isPseudoLocalesEnabled + " debugMinify=" + debug.optimization.enable)
                    println("releaseMinify=" + release.optimization.enable + " releaseSigning=" + release.signingConfig?.name)
                    println("debugKeystore=" + android.signingConfigs.getByName("debug").storeFile?.absolutePath?.replace("\\", "/"))
                }
            }
            """.trimIndent(),
        )
        write("local.properties", "sdk.dir=${File(sdk).invariantSeparatorsPath}\n")
        write("gradle.properties", "org.gradle.jvmargs=-Xmx1g -XX:MaxMetaspaceSize=1g\nandroid.useAndroidX=true\n")
        write("src/main/AndroidManifest.xml", "<manifest />\n")
    }

    private fun runner(vararg args: String): GradleRunner =
        GradleRunner
            .create()
            .withProjectDir(root)
            .withPluginClasspath(
                PluginUnderTestMetadataReading.readImplementationClasspath() +
                    System.getProperty("testKitKotlin").split(File.pathSeparator).map(::File) +
                    System.getProperty("testKitAndroid").split(File.pathSeparator).map(::File),
            ).withArguments(*args, "--stacktrace")

    @Test
    fun `an app that applies the convention gets what the apps share`() {
        build()

        val out = runner("print").build().output

        assertTrue(out.contains("MissingTranslation") && out.contains("UnusedResources") && out.contains("StringFormatCount"), out)
        assertTrue(out.contains("localeConfig=true"), out)
        assertTrue(out.contains("buildConfig=true"), out)
        assertTrue(out.contains("unitResources=true"), out)
        assertTrue(out.contains("java=17/17"), out)
        assertTrue(out.contains("versionName=0.1.0 versionCode=1"), out)
        assertTrue(out.contains("debugSuffix=.debug pseudo=true debugMinify=false"), out)
        assertTrue(out.contains("releaseMinify=true releaseSigning=null"), out)
    }

    @Test
    fun `the debug build is minified only when asked, and the committed debug keystore is used when it exists`() {
        build()
        write("app/debug.keystore", "not a real keystore")

        val out = runner("print", "-PminifyDebug").build().output

        assertTrue(out.contains("debugMinify=true"), out)
        assertTrue(out.contains("${root.name}/app/debug.keystore"), out)
    }

    @Test
    fun `without the committed keystore the debug build type keeps AGP's own`() {
        build()

        val out = runner("print").build().output

        assertTrue(!out.contains("${root.name}/app/debug.keystore"), out)
    }

    @Test
    fun `jvmVersion set in the app's own block is the Java target, though the plugin was applied first`() {
        build("androidAppConvention { jvmVersion = 21 }")

        val out = runner("print").build().output

        assertTrue(out.contains("java=21/21"), out)
    }

    @Test
    fun `debugKeystore set in the app's own block moves the debug key`() {
        build("androidAppConvention { debugKeystore = layout.projectDirectory.file(\"keys/other.keystore\") }")
        write("keys/other.keystore", "not a real keystore")
        write("app/debug.keystore", "not a real keystore")

        val out = runner("print").build().output

        assertTrue(out.contains("${root.name}/keys/other.keystore"), out)
    }

    @Test
    fun `release signing comes from keystore properties, and is absent without them`() {
        build()
        write("keystore.properties", "RELEASE_STORE_FILE=release.keystore\nRELEASE_STORE_PASSWORD=p\nRELEASE_KEY_ALIAS=a\nRELEASE_KEY_PASSWORD=k\n")

        val out = runner("print").build().output

        assertTrue(out.contains("releaseSigning=release"), out)
    }
}
