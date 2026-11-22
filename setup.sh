#!/usr/bin/env bash
# Prépare le projet Flutter : génère les fichiers de plateforme manquants, puis applique
# les réglages nécessaires (Android minSdk + Play Integrity, permissions iOS).
# À lancer une fois, depuis le dossier pointeuse-mobile :  ./setup.sh
set -euo pipefail
cd "$(dirname "$0")/app"

command -v flutter >/dev/null || { echo "Flutter n'est pas installé : https://docs.flutter.dev/get-started/install"; exit 1; }

echo "→ Génération des fichiers Android et iOS (les fichiers existants sont conservés)"
flutter create --org com.pointeuse --project-name pointeuse --platforms android,ios .
rm -f test/widget_test.dart

echo "→ Android : minSdk 26 et bibliothèque Play Integrity"
if [ -f android/app/build.gradle.kts ]; then
  G=android/app/build.gradle.kts
  sed -i.bak 's/minSdk = flutter.minSdkVersion/minSdk = 26/' "$G"
  grep -q "play:integrity" "$G" || printf '\ndependencies {\n    implementation("com.google.android.play:integrity:1.4.0")\n}\n' >> "$G"
else
  G=android/app/build.gradle
  sed -i.bak -e 's/minSdkVersion flutter.minSdkVersion/minSdkVersion 26/' -e 's/minSdk = flutter.minSdkVersion/minSdk = 26/' "$G"
  grep -q "play:integrity" "$G" || printf "\ndependencies {\n    implementation 'com.google.android.play:integrity:1.4.0'\n}\n" >> "$G"
fi
rm -f "$G.bak"

if [[ "${OSTYPE:-}" == darwin* ]]; then
  echo "→ iOS : permissions caméra et localisation, iOS 15.5 minimum (ML Kit)"
  P=ios/Runner/Info.plist
  PB=/usr/libexec/PlistBuddy
  $PB -c "Add :NSCameraUsageDescription string La caméra vérifie votre visage au moment du pointage." "$P" 2>/dev/null || true
  $PB -c "Add :NSLocationWhenInUseUsageDescription string Votre position est enregistrée uniquement au moment du pointage, pour confirmer votre présence sur le site client." "$P" 2>/dev/null || true
  if [ -f ios/Podfile ]; then
    sed -i '' -e "s/^# platform :ios, .*/platform :ios, '15.5'/" -e "s/^platform :ios, .*/platform :ios, '15.5'/" ios/Podfile
  fi
else
  echo "→ iOS : à faire sur un Mac (voir README, section iOS)"
fi

echo "→ Téléchargement des dépendances"
flutter pub get

[ -f config.json ] || cp config.example.json config.json
echo
echo "Terminé. Renseignez app/config.json, puis :"
echo "  cd app && flutter run --dart-define-from-file=config.json"
