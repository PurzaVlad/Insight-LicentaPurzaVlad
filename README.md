# Purza Vlad - Insight - Licență

## Repository

Adresa repository-ului:

**https://github.com/PurzaVlad/Insight-LicentaPurzaVlad/**

## Cerințe preliminare

- macOS cu Xcode instalat
- Node.js și npm
- Ruby + Bundler (pentru CocoaPods)
- CocoaPods

## Pași de compilare a aplicației

1. Clonează repository-ul:
   ```sh
   git clone https://github.com/PurzaVlad/Insight-LicentaPurzaVlad.git
   cd Insight-LicentaPurzaVlad
   ```

2. Instalează dependențele JavaScript:
   ```sh
   npm install
   ```

3. Instalează dependențele Ruby (CocoaPods):
   ```sh
   bundle install
   ```

4. Instalează pod-urile native (CocoaPods):
   ```sh
   bundle exec pod install
   ```

## Pași de instalare și lansare a aplicației

1. Pornește Metro bundler-ul (într-un terminal, din rădăcina proiectului):
   ```sh
   npm start
   ```

2. Într-un terminal separat, build & rulare pe simulator iOS:
   ```sh
   npm run ios
   ```

3. Alternativ, pentru rulare/debug direct din Xcode:
   - Deschide **`ios/Insight.xcworkspace`** (nu fișierul `.xcodeproj`)
   - Selectează scheme-ul `Insight` și simulatorul **iPhone 17 Pro**
   - Build & Run (⌘R)

4. La prima lansare, aplicația inițializează modelul LLM local (via `llama.rn`); acest pas poate dura câteva secunde suplimentare.
