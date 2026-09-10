/**
 * Reads the cwd of the focused herdr pane for a WezTerm tty, when herdr
 * (a terminal multiplexer) is running in the foreground of that tty.
 *
 * Resolution has three steps, each degrading to null on any ambiguity or
 * failure rather than guessing:
 *   1. Find the herdr process in the foreground process group of the tty (`ps`).
 *   2. Find herdr's API socket by correlating its client connection to the
 *      server process's bound sockets (`lsof -U -F pdn`).
 *   3. Ask the API socket for the focused pane's cwd (newline-delimited JSON).
 */
import { execFile } from 'child_process';
import { promises as fsPromises } from 'fs';
import net from 'net';
import { generateId } from './common';

const MAX_COMMAND_OUTPUT_BYTES = 10 * 1024 * 1024;
const MAX_RESPONSE_LINE_BYTES = 1024 * 1024;

/**
 * Finds the herdr pid among the foreground process group of a tty.
 * @param psOutput - Output of `ps -t <tty> -o pid=,stat=,comm=`
 */
export function parseForegroundHerdrPid(psOutput: string): number | null {
  const foregroundHerdrPids: number[] = [];

  for (const rawLine of psOutput.split('\n')) {
    const line = rawLine.trim();
    if (!line) continue;

    // comm can contain spaces (e.g. "/Applications/Herdr Tools/herdr"), so only
    // the first two fields are split off; everything else is the comm.
    const fields = line.match(/^(\d+)\s+(\S+)\s+(.+)$/);
    if (!fields) continue;
    const pidStr = fields[1];
    const stat = fields[2];
    const comm = fields[3];
    if (pidStr === undefined || stat === undefined || comm === undefined) continue;

    // '+' marks the tty's foreground process group; session leaders and
    // background processes must not match.
    if (!stat.includes('+')) continue;

    const commBase = comm.trim().split('/').pop();
    if (commBase === 'herdr') {
      foregroundHerdrPids.push(Number(pidStr));
    }
  }

  if (foregroundHerdrPids.length !== 1) return null;
  return foregroundHerdrPids[0] ?? null;
}

interface LsofRecord {
  pid: number;
  device: string;
  name: string | undefined;
}

/**
 * Parses `lsof -U -F pdn` output into per-fd records.
 *
 * `f<fd>` opens a new record; `d<device>`/`n<name>` belong to whichever `f`
 * most recently opened. A record is discarded unless it has a device, since
 * a name without a device cannot be correlated to anything.
 */
function parseLsofRecords(lsofOutput: string): LsofRecord[] {
  const records: LsofRecord[] = [];
  let currentPid: number | null = null;
  let recordOpen = false;
  let currentDevice: string | undefined;
  let currentName: string | undefined;

  const finalizeRecord = (): void => {
    if (recordOpen && currentPid !== null && currentDevice !== undefined) {
      records.push({ pid: currentPid, device: currentDevice, name: currentName });
    }
    recordOpen = false;
    currentDevice = undefined;
    currentName = undefined;
  };

  for (const rawLine of lsofOutput.split('\n')) {
    // Only a trailing \r (CRLF) is stripped; lsof -F values (e.g. socket
    // paths) may legitimately contain trailing spaces and must not be trimmed.
    const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
    if (line.length === 0) continue;
    const tag = line[0];
    const value = line.slice(1);

    if (tag === 'p') {
      finalizeRecord();
      const pid = Number(value);
      currentPid = Number.isFinite(pid) ? pid : null;
    } else if (tag === 'f') {
      finalizeRecord();
      recordOpen = true;
    } else if (tag === 'd' && recordOpen) {
      // An empty device is treated as no device at all (the record still
      // gets discarded below), since it can never correlate to anything.
      if (value.length > 0) currentDevice = value;
    } else if (tag === 'n' && recordOpen) {
      currentName = value;
    }
  }
  finalizeRecord();

  return records;
}

/**
 * Finds herdr's API socket path by correlating clientPid's unix peer
 * addresses to a server process's bound sockets, then excluding whichever
 * bound socket the client is already connected to. Falls back to null
 * whenever the server process or the remaining candidate isn't unique.
 */
