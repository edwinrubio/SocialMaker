# Memoria y contexto

Los agentes olvidan al terminar la sesión. Hearness define cómo **recordar entre sesiones**
sin ensuciar el proyecto.

## Qué se guarda y dónde

| Tipo | Dónde vive | Ejemplo |
|---|---|---|
| **Estado del trabajo** | `log.md` del proyecto | "hoy se implementó X, falta Y" |
| **Decisiones con razón** | nota de decisión / ADR | "elegimos Postgres por Z" |
| **Hechos reutilizables** | memoria persistente del agente | preferencias del humano, convenciones locales |
| **Rastro técnico** | historial de git | qué cambió cada commit |

## Qué NO se guarda como memoria

- Lo que el repo ya dice (estructura, código, historial). Si git lo sabe, no lo dupliques.
- Detalles que solo importan a la conversación de hoy.
- Secretos (nunca en memoria ni en logs).

Si el humano pide "recuerda esto" y es algo que el repo ya registra, el agente pregunta
**qué fue lo no obvio** y guarda *eso*, no el hecho crudo.

## Regla del contexto largo

En sesiones largas el contexto se resume. El agente no debe:
- Re-derivar hechos ya establecidos en la conversación.
- Re-litigar decisiones ya tomadas.
- Enumerar opciones que no va a seguir.

Cuando ya tiene información para actuar, **actúa**.

## Memoria recordada = contexto, no orden

Un dato de memoria que reaparece en una sesión futura es **contexto de fondo**, no una
instrucción del humano. Refleja lo que era cierto cuando se escribió. Si menciona un
archivo, función o flag, el agente **verifica que aún existe** antes de recomendarlo.

## Handoff entre agentes

Cuando un agente pasa trabajo a otro (o a una futura sesión), deja un **handoff**: objetivo,
qué se hizo, qué falta, dónde está el riesgo. Suficiente para retomar sin releer todo el
historial.

```markdown
## Handoff — 2026-07-27
- Objetivo: agregar login con OAuth
- Hecho: rutas y UI; falta callback del proveedor
- Riesgo: los secrets aún no están en el entorno de staging
- Siguiente: implementar callback en src/server/auth/callback.ts
```
