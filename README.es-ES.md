

<p align="center">
  <img src="docs/copilotmeter.png" alt="CopilotMeter logo" width="200">
</p>

<h1 align="center">CopilotMeter</h1>

Una pequeña aplicación nativa para la barra de menús de macOS que rastrea **cuánto estás usando realmente GitHub Copilot** — desglose de hoy / 7 días / 30 días, tasa de aciertos en caché, división por modelo y una estimación de costo en USD, todo de un vistazo.

<p align="center">
  <img src="docs/overview.png" alt="CopilotMeter popover" width="420">
</p>

Funciona con cualquier plan de Copilot, pero es **especialmente valioso para usuarios de GitHub Copilot Enterprise**: tu asiento es "Unlimited", el panel oficial en <https://github.com/settings/billing/usage> informa 0 % para siempre y no hay una API para los datos de tokens por turno. CopilotMeter analiza los mismos archivos locales que escribe Copilot de todos modos y te proporciona un número real.

Los usuarios de Pro / Pro+ / Business también obtienen un desglose más claro y siempre visible que el panel web, sin salir de la barra de menús.

## Privacidad y seguridad

- **Sin inicio de sesión.** No solicita credenciales de GitHub, token OAuth ni ninguna clave de API. Literalmente no hay ningún flujo de autenticación.
- **Solo dos puntos finales de red, ambos pasivos:**
  - SSH a los *hosts que marques marques* en la ventana emergente (para rastrear tus propias máquinas de desarrollo remotas, desactivado por defecto).
  - `api.github.com` una vez por semana para verificar `releases/latest` de una nueva versión (sin autenticación, sin payload, sin encabezados identificativos; desactiva con `defaults write dev.local.CopilotMeter disableUpdateChecks 1`).
- **Sin telemetría, ni informadores de fallos, ni SDKs de terceros.** Binario Swift único, compatible con sandbox.
- **Solo lee el estado de sesión de Copilot escrito localmente.** Específicamente:
  - `~/.copilot/session-state/<sid>/events.jsonl` — para resúmenes de tokens de CLI / Agente
  - `~/Library/Application Support/Code/User/{globalStorage,workspaceStorage}/.../github.copilot-chat/...` — para detectar sesiones de Chat que no exponen datos locales de Créditos de IA (el texto de los prompts **nunca** se carga en la memoria de la aplicación — véase `VSCodeChatTranscriptsReader.swift` / `VSCodeChatReader.swift`)
- **Nada se sube.** Toda la agregación ocurre en tu Mac y se almacena en `~/Library/Application Support/CopilotMeter/cache.db`. Desinstala eliminando ese directorio + `/Applications/CopilotMeter.app`; no quedan residuos en otro lugar.

Código abierto bajo MIT, así que siéntete libre de auditar los ~1,2 MB de Swift antes de instalarlo.

## Ligero por diseño

| | Tamaño |
|---|---|
| Descarga `.dmg` | ~ 900 KB |
| Paquete `.app` instalado | 1,6 MB |
| Binario nativo arm64 | 1,2 MB |
| Memoria residente mientras se ejecuta | ~ 45 MB |
| CPU en reposo | 0 % |
| Actualización local | cada 60 s (analiza solo el nuevo final de cada `events.jsonl` / transcripción) |
| Actualización remota | cada 1 h (incremental; 1 normalmente < 1 KB de tráfico SSH por host después de la primera sincronización) |

Sin demonios en segundo plano, sin herramientas auxiliares. Toda la aplicación es un solo binario Swift enlazado con frameworks del sistema (sin Electron, sin entorno de Node/Python integrado — el pequeño extractor de Python que incluimos solo se canaliza a través de SSH a hosts remotos, nunca se ejecuta localmente).

## 📣 Novedades

- **v0.1.31** — **Incorporar el uso de sesiones en curso (siempre activas) en el día de hoy.** Los Créditos de IA solo se escriben en disco al ejecutar `session.shutdown`, por lo que una sesión de CLI de Copilot mantenida abierta durante días (p. ej., en tmux) acumulaba mensajes todo el día pero mostraba ~0 créditos para ese día hasta su próximo cierre. El agregador ahora suprime la estimación por mensaje solo hasta el último cierre autorizado de la sesión/modelo; los mensajes posteriores (el trabajo en curso de hoy) se estiman y atribuyen a su propio día. La estimación se calibra a partir de la relación histórica de Créditos de IA por token de salida de la propia sesión (acotada para evitar valores irreales) en lugar de un precio solo de tokens de salida, por lo que la magnitud es realista en lugar de una subestimación de ~6×. Los días históricos completamente cubiertos por cierres permanecen sin cambios y no hay doble conteo una vez que llega un cierre real.

