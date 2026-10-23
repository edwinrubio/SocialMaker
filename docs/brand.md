# SocialMaker — marca

## Símbolo
Un anillo partido en **tres fragmentos** alrededor de un **botón de grabar con play**: grabar por partes y unirlas en un video. Degradado rosa → naranja sobre fondo ciruela oscuro.

Fuente única: `tool/brand_icon.swift` (Core Graphics, sin herramientas de diseño). Genera en `assets/brand/`:

| Archivo | Uso |
|---|---|
| `icon.png` | Ícono de app (iOS, Android legacy), opaco 1024² |
| `foreground.png` / `monochrome.png` | Ícono adaptable de Android y ícono temático (Android 13+) |
| `logo.png` | Splash (iOS y Android < 12) |
| `splash_android12.png` | Splash de Android 12+ |

Regenerar:

```sh
swift tool/brand_icon.swift assets/brand
dart run flutter_launcher_icons
dart run flutter_native_splash:create
git checkout ios/Runner.xcodeproj/project.pbxproj ios/Runner/Info.plist  # el generador los toca sin necesidad
```

## Colores (`lib/brand.dart`)

| Token | Hex | Uso |
|---|---|---|
| `Brand.pink` | `#FE2C55` | Acento: grabar, selección, acciones principales |
| `Brand.orange` | `#FF8A3D` | Segundo color del degradado |
| `Brand.night` | `#0C0912` | Splash y fondos |
| `Brand.plum` | `#1A0B17` | Fondo del ícono adaptable |

## Nombre
**SocialMaker**, una palabra, S y M en mayúscula.
