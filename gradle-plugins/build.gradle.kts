import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    `kotlin-dsl`
}

group = "binge.gates"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

dependencies {
    // binge.gates.detekt applies the detekt plugin itself, so it ships with these plugins.
    implementation(libs.detekt.gradlePlugin)
    // compileOnly: a consumer that uses Kotlin already has it on its build classpath, and one that
    // does not must not be handed it. The detekt gate checks for it before touching its types.
    compileOnly(libs.kotlin.gradlePlugin)
    testImplementation(libs.junit.jupiter.api)
    testRuntimeOnly(libs.junit.jupiter.engine)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.validatePlugins {
    enableStricterValidation = true
    failOnWarning = true
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

gradlePlugin {
    plugins {
        register("translationStaleness") {
            id = "binge.gates.translation-staleness"
            implementationClass = "binge.gates.TranslationStalenessPlugin"
            displayName = "Translation staleness"
            description = "Fails when a translated source string changes without its translations being re-confirmed."
        }
        register("detekt") {
            id = "binge.gates.detekt"
            implementationClass = "binge.gates.DetektGatePlugin"
            displayName = "detekt wiring"
            description = "Applies detekt pinned to production source, with type resolution and an optional baseline."
        }
        register("baselineStaleness") {
            id = "binge.gates.baseline-staleness"
            implementationClass = "binge.gates.BaselineStalenessPlugin"
            displayName = "Baseline staleness"
            description = "Fails when the detekt baseline holds an entry the code no longer produces."
        }
        register("tvMaterialSeparation") {
            id = "binge.gates.tv-material-separation"
            implementationClass = "binge.gates.TvMaterialSeparationPlugin"
            displayName = "tv-material separation"
            description = "Fails when TV source imports Material 3 or phone source imports tv-material."
        }
    }
}
