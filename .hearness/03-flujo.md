# Flujo de trabajo

El ciclo de vida que sigue todo trabajo bajo Hearness. Cinco fases. No todas las tareas
recorren las cinco: el tamaño de la tarea decide cuánto ceremonial aplica (ver *Calibración*
al final).

```
  DISCUTIR ──► PLANEAR ──► EJECUTAR ──► VERIFICAR ──► REGISTRAR
     │            │            │            │             │
  contexto      plan        commits     evidencia       log
  ambigüedad    aprobado    atómicos    de que sirve    + memoria
```

## 1. Discutir
Reunir contexto **antes** de tocar nada. Quién pide qué, para qué, con qué restricciones.
Resolver ambigüedad preguntando (Principio 2). Salida: entendimiento compartido del
objetivo y del criterio de aceptación.

> Si el objetivo no se puede enunciar en una frase, todavía no se planea.

## 2. Planear
El **Arquitecto** propone: pasos, archivos afectados, riesgos, criterio de aceptación.
El humano aprueba (o corrige). Para cambios grandes o irreversibles, este paso es
**obligatorio**. Salida: un plan aprobado.

## 3. Ejecutar
El **Ejecutor** implementa el plan aprobado en **commits atómicos** (uno por unidad lógica,
cada uno con mensaje claro). Se mantiene dentro de su alcance. Si el plan falla en la
práctica, **para y reporta la desviación** — no rediseña por su cuenta.

## 4. Verificar
El **Verificador** confirma contra el criterio de aceptación, con **evidencia real**
(salida de tests, screenshot del navegador, request/response). No vale "debería funcionar".
Si falla: vuelve a Ejecutar con el diagnóstico.

## 5. Registrar
Dejar rastro (Principio 6):
- Entrada de log: `## [YYYY-MM-DD] <fase> | <una línea>`.
- Memoria persistente si hay algo reutilizable para el futuro.
- Índice/docs actualizados si nacieron archivos nuevos.

## Manejo de desviaciones

Cuando la realidad contradice el plan:
1. **Parar.** No seguir ejecutando sobre una premisa rota.
2. **Reportar** qué se esperaba vs. qué se encontró.
3. **Esperar** nueva decisión (replan o ajuste), salvo que el arreglo sea trivial y obvio.

## Calibración por tamaño

| Tamaño | Discutir | Planear | Ejecutar | Verificar | Registrar |
|---|---|---|---|---|---|
| Trivial (typo, constante) | — | — | ✅ | rápido | commit |
| Pequeño (1-2 archivos) | breve | mental | ✅ | ✅ | commit + log |
| Mediano (feature) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Grande / irreversible | ✅ | ✅ **aprobado** | ✅ | ✅ | ✅ |

La regla: **a más riesgo, más ceremonia.** Nunca al revés.
