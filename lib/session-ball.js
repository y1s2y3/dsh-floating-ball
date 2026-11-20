/**
 * session-ball entry point.
 *
 *   v2       : our clean-room host (lib/floating-ball-v2.js) + resources/ball-v2.ps1
 *              <- PRODUCTION DEFAULT (v1.0.0)
 *   upstream : the original host (lib/session-ball-upstream.js) + resources/ball.ps1
 *              <- legacy rollback only; a verbatim copy is kept in legacy/original-plugin/
 *
 * `config.engine = 'upstream'` is the ONLY way to leave v2; anything else (including no config)
 * runs the production engine. Rolling back is one line in the Profile patch:
 *
 *   # profile cordis.patch.yml
 *   - id: session-ball
 *     name: dsh-floating-ball
 *     config:
 *       engine: upstream    # legacy rollback; remove this line to return to production v2
 */
// The v2 engine is imported statically (it has no external deps) so apply() stays synchronous and
// registers its cleanup effect immediately: an apply() that awaits an import first can be disposed
// before ctx.effect() runs, which leaks a second host/ball on every reload. The upstream engine
// still needs a lazy import because its module depends on @deepseek-ai/schemastery.
import { apply as applyV2 } from './floating-ball-v2.js'

export const name = 'session-ball'

export function resolveEngine(config) {
  const raw = config ?? {}
  return raw.engine === 'upstream' ? 'upstream' : 'v2'
}

export function apply(ctx, config) {
  const engine = resolveEngine(config)
  ctx.logger?.info?.(`session-ball：宿主引擎 engine=${engine}（production=v2 / legacy=upstream）`)
  if (engine === 'v2') return applyV2(ctx, config)
  return import('./session-ball-upstream.js').then((module) => {
    const start = module.apply ?? module.default?.apply
    if (typeof start !== 'function') throw new Error('session-ball: upstream engine has no apply()')
    return start(ctx, config)
  })
}

export default { name, apply, resolveEngine }
