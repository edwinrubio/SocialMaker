# Convenciones

Cómo se escribe el trabajo para que sea legible por el siguiente agente y por el humano.

## Código

- **Escribe como el código que rodea.** Igual densidad de comentarios, mismos nombres,
  mismo estilo. No impongas un estilo nuevo en un archivo ajeno.
- **Nombres explícitos** sobre abreviaturas ingeniosas. `usuarioActivo` > `ua`.
- **Funciones cortas, un propósito.** Si necesita un comentario que explique "y aquí además",
  probablemente son dos funciones.
- **Sin código muerto.** No dejar bloques comentados "por si acaso". El historial de git es
  el "por si acaso".
- **Errores explícitos.** No tragar excepciones en silencio. Falla ruidoso o maneja
  a propósito.

## Commits

Formato **Conventional Commits**:

```
<tipo>(<ámbito>): <resumen imperativo ≤50 chars>

<cuerpo opcional: el *por qué*, no el *qué*>
```

Tipos: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

- **Atómicos:** un commit = una unidad lógica. No mezclar refactor con feature.
- El cuerpo explica **por qué**, no **qué** (el diff ya dice el qué).
- Nada de `wip`, `arreglos`, `.` como mensaje.

## Documentación

- **Una idea por archivo.** Si un doc crece demasiado, se parte y se enlaza.
- **Enlaza en lugar de repetir.** La verdad vive en un solo lugar; los demás apuntan a él.
- **Frontmatter mínimo** cuando aplique (tipo, fuentes, fecha de actualización).
- **Fechas absolutas.** "hoy" → `2026-07-27`. Nunca relativas en un doc que se archiva.
- Enlaces a archivos con ruta relativa y clicable.

## Nombres de archivo

- `kebab-case` para docs (`flujo-de-trabajo.md`).
- Prefijo numérico cuando el orden importa (`01-principios.md`).
- Nombre = contenido. Un `utils.md` que en realidad son reglas de deploy está mal nombrado.

## Reportes al humano

- Directo. Primero la conclusión, después el detalle.
- Rutas como enlaces clicables `ruta/archivo.md:línea`.
- Comandos para copiar en bloque ```bash```, uno por bloque.
- Si algo falló, se dice con la salida real. Sin maquillaje.