export function parseApiSocketPath(lsofOutput: string, clientPid: number): string | null {
  const records = parseLsofRecords(lsofOutput);
  const peerPrefix = '->';

  const clientPeerAddresses = new Set<string>();
  for (const record of records) {
    if (record.pid !== clientPid || !record.name?.startsWith(peerPrefix)) continue;
    const peerAddress = record.name.slice(peerPrefix.length);
    // An empty peer address ("n->" with nothing after it) is malformed and
    // must not be treated as a valid correlation key.
    if (peerAddress.length > 0) clientPeerAddresses.add(peerAddress);
  }
  // With more than one distinct peer, "the" client connection isn't unique,
  // so any bound path derived from it (including by elimination) isn't
  // trustworthy either — e.g. two peers could each match a different bound
  // path on the same server, leaving an unrelated third path looking like
  // the sole remaining candidate.
  if (clientPeerAddresses.size !== 1) return null;

  // A pid can only be a server candidate if it actually exposes some bound
  // socket; a device match on a bare peer-connection record (no bound path
  // at all, e.g. a truncated or malformed one) isn't enough to trust that pid.
  const pidsWithBoundPaths = new Set<number>();
  for (const record of records) {
    if (record.name?.startsWith('/')) pidsWithBoundPaths.add(record.pid);
  }

  const candidatePids = new Set<number>();
  for (const record of records) {
    if (clientPeerAddresses.has(record.device) && pidsWithBoundPaths.has(record.pid)) {
      candidatePids.add(record.pid);
    }
  }
  if (candidatePids.size !== 1) return null;
  const [serverPid] = candidatePids;
  if (serverPid === undefined) return null;

  const boundPaths = new Set<string>();
  const connectedPaths = new Set<string>();
  for (const record of records) {
    if (record.pid !== serverPid || !record.name?.startsWith('/')) continue;
    boundPaths.add(record.name);
    if (clientPeerAddresses.has(record.device)) {
      connectedPaths.add(record.name);
    }
  }
  // The device match that identified serverPid may not itself have been a
  // bound path; require actual proof the client is connected to one of this
  // server's bound sockets before trusting any of its other bound paths.
  if (connectedPaths.size === 0) return null;

  const apiCandidates = [...boundPaths].filter(candidate => !connectedPaths.has(candidate));
  return apiCandidates.length === 1 ? apiCandidates[0] ?? null : null;
}

/**
 * Runs a command with a hard timeout, collapsing every failure mode
 * (missing binary, non-zero exit, signal, timeout, oversized output, empty
 * output) to null so callers never have to distinguish them.
 */
function runCommand(command: string, args: string[], timeoutMs: number): Promise<string | null> {
  // execFile's timeout option requires a positive integer; performance.now()
  // (the default clock) returns fractional milliseconds, and passing one
  // through synchronously throws ERR_OUT_OF_RANGE before the callback runs.
  const boundedTimeoutMs = Math.max(1, Math.floor(timeoutMs));
  return new Promise(resolve => {
    execFile(
      command,
      args,
      { timeout: boundedTimeoutMs, maxBuffer: MAX_COMMAND_OUTPUT_BYTES, killSignal: 'SIGTERM' as const },
      (error, stdout) => {
        if (error || !stdout || stdout.trim().length === 0) {
          resolve(null);
          return;
        }
        resolve(stdout);
      }
    );
  });
}

/** Runs `stage` with the remaining time in `deadline`, or null if none is left. */
async function withRemainingBudget<T>(
  deadline: number,
  now: () => number,
  stage: (remainingMs: number) => Promise<T | null>
): Promise<T | null> {
  const remainingMs = deadline - now();
  if (remainingMs <= 0) return null;
  return stage(remainingMs);
}

/**
 * Stats a path (following symlinks) racing a timeout. Any rejection reason
 * (ENOENT, EACCES, EPERM, ELOOP, ...) collapses to false, same as a timeout.
 */
