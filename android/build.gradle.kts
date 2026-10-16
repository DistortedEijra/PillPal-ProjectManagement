plugins {
  // ...

}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
    // Force all subprojects to use compileSdk 36
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library")) {
            project.extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
                compileSdk = 36
                defaultConfig.targetSdk = 36
            }
        }
    }
}

// Redirect build outputs to Flutter's expected build directory.
// file("../build") resolves relative to android/ → AppDev-main2/build, which is
// where Flutter tools look for the APK. Using projectDir-relative path means
// android/build/ is never created, so Gradle 8.x no longer complains about it.
val flutterBuildDir: File = file("../build")
rootProject.layout.buildDirectory.set(flutterBuildDir)

subprojects {
    layout.buildDirectory.set(File(flutterBuildDir, project.name))
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
