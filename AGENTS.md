# AGENTS.md — SocialMaker

> Todo agente que trabaje en este repo **lee este archivo primero**.
> Las reglas universales están en Hearness: [`.hearness/`](.hearness/) → empieza por
> `.hearness/01-principios.md`. Este archivo solo define lo específico del proyecto.
> **Ante conflicto, Hearness gana** (salvo la desviación declarada en §8).

## 1. Qué es el proyecto

App móvil (Android + iOS) para grabar videos estilo TikTok: se graba **mientras se mantiene
presionado** el botón, cada presión crea un **fragmento**, y el usuario decide qué fragmentos
quedan y cuáles se borran antes de exportar. Incluye un filtro de **reemplazo de fondo**
(segmentación de persona) con una foto o un video.

## 2. Stack

- **App:** Flutter (Dart) — [`lib/`](lib/).
- **Plugin nativo local:** [`packages/bg_camera/`](packages/bg_camera/) — cámara, segmentación,
  composición y codificación en nativo.
  - **iOS (Swift):** AVFoundation + Vision (`VNGeneratePersonSegmentationRequest`) + Core Image.
    Mínimo iOS 15.0.
  - **Android (Kotlin):** CameraX + MediaPipe Tasks `ImageSegmenter` + OpenGL ES + MediaCodec /
    Media3 Transformer. minSdk 24.
- **Base de datos / backend:** ninguno (todo local en el dispositivo).
- **Deploy:** ninguno por ahora (builds locales a dispositivo).

## 3. Idioma

Código, identificadores y comentarios en **inglés**. Commits en **inglés** (Conventional
Commits). Docs de Hearness, planes y comunicación con el humano en **español**.

## 4. Agentes de este proyecto

| Agente | Rol base | Alcance (puede tocar) | Prohibido |
|---|---|---|---|
| Arquitecto | Arquitecto | solo lectura + `docs/planes/**` | editar código |
| Ejecutor-Flutter | Ejecutor | `lib/**`, `test/**`, `packages/bg_camera/lib/**`, `pubspec.yaml` | código nativo, firma |
| Ejecutor-iOS | Ejecutor | `ios/**`, `packages/bg_camera/ios/**` | `android/**`, bundle id, signing team |
| Ejecutor-Android | Ejecutor | `android/**`, `packages/bg_camera/android/**` | `ios/**`, applicationId, keystores |
| Revisor | Revisor | solo lectura | arreglar; solo señala |
| Verificador | Verificador | solo lectura + correr app/tests | marcar `hecha` sin evidencia |

## 5. Guardrails locales (además de base/04)

- No cambiar bundle id iOS (`com.edwinrubio.socialMaker`) / applicationId Android
  (`com.edwinrubio.social_maker`) ni configuración de
  firma (Team, keystores, provisioning) sin aprobación.
- No subir builds a App Store / Play Store ni TestFlight.
- No agregar dependencias con licencia **GPL** (por eso no se usa ffmpeg-kit GPL).
- No mandar video/audio del usuario a ningún servicio remoto: todo el procesamiento es local.

## 6. Flujo

Se sigue el flujo estándar de Hearness ([03-flujo.md](.hearness/03-flujo.md)).
Extras del proyecto:

- Las features con cámara se verifican en **dispositivo físico** (el simulador iOS no tiene
  cámara). La evidencia va en `log.md`.
- Implementar iOS primero y Android después en cada feature nativa.

## 7. Comandos clave

```bash
flutter pub get
flutter run                 # requiere dispositivo conectado
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --no-codesign
```

## 8. Skills

Sigue [09-skills.md](.hearness/09-skills.md) **con una desviación**: el gate de seguridad con
mcp-sentinel está **desactivado por decisión del humano** (2026-10-23). Por eso `skills.json`
lleva `seguridad.modo: "desactivado"` y `init.sh` no chequea el gate de skills.

- Skills declaradas en [`skills.json`](skills.json): GSD, graphify, frontend-design.
- Se instalan con `./bootstrap-skills.sh` (`AMBIENTE=frontend` para incluir frontend-design).

## 9. Verificación de entorno (obligatorio)

Sigue [07-verificacion-entorno.md](.hearness/07-verificacion-entorno.md).

- **Script:** `./init.sh` (macOS/Linux) · `init.bat` (Windows).
- **Qué chequea:** flutter y dart, Xcode + CocoaPods (solo macOS), adb + java, dependencias
  (`.dart_tool`), `flutter analyze` y `flutter test`.
- **Contrato:** exit 0 = verde; exit ≠0 = el agente para y reporta el chequeo que falló.
- Primer y último comando de toda sesión.

## 10. Registro y estado

- **Estado de features:** [`features.json`](features.json). Sigue
  [08-features.md](.hearness/08-features.md).
- Log del proyecto: [`log.md`](log.md) — formato `## [YYYY-MM-DD] <fase> | <línea>`.
- Planes y decisiones: [`docs/planes/`](docs/planes/).