async function statIsSocketWithTimeout(path: string, timeoutMs: number): Promise<boolean> {
  const boundedTimeoutMs = Math.max(1, Math.floor(timeoutMs));
  const timedOut = Symbol('herdr-client-stat-timeout');
  let timer: NodeJS.Timeout | undefined;
  const timeoutPromise = new Promise<typeof timedOut>(resolve => {
    timer = setTimeout(() => resolve(timedOut), boundedTimeoutMs);
  });

  try {
    const outcome = await Promise.race([
      fsPromises.stat(path).then(stats => stats.isSocket()).catch(() => false),
      timeoutPromise
    ]);
    return outcome === timedOut ? false : outcome;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * Resolves the tty's foreground herdr API socket within a single time
 * budget shared across `ps`, `lsof`, and the socket stat check.
 * @param tty - e.g. "ttys000" or "/dev/ttys000"
 * @param budgetMs - total time budget across all steps
 * @param now - monotonic clock, injectable for tests (defaults to performance.now)
 */
export async function resolveHerdrApiSocket(
  tty: string,
  budgetMs: number,
  now: () => number = () => performance.now()
): Promise<string | null> {
  const normalizedTty = tty.startsWith('/dev/') ? tty.slice('/dev/'.length) : tty;
  const deadline = now() + budgetMs;

  const psOutput = await withRemainingBudget(deadline, now, remainingMs =>
    runCommand('/bin/ps', ['-t', normalizedTty, '-o', 'pid=,stat=,comm='], remainingMs));
  const pid = psOutput !== null ? parseForegroundHerdrPid(psOutput) : null;
  if (pid === null) return null;

  const lsofOutput = await withRemainingBudget(deadline, now, remainingMs =>
    runCommand('/usr/sbin/lsof', ['-U', '-F', 'pdn'], remainingMs));
  const socketPath = lsofOutput !== null ? parseApiSocketPath(lsofOutput, pid) : null;
  if (socketPath === null) return null;

  const isSocket = await withRemainingBudget(deadline, now, remainingMs =>
    statIsSocketWithTimeout(socketPath, remainingMs));
  return isSocket === true ? socketPath : null;
}

/**
 * Validates a `pane.current` response line, requiring a matching id and a
 * non-empty absolute cwd. Falls back to `pane.cwd` when `foreground_cwd` is
 * missing or null.
 */
function parseHerdrResponse(line: string, expectedId: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) return null;
  const response = parsed as Record<string, unknown>;
  if (response['id'] !== expectedId) return null;

  const result = response['result'];
  if (typeof result !== 'object' || result === null) return null;
  const resultObj = result as Record<string, unknown>;
  if (resultObj['type'] !== 'pane_current') return null;

  const pane = resultObj['pane'];
  if (typeof pane !== 'object' || pane === null) return null;
  const paneObj = pane as Record<string, unknown>;

  const cwd = paneObj['foreground_cwd'] ?? paneObj['cwd'];
  if (typeof cwd !== 'string' || cwd.length === 0 || !cwd.startsWith('/')) return null;
  return cwd;
}

/**
 * Fetches the focused pane's cwd from herdr's API socket via a single
 * newline-delimited JSON request/response.
 */
export function getHerdrFocusedPaneCwd(socketPath: string, timeoutMs: number): Promise<string | null> {
  return new Promise(resolve => {
    const requestId = generateId();
    const socket = net.createConnection({ path: socketPath });
    let settled = false;
    const chunks: Buffer[] = [];
    let totalLength = 0;

    const timer = setTimeout(() => settle(null), timeoutMs);

    function cleanup(): void {
      clearTimeout(timer);
      socket.destroy();
    }

    function settle(result: string | null): void {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(result);
    }

    socket.on('connect', () => {
      socket.write(`${JSON.stringify({ id: requestId, method: 'pane.current', params: {} })}\n`);
    });

    // Chunks are buffered as an array (not concatenated eagerly) so that
    // many small chunks don't cost O(n^2); concatenating as Buffer (not
    // string) also avoids splitting multi-byte UTF-8 characters mid-chunk.
    socket.on('data', (chunk: Buffer) => {
      chunks.push(chunk);
      totalLength += chunk.length;

      const newlineIndexInChunk = chunk.indexOf(0x0a);
      if (newlineIndexInChunk === -1) {
        if (totalLength > MAX_RESPONSE_LINE_BYTES) settle(null);
        return;
      }

      // The overflow check applies to the first line's length regardless of
      // whether a newline was found, so an oversized line isn't let through
      // just because it happens to be terminated.
      const lineLength = totalLength - chunk.length + newlineIndexInChunk;
      if (lineLength > MAX_RESPONSE_LINE_BYTES) {
        settle(null);
        return;
      }

      const combined = Buffer.concat(chunks, totalLength);
      const line = combined.subarray(0, lineLength).toString('utf8');
      settle(parseHerdrResponse(line, requestId));
    });

    socket.on('error', () => settle(null));
    socket.on('end', () => settle(null));
    socket.on('close', () => settle(null));
  });
}
