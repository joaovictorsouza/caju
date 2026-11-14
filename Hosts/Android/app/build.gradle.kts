plugins {
    id("com.android.application")
}

android {
    namespace = "dev.caju.host"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.caju.host"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release {
            // Sem assinatura de release ainda (TB-Android só gera o debug).
            isMinifyEnabled = false
        }
    }
}

// O Swift não passa pelo CMake: scripts/build-native.sh compila e liga o host e
// copia libCajuAndroidHost.so + o runtime do Swift para src/main/jniLibs/arm64-v8a.
val buildSwiftHost by tasks.registering(Exec::class) {
    workingDir = rootDir
    commandLine("sh", "scripts/build-native.sh")
    // O Swift SDK for Android exige o NDK r30; ignora um ANDROID_NDK_HOME que não exista.
    val sdk = System.getenv("ANDROID_HOME") ?: "${System.getProperty("user.home")}/Library/Android/sdk"
    val fromEnv = System.getenv("ANDROID_NDK_HOME")?.let(::File)?.takeIf { it.isDirectory }
    val ndk = fromEnv ?: File("$sdk/ndk").listFiles()?.filter { it.name.startsWith("30.") }?.maxOrNull()
    if (ndk != null) environment("ANDROID_NDK_HOME", ndk.absolutePath)
}

tasks.named("preBuild") { dependsOn(buildSwiftHost) }
