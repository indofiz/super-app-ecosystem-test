import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Read signing credentials from android/key.properties (gitignored).
// That file is created per-developer and injected as a CI secret — it is
// NEVER committed. See android/key.properties.example for the format.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "id.go.pangkalpinangkota.smart_app_test"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "id.go.pangkalpinangkota.smart_app_test"
        // 23 keeps flutter_secure_storage on EncryptedSharedPreferences without fallback.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Consumed by flutter_appauth's manifest merge — registers
        // RedirectUriReceiverActivity to capture the deeplink.
        // TODO(C-04): migrate to HTTPS App Links once mobile.pangkalpinangkota.go.id
        // is live and assetlinks.json is published (requires domain + BFF deploy).
        manifestPlaceholders["appAuthRedirectScheme"] = "id.go.pangkalpinangkota.smartapptest"
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias      = keystoreProperties["keyAlias"]      as String
                keyPassword   = keystoreProperties["keyPassword"]   as String
                storeFile     = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use production keystore when key.properties is present.
            // Without it the APK is unsigned — it will fail to install,
            // which is the correct safe-failure for a CI run missing secrets.
            // NEVER fall back to the debug keystore in release.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                null
        }
    }
}

flutter {
    source = "../.."
}
