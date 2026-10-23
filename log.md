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
## [2026-10-23] ejecutar | Límite de grabación 10 min. Tocar fragmento = seleccionar; ⌫ borra el seleccionado (o el último).
## [2026-10-23] verificar | iOS simulador (iPhone 17 Pro, iOS 26.5) con cámara simulada (video en loop, solo simulador): integration_test pasa — 3 fragmentos, seleccionar/borrar #2, unir, video final se reproduce. Corregido: export iOS fallaba con pista de audio vacía. Fondo en iOS no probable en simulador (Vision no trae el modelo ahí).
## [2026-10-23] verificar | integration_test también pasa en emulador Android (sin paso de fondo; fondo Android ya verificado a mano).
## [2026-10-23] ejecutar | v2: zoom deslizando hacia arriba, Configuración (720p/1080p/4K), Filtros → Desenfocar, Android cámara por GPU (SurfaceTexture OES)
## [2026-10-23] ejecutar | v2 iOS: subtítulos con IA de Apple (SpeechAnalyzer, fallback SFSpeechRecognizer), editor por frase, compartir (TikTok/Instagram/Shorts/Más)
## [2026-10-23] verificar | Simulador iOS: integration_test pasa a 1080p; subtítulos quemados visibles en sus tiempos. Corregido: crash SIGTRAP de AVVideoCompositionCoreAnimationTool (ahora Core Image) y audio faltante de la cámara simulada (solo simulador).
## [2026-10-23] ejecutar | Grabar con un toque (toque inicia, toque para); mantener presionado + zoom sigue igual. Widget tests + integration_test iOS verdes.
## [2026-10-23] ejecutar | Desenfoque: máscara sin rastro (VNImageRequestHandler por frame en vez de VNSequenceRequestHandler) + borde erosionado/suavizado; nivel de desenfoque ajustable (slider en Filtros, guardado). Instalado en iPhone; pendiente validación del usuario.
