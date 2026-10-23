> **Nota SocialMaker (2026-10-23):** en este proyecto el gate de seguridad con mcp-sentinel
> está **desactivado por decisión del humano**. Ver [AGENTS.md §8](../AGENTS.md). El resto de
> este documento (skills.json + bootstrap) sí aplica.

# Skills del proyecto (skills.json + bootstrap + verificación)

Todo proyecto instanciado bajo Hearness declara las **skills** (plugins de agente) que
necesita en un archivo **`skills.json`**, y trae un **bootstrap** que las instala en
**cualquier ambiente** (otra máquina, CI, un compañero) sin depender de lo que ya esté
instalado localmente. Ninguna skill se **usa** hasta pasar el **escaneo de seguridad**.

Dos objetivos:
1. **Portabilidad** — el proyecto sabe qué skills usa y las instala solo, sea el ambiente que sea.
2. **Seguridad** — cada skill se escanea contra vulnerabilidades y **filtración de datos**
   antes de correr. Gate **bloqueante**.

## Base recomendada de Hearness

Skills que se instalan por defecto en un proyecto nuevo (ajustables en `skills.json`):

| Skill | Para qué | `aplica_si` |
|---|---|---|
| **GSD suite** (`gsd-*`) | Metodología planear→ejecutar→verificar; calza con el flujo de Hearness | siempre |
| **graphify** | Grafo de conocimiento del codebase | siempre |
| **mcp-sentinel** | 🔒 Escáner de seguridad de skills/MCPs (vulns + exfiltración de datos) | siempre — **obligatoria** |
| **frontend-design** | Calidad de UI | proyectos con frontend |
| gopls-lsp | LSP de Go | proyectos Go |
| security-guidance | Guía de código seguro | opcional |

`mcp-sentinel` no es negociable: es la herramienta que hace cumplir el gate de seguridad.

## `skills.json` — esquema

```jsonc
{
  "proyecto": "NombreProyecto",
  "esquema": 1,
  "actualizado": "YYYY-MM-DD",
  "seguridad": {
    "modo": "bloqueante",          // bloqueante | advertencia
    "escaner": "mcp-sentinel",
    "revalidar_dias": 30           // re-escanear si el último scan es más viejo
  },
  "skills": [
    {
      "nombre": "graphify",
      "fuente": "marketplace | skills-dir | git",  // de dónde se instala
      "marketplace": "nombre-o-null",   // si fuente=marketplace
      "repo": "usuario/repo-o-null",    // fuente de verdad para reinstalar en otro ambiente
      "plugin_id": "graphify@skills-dir",
      "commit": "sha-o-null",           // pin: evita drift de supply-chain
      "aplica_si": "siempre | frontend | go | ...",
      "requerido": true,
      "por_que": "Para qué la usa este proyecto.",
      "verificado": null,               // fecha del último scan LIMPIO (mcp-sentinel)
      "scan": null                      // "limpio" | "hallazgos: <resumen>"
    }
  ]
}
```

Plantilla lista (con la base recomendada precargada): [plantilla-skills.json](plantilla-skills.json).

## Bootstrap — instalar en cualquier ambiente

El script [bootstrap-skills.sh](bootstrap-skills.sh) lee `skills.json` y, para cada skill que
`aplica`:

1. Si su `marketplace`/`repo` no está registrado → `claude plugin marketplace add <fuente>`.
2. Si la skill no está instalada (`claude plugin list`) → `claude plugin install <plugin_id>`.
3. Verifica el **pin** (`commit`): si el sha instalado no coincide con el declarado → alerta
   (posible cambio no revisado en la cadena de suministro).

> El bootstrap **instala**; no marca nada como seguro. Eso lo hace el escaneo (abajo).

## Verificación de seguridad — gate bloqueante

`modo: "bloqueante"` (config del proyecto). Regla:

> **Ninguna skill se usa hasta que `mcp-sentinel` la escanea y el resultado es limpio.**

Flujo:
1. El agente corre **mcp-sentinel** sobre las skills instaladas (escanea vulns conocidas,
   exfiltración de credenciales/datos, dominios maliciosos, comandos peligrosos).
2. Por cada skill limpia: escribe `verificado: <hoy>` y `scan: "limpio"` en `skills.json`.
3. Si hay **hallazgos**: `scan: "hallazgos: ..."`, la skill **queda bloqueada**, se reporta
   al humano y **no se usa** (Principio 1 + guardrails base/04). No se "desbloquea" sola.
4. Se re-escanea si el último `verificado` supera `revalidar_dias` (drift / actualización).

Este gate se **engancha al init script**: [init.sh](../base/07-verificacion-entorno.md)
falla (exit ≠0) si alguna skill `requerida` tiene `verificado: null` o vencido. Así, "empezar
a programar" es imposible sobre skills sin verificar.

## Reglas duras

- 🚫 Una skill con `scan` de hallazgos **no se usa** aunque sea cómoda. Se reporta y se espera decisión.
- 🚫 El bootstrap no instala nada fuera de lo declarado en `skills.json`.
- 🔒 Pinnear por `commit` las skills sensibles: una actualización silenciosa es un vector de ataque.
- Todo cambio de estado (`verificado`/`scan`) actualiza `actualizado`.
- Nunca poner tokens ni secretos en `skills.json` (es versionado).

## Consulta rápida

```bash
# skills que aplican y NO están verificadas (bloquean el arranque)
jq '.skills[] | select(.requerido and (.verificado==null)) | .nombre' skills.json
# skills con hallazgos de seguridad
jq '.skills[] | select(.scan!=null and (.scan|startswith("hallazgos"))) | {nombre,scan}' skills.json
```
