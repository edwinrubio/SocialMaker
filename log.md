# Log — SocialMaker

## [2026-10-23] planear | Plan aprobado: Flutter + plugin nativo bg_camera, Hearness sin mcp-sentinel
## [2026-10-23] ejecutar | Flutter SDK reparado (3.19.5 x86 → 3.47.7 arm64), scaffold app + plugin, Hearness instanciado
## [2026-10-23] verificar | entorno-hearness hecha: ./init.sh exit 0 (analyze + test verdes)
## [2026-10-23] ejecutar | Plugin bg_camera: iOS (AVFoundation + Vision + Core Image) y Android (CameraX + MediaPipe + GLES + MediaCodec + Media3)
## [2026-10-23] ejecutar | App Flutter: grabación mantener-presionado, barra de fragmentos, revisión/borrado, export y guardado en galería, selector de fondo
## [2026-10-23] verificar | analyze limpio, 9 tests verdes (6 app + 3 plugin), `flutter build ios --no-codesign` y `flutter build apk --debug` OK. Pendiente: prueba en dispositivo físico
## [2026-10-23] verificar | Licencias Android aceptadas (doctor ✓). iOS firma automática con Team 5MJD5LZ348 (mismo que Duelig)
## [2026-10-23] verificar | Emulador Android (webcam): ANR al grabar, fragmentos de ~0 s, lag (fence wait 3 s en hilo principal), filtro roto (MediaPipe GL + R8) y merge estirado. Todos corregidos y verificados.
## [2026-10-23] ejecutar | UI tipo TikTok: miniaturas de fragmentos bajo el preview (ver/borrar en cualquier momento), ✓ une directo, botón Filtros con categoría Fondos.
## [2026-10-23] verificar | Android: foto y video de fondo OK en preview y en video exportado; merge 2 fragmentos = suma exacta de frames. iOS simulador: crash al fallar config de AVCaptureSession corregido.
