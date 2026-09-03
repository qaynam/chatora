import { execFile as execFileCb } from 'node:child_process'
import { promisify } from 'node:util'
import { Context, Effect, Layer } from 'effect'
import { CommandExecutorError } from './errors'

const execFileAsync = promisify(execFileCb)

export interface CommandExecutorShape {
  /**
   * Runs `file` with `args` as a literal argv array — never a shell string — so an
   * untrusted value (a PAT) passed as one array element cannot be reinterpreted by a
   * shell.
   */
  readonly execFile: (
    file: string,
    args: readonly string[],
  ) => Effect.Effect<{ stdout: string; stderr: string }, CommandExecutorError>
}

export class CommandExecutor extends Context.Tag('@chatora/core/CommandExecutor')<
  CommandExecutor,
  CommandExecutorShape
>() {}

export const CommandExecutorLive: Layer.Layer<CommandExecutor> = Layer.succeed(
  CommandExecutor,
  CommandExecutor.of({
    execFile: (file, args) =>
      Effect.tryPromise({
        try: () => execFileAsync(file, args as string[]),
        catch: (cause) => new CommandExecutorError({ command: file, args, cause }),
      }),
  }),
)
