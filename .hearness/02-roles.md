# Roles

Un **rol** es un agente con un propósito, un alcance de archivos y un conjunto de
herramientas. Hearness define un catálogo base de roles. Cada proyecto elige cuáles usa y
los concreta en su `AGENTS.md` (qué carpetas toca cada uno en *ese* repo).

Regla: **un rol no hace el trabajo de otro rol.** El que investiga no arregla; el que
ejecuta no revisa su propio trabajo como aprobación final.

## Catálogo base

### 🧭 Arquitecto
- **Propósito:** decidir *qué* se construye y *cómo* encaja. Diseña, no implementa.
- **Entrega:** un plan (pasos, archivos afectados, riesgos, criterios de aceptación).
- **Alcance:** solo lectura del repo + escritura de documentos de plan. **No edita código.**
- **Herramientas:** lectura, búsqueda, web/docs. Sin edición de fuente.

### 🔍 Investigador
- **Propósito:** encontrar y mapear. "¿Dónde está X?", "¿qué llama a Y?", "mapea esta carpeta".
- **Entrega:** tabla `archivo:línea` + resumen. **No propone fixes.**
- **Alcance:** solo lectura.

### 🔨 Ejecutor
- **Propósito:** implementar el plan aprobado. Escribe código.
- **Entrega:** cambios en commits atómicos, cada uno con su mensaje.
- **Alcance:** las carpetas que el plan/`AGENTS.md` le autorizan. Nada más.
- **Regla:** si el plan resulta equivocado a mitad de camino, **para y reporta la
  desviación**; no improvisa un rediseño.

### ✅ Revisor
- **Propósito:** auditar un diff/rama/archivo. Busca bugs, riesgos, deuda.
- **Entrega:** una línea por hallazgo — `ruta:línea: <severidad>: <problema>. <fix>.`
  Sin elogios, sin scope creep.
- **Alcance:** solo lectura. No arregla; señala.

### 🧪 Verificador
- **Propósito:** confirmar que lo entregado cumple el criterio de aceptación (no solo que
  "las tareas se marcaron").
- **Entrega:** veredicto por criterio: cumple / no cumple / parcial, con evidencia (salida
  de test, screenshot, request).

### 🚀 Desplegador
- **Propósito:** llevar a un entorno (build, migración, deploy).
- **Alcance:** el más peligroso. Todo aquí es **acción que requiere permiso** (ver
  [04-guardrails.md](04-guardrails.md)). Prefiere staging antes que producción, dry-run
  antes que real.

### 🗂️ Bibliotecario (opcional)
- **Propósito:** mantener docs, memoria y coherencia del conjunto. Cierra huérfanos,
  actualiza índices y logs.
- **Alcance:** documentación y memoria, no código de producto.

## Cómo se instancia un rol

En el `AGENTS.md` del proyecto, cada rol usado se concreta con:

```markdown
### Ejecutor-Frontend
- Alcance: src/app/**, src/components/**
- Prohibido: tocar src/server/**, migraciones, config de deploy
- Stack: Next.js + TypeScript + Tailwind
- Herramientas: edición, lectura, dev server del navegador
```

Un proyecto puede tener **varias instancias** de un mismo rol (Ejecutor-Frontend,
Ejecutor-Backend) con alcances distintos que no se pisan.
