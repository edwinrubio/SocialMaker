# Verificación de entorno (init script)

Todo proyecto instanciado bajo Hearness **debe** incluir un **script de verificación de
entorno**. Su trabajo: confirmar que el software corre bien **antes de empezar a programar**
y **al cerrar la sesión**. Es el "chequeo de salud" del proyecto.

## Por qué es obligatorio

Un agente que empieza a programar sobre un entorno roto pierde tiempo y ensucia el repo con
falsos errores. Un agente que cierra sesión sin verificar puede dejar todo roto para el
siguiente. El init script corta ambos problemas: **verde antes de tocar, verde antes de irse.**

## Qué archivo, según el SO

- **Unix / macOS / Linux:** `init.sh` (bash).
- **Windows:** `init.bat` (o `init.ps1` si el proyecto usa PowerShell).
- Un proyecto multiplataforma incluye **ambos** (`init.sh` + `init.bat`) con los mismos chequeos.

Plantillas listas para copiar: [plantilla-init.sh](plantilla-init.sh) y
[plantilla-init.bat](plantilla-init.bat).

## Cuándo se corre

| Momento | Pregunta que responde | Si falla |
|---|---|---|
| **Antes de programar** (`init.sh check`) | ¿Puedo empezar sobre base sana? | No se programa. Se arregla el entorno primero. |
| **Al cerrar sesión** (`init.sh check`) | ¿Dejo todo tan sano como lo encontré? | No se cierra "hecho". Se reporta qué quedó roto. |

Es el **primer** y el **último** comando de una sesión de trabajo.

## Qué debe chequear (mínimo)

El script verifica **presencia y salud**, nunca valores de secretos:

1. **Herramientas de runtime** presentes y en versión correcta (node, python, etc.).
2. **Dependencias instaladas** (node_modules, venv, paquetes).
3. **Config/env presentes** — que la variable *exista*, no imprimir su valor.
4. **Servicios alcanzables** — base de datos, API, cache responden.
5. **El proyecto compila** — typecheck / build sin errores.
6. **Smoke test** — el arranque mínimo funciona.

## Contrato de salida

- **Exit code `0`** = todo verde. El agente puede empezar / cerrar tranquilo.
- **Exit code `≠0`** = algo falla. El agente **para** y reporta qué chequeo falló, con la
  salida real (Principio 7).
- Salida legible: una línea por chequeo, `✅`/`❌`, y un resumen final.

## Reglas duras

- 🚫 **El script no imprime secretos.** Verifica que existan, no los muestra.
- 🚫 **El script no arregla solo** cosas peligrosas (no corre migraciones, no instala deps
  pesadas) sin permiso. Chequea y reporta; el arreglo sigue el flujo normal (base/04).
- ✅ Es **idempotente y de solo lectura** por defecto: correrlo mil veces no cambia nada.
- El `AGENTS.md` del proyecto declara la **ruta del script** y **qué chequea** (ver
  plantilla-AGENTS.md §9).