- **v0.1.30** — **Eliminar heurística poco fiable de Cloud Agent; clasificar el uso de session-state como CLI.** Las sesiones en `~/.copilot/session-state` de una máquina fueron ejecutadas por un proceso `copilot` en esa máquina, por lo que corresponden al uso de CLI de terminal (o agente de VS Code si está registrado en la base de datos de chat de VS Code). La antigua regla `hostType=github` → Cloud Agent solo reflejaba un contexto de git-worktree de agente, no un envío a la nube, y provocaba que las sesiones grandes impulsadas por terminal se etiquetaran erróneamente como Cloud Agent y alternaran entre sincronizaciones. La clasificación ahora es estable e independiente del tiempo: agente de VS Code (fija) o CLI. Una migración única reclasifica las filas existentes de Cloud Agent como CLI. Las sesiones de agente enviadas genuinamente a la nube nunca escriben en el estado de sesión local, por lo que la etiqueta Cloud Agent se reserva para una ruta de importación explícita de origen en la nube futura.

- **v0.1.29** — **Detener la alternancia de origen CLI/Cloud-Agent/VS-Code.** Las sesiones reanudadas en terminal seguían volviendo a VS Code Agent / Cloud Agent en sincronizaciones incrementales porque el marcador `session.resume` estaba antes del desplazamiento de bytes y no se volvía a leer. La señal de reanudación ahora se persiste en una tabla fija `session_resume`, y la búsqueda de sesiones de VS Code excluye filas con `agent_name = copilotcli` (la CLI de terminal también se registra allí). Un reescaneo único reclasifica los datos existentes. Efecto neto: una sesión grande impulsada por terminal ya no se cuenta como Cloud Agent o VS Code Agent.

- **v0.1.28** — **Clasificar sesiones reanudadas en terminal como CLI.** Las sesiones que se originaron en un entorno de agente alojado en GitHub pero que luego se continuaron con `copilot --resume` en una terminal ahora se atribuyen a **Copilot CLI**, incluso cuando su `session.start.context.hostType` original es `github` o el id de sesión también aparece en la base de datos de VS Code. Esto mantiene la división de origen alineada con cómo se ejecutó el trabajo localmente.

- **v0.1.27** — **Solo Créditos de IA.** Se eliminó la columna de facturación legacy de GitHub basada en facturas/peticiones y todas las estadísticas visibles de recuento de peticiones. CopilotMeter ahora presenta el uso estrictamente en Créditos de IA de GitHub más el equivalente en USD, manteniendo los detalles de tokens/caché solo donde explican el costo de los Créditos de IA. Las fuentes sin datos locales de tokens o `totalNanoAiu` se omiten de las estadísticas de facturación en lugar de recurrir a los recuentos de peticiones.

- **v0.1.26** — **Corregir la contabilidad de shutdown-resume para Créditos de IA y tasa de aciertos en caché.** La CLI de Copilot puede escribir múltiples resúmenes reales de `session.shutdown` en el mismo archivo de sesión después de `copilot --resume`; las versiones anteriores colapsaban esas filas por `(session, model, remote)`, subestimando los Créditos de IA y haciendo que las tasas de aciertos en caché parezcan mucho más bajas de lo que son. Las filas de shutdown ahora se indexan por su desplazamiento de bytes de evento estable, se reconstruyen las filas viejas colapsadas de caché de shutdown y las estimaciones de salida de mensajes del asistente ya no cuentan dos veces las sesiones que ya tienen `totalNanoAiu` autorizado.

- **v0.1.25** — **Relleno de Créditos de IA remotos para hosts sincronizados antes del soporte de `totalNanoAiu`.** Las versiones más antiguas de CopilotMeter podían avanzar los desplazamientos del extractor de un host remoto más allá de las líneas `session.shutdown` antes de leer el `totalNanoAiu` autorizado de GitHub, dejando hosts como `l40` estancados en estimaciones bajas basadas en tokens. Esta versión restablece cada desplazamiento del extractor remoto una vez, reproduce los resúmenes de sesiones finalizadas y rellena `ai_credits_nano` de forma idempotente en la caché local.

