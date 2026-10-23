# Registro de features (features.json)

Todo proyecto instanciado bajo Hearness **debe** mantener un archivo **`features.json`** en
su raíz: el registro legible por máquina de **todas las features del proyecto y el estado de
cada una** (hecha, en progreso, fallando, bloqueada…).

## Por qué JSON y no un doc

- Un agente lo lee y actualiza **sin ambigüedad** (no parsea prosa).
- Se consulta rápido: "¿qué está fallando?", "¿qué falta?", "¿qué está bloqueado?".
- Es la **fuente de verdad del avance**. El `log.md` cuenta *qué pasó*; `features.json`
  dice *dónde está cada cosa ahora*.

## Ubicación

- Raíz del proyecto: `./features.json`.
- El `AGENTS.md` lo declara como fuente de verdad del estado (plantilla-AGENTS §9).

## Estados (enum fijo)

| estado | Significa | Quién lo pone |
|---|---|---|
| `pendiente` | Planeada, no empezada | Arquitecto |
| `en-progreso` | Ejecutándose ahora | Ejecutor |
| `en-revision` | Implementada, esperando Revisor/Verificador | Ejecutor |
| `hecha` | Verificada **con evidencia** | Verificador |
| `fallando` | Implementada pero rompe (test rojo / bug) | Verificador o Revisor |
| `bloqueada` | No avanza por dependencia externa | cualquiera, con `bloqueo` |

Regla: una feature solo pasa a `hecha` cuando hay evidencia real (Principio 7). Nunca por
"debería funcionar".

## Esquema

```jsonc
{
  "proyecto": "NombreProyecto",
  "esquema": 1,                       // versión del formato Hearness
  "actualizado": "YYYY-MM-DD",        // fecha absoluta de última edición
  "features": [
    {
      "id": "kebab-case-unico",       // estable, no cambia
      "nombre": "Título legible",
      "descripcion": "Qué hace y para quién.",
      "estado": "pendiente | en-progreso | en-revision | hecha | fallando | bloqueada",
      "responsable": "NombreAgente",  // qué agente la lleva (ver AGENTS.md)
      "criterio": "Cómo se sabe que está hecha (criterio de aceptación).",
      "bloqueo": null,                // texto si estado=bloqueada/fallando; si no, null
      "actualizado": "YYYY-MM-DD"
    }
  ]
}
```

Plantilla lista: [plantilla-features.json](plantilla-features.json).

## Reglas de mantenimiento

- **Se actualiza en la fase Registrar** del flujo ([base/03-flujo.md](03-flujo.md)), no al final del proyecto.
- El `id` es **estable**: una vez creado no cambia (los enlaces y el historial dependen de él).
- Cada cambio de estado actualiza también `actualizado` de esa feature y del archivo.
- Si una feature `fallando` o `bloqueada`, el campo `bloqueo` **explica por qué** en una frase.
- 🚫 No borrar features "hechas" para acortar el archivo: son el historial de alcance. Si algo
  se descarta, marcarlo (`estado` que el proyecto defina, p. ej. `descartada`) — no eliminarlo
  sin confirmación del humano.
- 🚫 Nunca meter secretos ni datos personales en `features.json`.

## Consulta rápida (ejemplos)

```bash
# qué está fallando
jq '.features[] | select(.estado=="fallando") | .nombre' features.json
# qué falta por hacer
jq '.features[] | select(.estado=="pendiente" or .estado=="en-progreso") | .id' features.json
# conteo por estado
jq -r '.features[].estado' features.json | sort | uniq -c
```
