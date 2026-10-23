# Publicación en tiendas

Todo lo que se pudo preparar sin tus cuentas está aquí. Lo marcado **(tú)** requiere tu sesión o tus datos legales.

## Archivos
| Qué | Dónde |
|---|---|
| Android App Bundle firmado | `build/app/outputs/bundle/release/app-release.aab` (`flutter build appbundle --release`) |
| Archivo iOS | `build/ios/archive/Runner.xcarchive` (`flutter build ipa --release --export-options-plist=ios/store/ExportOptions.plist`) |
| Textos de la ficha (es / en) | `listing.md` |
| Política de privacidad | `privacy-policy.md` (falta tu correo de soporte y publicarla en una URL) |
| Capturas iPhone 6,9" (1320×2868) | `screenshots/ios/` |
| Capturas Android (1080×1920) | `screenshots/android/` |
| Gráfico destacado Play (1024×500) | `feature_graphic.png` |
| Ícono 1024² | `../../assets/brand/icon.png` |

## Clave de subida de Android
- Keystore: `~/.socialmaker/upload-keystore.jks` (alias `upload`), contraseñas en `~/.socialmaker/key.properties` y `android/key.properties` (ignorado por git).
- SHA-256: `1F:A5:B7:09:20:5A:AC:36:61:D1:C8:DC:E9:8C:9C:0E:D6:8D:6E:EF:D4:02:0D:9E:18:41:F5:F8:68:EA:30:89`
- **(tú)** Guárdala en tu gestor de contraseñas y bórrala de `~/.socialmaker` cuando la tengas a salvo. Activa *Play App Signing* (por defecto): Google guarda la clave de la app; esta es solo la de subida y se puede resetear si se pierde.

## Google Play — com.edwinrubio.social_maker
1. **(tú)** Play Console → Crear app: "SocialMaker", app, gratis, idioma es-419.
2. **(tú)** Contenido de la app: política de privacidad (URL), anuncios: no, acceso: sin login, clasificación IARC, público objetivo 13+, **seguridad de los datos: no se recopilan ni comparten datos**, permisos de cámara/micrófono justificados por la función principal.
3. **(tú)** Ficha principal: textos de `listing.md`, ícono 512² (`assets/brand/icon.png` reducido), gráfico destacado, capturas.
4. **(tú)** Producción → Crear versión → subir `app-release.aab` (la primera subida tiene que ser manual en la consola) → Enviar a revisión.
   - Si tu cuenta de desarrollador personal es posterior a nov-2023, Google exige antes una **prueba cerrada con 12 testers durante 14 días**; sin eso el botón de producción no aparece.

## App Store — com.edwinrubio.socialMaker
1. **(tú)** Xcode → Settings → Accounts: inicia sesión con tu Apple ID del equipo 5MJD5LZ348 (ahora Xcode no tiene cuenta y no puede crear el perfil de distribución).
2. **(tú)** App Store Connect → Apps → + Nueva app: iOS, "SocialMaker", es-MX, bundle `com.edwinrubio.socialMaker`, SKU `socialmaker`.
3. Subir el build (puedo hacerlo yo cuando estén 1 y 2):
   `xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive -exportOptionsPlist ios/store/ExportOptions.plist -exportPath build/ios/ipa -allowProvisioningUpdates` con `destination` = `upload`, o Xcode → Organizer → Distribute App.
4. **(tú)** Ficha: textos, capturas, URL de privacidad, URL de soporte, categoría Foto y video, clasificación 4+, **Privacidad de la app: "No se recopilan datos"**, cifrado: ya declarado (`ITSAppUsesNonExemptEncryption = NO`).
5. **(tú)** Elegir el build → Enviar a revisión.

## Para revisión (notas al revisor)
"No requiere cuenta. Graba manteniendo o tocando el botón rojo; toca ✓ para unir. Los subtítulos (iPhone) usan reconocimiento de voz en el dispositivo; no se envían datos a servidores."
