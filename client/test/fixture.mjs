import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, cp, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const godot = process.env.STAGEHAND_GODOT ?? 'godot';

export async function launchFixture({
  builtins, bindAddress, expectedErrors = [], strictDeclarations,
} = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'stagehand-test-'));
  const token = randomBytes(24).toString('hex');
  let child,
    output = '';
  const userDirectory = join(
    homedir(),
    'Library/Application Support/stagehand-tests',
    basename(directory),
  );
  const stop = async () => {
    if (child && child.exitCode === null) {
      child.kill('SIGTERM');
      await once(child, 'exit');
    }
    if (process.env.STAGEHAND_KEEP_FIXTURE) console.log(`Fixture: ${directory}\n${output}`);
    else {
      await rm(directory, { recursive: true, force: true });
      if (process.platform === 'darwin') await rm(userDirectory, { recursive: true, force: true });
    }

    for (const line of output.split('\n').filter((line) => /SCRIPT ERROR:|ERROR:/.test(line))) {
      assert.ok(expectedErrors.some((pattern) => pattern.test(line)),
        `fixture emitted an unexpected engine error:\n${output}`);
    }
  };

  try {
    await cp(join(repo, 'tests/fixture'), directory, { recursive: true });
    await cp(join(repo, 'addons/stagehand'), join(directory, 'addons/stagehand'), {
      recursive: true,
    });

    const project = join(directory, 'project.godot');
    await writeFile(
      project,
      (await readFile(project, 'utf8')).replace(
        'config/custom_user_dir_name="stagehand-fixture"',
        `config/custom_user_dir_name="stagehand-tests/${basename(directory)}"`,
      ) + (strictDeclarations ? '\n[debug]\ngdscript/warnings/untyped_declaration=2\n'
        + 'gdscript/warnings/static_called_on_instance=2\n' : ''),
    );

    let binary = godot;
    let args = ['--headless', '--audio-driver', 'Dummy', '--path', directory];
    if (process.env.STAGEHAND_RELEASE) {
      const pack = join(directory, 'fixture.pck');
      const exported = spawnSync(
        godot,
        ['--headless', '--path', directory, '--export-pack', 'Stagehand Fixture', pack],
        {
          encoding: 'utf8',
          timeout: 30_000,
        },
      );

      assert.equal(exported.status, 0, `Export failed:\n${exported.stdout}\n${exported.stderr}`);
      binary = join(directory, 'fixture');
      await cp(process.env.STAGEHAND_RELEASE, binary);
      args = ['--headless', '--audio-driver', 'Dummy'];
    }
    if (process.env.STAGEHAND_GRAPHICAL === '1') args = args.filter((arg) => arg !== '--headless');
    child = spawn(binary, args, {
      env: {
        ...process.env,
        STAGEHAND_TOKEN: token,
        STAGEHAND_BIND_ADDRESS: bindAddress ?? '',
        ...(builtins ? { STAGEHAND_BUILTINS: builtins.join(',') } : {}),
        ...(builtins === null ? { STAGEHAND_SKIP_BUILTINS: '1' } : {}),
      },
    });

    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`Fixture did not start:\n${output}`)),
        15_000,
      );
      const collect = (chunk) => {
        output += chunk.toString();

        const match = output.match(/STAGEHAND_READY (\d+)/);
        if (!match && /SCRIPT ERROR:|ERROR:/.test(output)) {
          clearTimeout(timer);
          reject(new Error(`Fixture failed to load:\n${output}`));

          return;
        }
        if (match) {
          clearTimeout(timer);
          let host = bindAddress ?? '127.0.0.1';
          if (host === '*' || host === '0.0.0.0') {
            host = '127.0.0.1';
          } else if (host === '::') {
            host = '::1';
          }

          resolve(`ws://${host.includes(':') ? `[${host}]` : host}:${match[1]}`);
        }
      };
      child.stdout.on('data', collect);
      child.stderr.on('data', collect);
      child.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`Fixture exited ${code}:\n${output}`));
      });
    });

    const waitForOutput = (pattern) => new Promise((resolve, reject) => {
      const check = () => {
        if (pattern.test(output)) finish();
      };
      const finish = (error) => {
        clearTimeout(timer);
        child.stdout.off('data', check);
        child.stderr.off('data', check);
        if (error) reject(error);
        else resolve(output);
      };
      const timer = setTimeout(() => finish(new Error(`Missing fixture output: ${pattern}`)), 2000);

      child.stdout.on('data', check);
      child.stderr.on('data', check);
      check();
    });

    return { url, token, stop, output: () => output, waitForOutput };
  } catch (error) {
    await stop().catch(() => {});

    throw error;
  }
}
