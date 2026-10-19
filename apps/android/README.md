# Nook for Android

Not yet implemented. This directory is reserved for the Android companion and app.

- **Planned architecture:** Kotlin with Jetpack Compose for the UI layer, sharing the portable Swift core (`packages/core`) or Companion protocol (`packages/protocol`).
- **Build & CI:** Will use a Gradle project (`settings.gradle.kts`) and a dedicated CI workflow filtered on `apps/android/**`.