- **v0.1.24** — **Desglose de origen por host en la pista *Remote hosts* + una nota en línea que explica cómo aparecen las sesiones reanudadas con `copilot --resume`.** Al pasar el cursor sobre cualquier chip remoto (p. ej., `@host 211 AIU`), ahora ves una descomposición de Créditos de IA por origen en lugar de un único número agregado. Una nueva leyenda debajo de la tira de chips explica el punto de confusión más común: cuando ejecutas `copilot --resume` en un remoto contra un worktree de agente (rama `agents/...`, directorio de trabajo actual `.worktrees/agents-...`), la sesión original de GitHub Coding Agent sigue emitiendo `context.hostType="github"` en su events.jsonl, por lo que las sesiones reanudadas se clasifican como **Cloud Agent** en lugar de CLI, incluso aunque hayas escrito `copilot` en tu terminal. La clasificación es correcta (los datos provienen de una sesión de Coding Agent); la pista y la leyenda ahora hacen esto visible en lugar de dejar que los usuarios adivinen a dónde fue su uso. Se añadió un agregado conjunto `byWindowByRemoteSource` para respaldar el desglose; sin cambios de precios ni de ingestión.

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/zhongjiechen/CopilotMeter/main/Scripts/install.sh | bash
```

O descarga `CopilotMeter.dmg` desde la [última versión](https://github.com/zhongjiechen/CopilotMeter/releases/latest). El DMG está firmado de forma ad-hoc (no notariado), por lo que si al hacer doble clic aparece *"Apple no puede verificar..."*, ejecuta:

```bash
xattr -d com.apple.quarantine ~/Downloads/CopilotMeter.dmg
open ~/Downloads/CopilotMeter.dmg
```

Luego arrastra CopilotMeter a `/Applications` y añádelo a **Ajustes del Sistema → General → Elementos de inicio**.

## Rastreo de máquinas remotas (opcional)

Abre la ventana emergente → expande **Remote hosts** → marca cualquier host de tu `~/.ssh/config`. CopilotMeter canaliza un pequeño extractor de Python a través de SSH y extrae solo los eventos relevantes para los tokens:

| | Primera sincronización | Incremental |
|---|---|---|
| Red | ~3 MB | ~1 KB |
| Tiempo | ~30 s | ~5 s |
| Disco local | 4 KB | (sin cambios) |

Ningún prompt de usuario ni respuesta del asistente sale del servidor remoto. Se actualiza automáticamente cada hora.

## Fuentes de datos

| Fuente | Dónde | ¿Datos de tokens? |
|---|---|---|
| Copilot CLI | `~/.copilot/session-state/<sid>/events.jsonl` | ✅ completo |
| VS Code Agent (local) | misma ruta — invocado por VS Code Chat en modo Agente | ✅ completo |
| VS Code Agent (remoto vscode-server) | `workspaceStorage/<wkHash>/GitHub.copilot-chat/transcripts/<sid>.jsonl` | ❌ sin datos locales de Créditos de IA [^1] |
| VS Code Ask / Edit Chat | `globalStorage/.../session-store.db` central + transcripciones | ❌ sin datos locales de Créditos de IA [^1] |
| Cloud Agent (enviado a la nube) | events.jsonl con `hostType=github` | ✅ completo |
| Remote hosts | extraído vía SSH desde los directorios de datos de cada remoto | igual por origen que arriba |
| Caché | `~/Library/Application Support/CopilotMeter/cache.db` | — |

[^1]: VS Code Copilot Chat marca los eventos `assistant.usage` que contienen tokens como `ephemeral` y los filtra antes de escribir en disco, por lo que los recuentos de tokens de entrada/salida por turno y los valores de Créditos de IA no están disponibles en el sistema de archivos local. CopilotMeter omite esas sesiones de las estadísticas de facturación de Créditos de IA.

No se realizan llamadas de red excepto el SSH a los remotos habilitados.

## Compilar desde el código fuente

```bash
git clone https://github.com/zhongjiechen/CopilotMeter.git
cd CopilotMeter
make app             # compila y ensambla CopilotMeter.app
make dmg             # compila y empaqueta CopilotMeter.dmg
make install         # copia a /Applications
```

Requiere Apple Silicon + Xcode CLT (Swift 5.9 +).

## Licencia

MIT — véase [LICENSE](LICENSE).
