plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
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

        // Consumed by flutter_appauth's manifest merge — matches the deeplink
        // <data android:scheme="..."> entry in AndroidManifest.xml.
        manifestPlaceholders["appAuthRedirectScheme"] = "id.go.pangkalpinangkota.smartapptest"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
