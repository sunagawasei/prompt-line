import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { EventEmitter } from 'events';

const { mockExecFile } = vi.hoisted(() => ({ mockExecFile: vi.fn() }));
const { mockStat } = vi.hoisted(() => ({ mockStat: vi.fn() }));
const { mockCreateConnection } = vi.hoisted(() => ({ mockCreateConnection: vi.fn() }));

vi.mock('child_process', () => ({
  execFile: mockExecFile
}));

vi.mock('fs', () => ({
  promises: {
    stat: mockStat
  }
}));

vi.mock('net', () => {
  const netMock = { createConnection: mockCreateConnection };
  return { ...netMock, default: netMock };
});

import {
  parseForegroundHerdrPid,
  parseApiSocketPath,
  resolveHerdrApiSocket,
  getHerdrFocusedPaneCwd
} from '../../src/utils/herdr-client';

function lines(...rows: string[]): string {
  return rows.join('\n');
}

describe('parseForegroundHerdrPid', () => {
  it('returns the pid of the S+ herdr process', () => {
    const output = lines(
      '19338 Ss   -zsh',
      '19534 SN   deno',
      '63556 S+   herdr'
    );
    expect(parseForegroundHerdrPid(output)).toBe(63556);
  });

  it('does not return the Ss session leader shell', () => {
    const output = lines('19338 Ss   -zsh');
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('does not return an SN process even if named herdr', () => {
    const output = lines('19534 SN   herdr');
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('does not return a stopped (T) herdr', () => {
    const output = lines('63556 T   herdr');
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('does not return herdr without a + in stat', () => {
    const output = lines('63556 Ss   herdr');
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('matches when comm is an absolute path', () => {
    const output = lines('63556 S+   /nix/store/abc123-herdr/bin/herdr');
    expect(parseForegroundHerdrPid(output)).toBe(63556);
  });

  it('matches when comm is an absolute path containing spaces', () => {
    const output = lines('63556 S+   /Applications/Herdr Tools/herdr');
    expect(parseForegroundHerdrPid(output)).toBe(63556);
  });

  it('returns null when multiple + herdr processes are present', () => {
    const output = lines(
      '63556 S+   herdr',
      '70001 S+   herdr'
    );
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('returns null when herdr is not present', () => {
    const output = lines(
      '19338 Ss   -zsh',
      '19534 SN   deno'
    );
    expect(parseForegroundHerdrPid(output)).toBeNull();
  });

  it('returns null for empty input', () => {
    expect(parseForegroundHerdrPid('')).toBeNull();
  });

  it('returns null for header-only input', () => {
    expect(parseForegroundHerdrPid('PID STAT COMM')).toBeNull();
  });
});

describe('parseApiSocketPath', () => {
  it('returns herdr.sock for the real-world fixture shape', () => {
    const output = lines(
      'p63556',
      'f4',
      'd0xCLIENT4',
      'n->0xa2f6e19661b8f50e',
      'f5',
      'd0xCLIENT5',
      'n->0xa2f6e19661b8f50e',
      'p21034',
      'f4',
      'd0x4de0d7f3038e4a18',
      'n/Users/s23159/.config/herdr/herdr.sock',
      'f8',
      'd0xa2f6e19661b8f50e',
      'n/Users/s23159/.config/herdr/herdr-client.sock',
      'f9',
      'd0xfaf18becbc6f6582',
      'n/Users/s23159/.config/herdr/herdr-client.sock',
      'f10',
      'd0xa2f6e19661b8f50e',
      'n/Users/s23159/.config/herdr/herdr-client.sock'
    );
    expect(parseApiSocketPath(output, 63556)).toBe('/Users/s23159/.config/herdr/herdr.sock');
  });

  it('returns the real API socket path when it lives outside the config directory', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock',
      'f3',
      'd0xQ',
      'n/opt/herdr-alt/api.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBe('/opt/herdr-alt/api.sock');
  });

  it('returns herdr.sock for a named session under sessions/<name>/', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/Users/s23159/.config/herdr/sessions/foo/herdr-client.sock',
      'f3',
      'd0xQ',
      'n/Users/s23159/.config/herdr/sessions/foo/herdr.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBe('/Users/s23159/.config/herdr/sessions/foo/herdr.sock');
  });

  it('returns herdr.sock for a named session under an herdr-dev directory', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/Users/s23159/.config/herdr-dev/sessions/foo/herdr-client.sock',
      'f3',
      'd0xQ',
      'n/Users/s23159/.config/herdr-dev/sessions/foo/herdr.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBe('/Users/s23159/.config/herdr-dev/sessions/foo/herdr.sock');
  });

  it('does not misjoin d and n across records: d+peer-name complete, then an orphan name with no device', () => {
    const output = lines(
      'p5001',
      'f1',
      'd0xCLI',
      'n->0xSRVID',
      'p6002',
      'f2',
      'd0xSRVID',
      'n->0xREMOTE',
      'f3',
      'd0xOTHER',
      'n->0xSOMETHINGELSE',
      'f4',
      'n/tmp/orphan1.sock'
    );
    expect(parseApiSocketPath(output, 5001)).toBeNull();
  });

  it('does not misjoin d and n across records: orphan name with no device, then a complete d+name record', () => {
    const output = lines(
      'p5001',
      'f1',
      'd0xCLI',
      'n->0xSRVID',
      'p6002',
      'f2',
      'n->0xDANGLING',
      'f3',
      'd0xSRVID',
      'n/tmp/orphan2.sock'
    );
    expect(parseApiSocketPath(output, 5001)).toBeNull();
  });

  it('does not misjoin d and n across records: device with no name, then an orphan name with no device', () => {
    const output = lines(
      'p5001',
      'f1',
      'd0xCLI',
      'n->0xSRVID',
      'p6002',
      'f2',
      'd0xSRVID',
      'n->0xREMOTE',
      'f3',
      'd0xOTHER',
      'f4',
      'n/tmp/orphan3.sock'
    );
    expect(parseApiSocketPath(output, 5001)).toBeNull();
  });

  it('counts the same bound path appearing on multiple fds as a single candidate', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock',
      'f3',
      'd0xQ1',
      'n/tmp/api.sock',
      'f4',
      'd0xQ2',
      'n/tmp/api.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBe('/tmp/api.sock');
  });

  it('returns null when the client has multiple distinct unix peers', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP1',
      'f2',
      'd0xC2',
      'n->0xP2',
      'p200',
      'f3',
      'd0xP1',
      'n->0xX',
      'p300',
      'f4',
      'd0xP2',
      'n->0xY'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when server candidates span multiple processes', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/server200.sock',
      'p300',
      'f3',
      'd0xP',
      'n/tmp/server300.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when two or more API candidates remain', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock',
      'f3',
      'd0xQ1',
      'n/tmp/api1.sock',
      'f4',
      'd0xQ2',
      'n/tmp/api2.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when the device match is on a bare peer record with no bound path, even if the pid has one other bound path (F-42)', () => {
    // f2's device matches the client's peer, but f2 itself is not a bound
    // path (name is a peer address, not a path); f3 is a genuine bound path
    // on the same pid but for an unrelated device. Trusting f2 alone would
    // wrongly return f3's path with zero proof of a real connection to it.
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n->0xREMOTE',
      'f3',
      'd0xQ',
      'n/tmp/onlyother.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when a client holds two distinct peers, even if both map to the same server (connection is not unique)', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP1',
      'f2',
      'd0xC2',
      'n->0xP2',
      'p200',
      'f3',
      'd0xP1',
      'n/tmp/bound1.sock',
      'f4',
      'd0xP2',
      'n/tmp/bound2.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when two distinct peers each consume a different bound path, leaving an unrelated third path looking like the sole candidate (F-48)', () => {
    // Without the single-peer requirement, P1 and P2 would each be
    // "connected" to one of client.sock/api.sock, leaving unrelated.sock as
    // the only bound path nobody is connected to — and thus wrongly
    // returned, even though the client never actually talked to it.
    const output = lines(
      'p100',
      'f3',
      'd0xP1',
      'n->0xP1',
      'f4',
      'd0xP2',
      'n->0xP2',
      'p200',
      'f5',
      'd0xP1',
      'n/tmp/client.sock',
      'f6',
      'd0xP2',
      'n/tmp/api.sock',
      'f7',
      'd0xQ',
      'n/tmp/unrelated.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when the server has bound only the client-connected socket', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when the peer address does not resolve to any bound path', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xNOWHERE',
      'p200',
      'f2',
      'd0xQ',
      'n->0xREMOTE',
      'f3',
      'd0xR',
      'n/tmp/somepath.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('does not throw and returns null on output truncated mid-record', () => {
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n->0xREMOTE',
      'f3',
      'd0xQ'
    );
    expect(() => parseApiSocketPath(output, 100)).not.toThrow();
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('returns null when the lsof output contains an empty device and an empty peer address (F-51)', () => {
    // Without treating empty d/n values as "absent", the empty peer address
    // ("n->" with nothing after it) would form a {''} peer set that matches
    // the server's empty-device bound path, letting the unrelated
    // /tmp/real-api.sock look like the sole remaining candidate.
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->',
      'p200',
      'f2',
      'd',
      'n/tmp/empty-device.sock',
      'f3',
      'd0xQ',
      'n/tmp/real-api.sock'
    );
    expect(parseApiSocketPath(output, 100)).toBeNull();
  });

  it('preserves a trailing-whitespace socket path (F-52)', () => {
    const pathWithTrailingSpace = '/tmp/api-trailing-space.sock  ';
    const output = lines(
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock',
      'f3',
      'd0xQ',
      `n${pathWithTrailingSpace}`
    );
    expect(parseApiSocketPath(output, 100)).toBe(pathWithTrailingSpace);
  });

  it('preserves a trailing-whitespace socket path with CRLF line endings (F-52)', () => {
    const pathWithTrailingSpace = '/tmp/api-crlf-trailing-space.sock  ';
    const rawLines = [
      'p100',
      'f1',
      'd0xC1',
      'n->0xP',
      'p200',
      'f2',
      'd0xP',
      'n/tmp/connected.sock',
      'f3',
      'd0xQ',
      `n${pathWithTrailingSpace}`,
      'p999'
    ];
    // Every line (including the target one) gets a trailing \r from the
    // CRLF join; only that \r should be stripped, not the path's own spaces.
    const output = rawLines.join('\r\n');
    expect(parseApiSocketPath(output, 100)).toBe(pathWithTrailingSpace);
  });
});

describe('resolveHerdrApiSocket', () => {
  function makeNow(sequence: number[]): () => number {
    let index = 0;
    return () => {
      const value = sequence[index] ?? sequence[sequence.length - 1] ?? 0;
      index += 1;
      return value;
    };
  }

  function mockExecFileSequence(
    responses: Array<{ error?: (Error & { killed?: boolean }) | null; stdout?: string }>
  ): void {
    let call = 0;
    mockExecFile.mockImplementation((_file: string, _args: string[], _options: unknown, callback: (...args: unknown[]) => void) => {
      const response = responses[call] ?? responses[responses.length - 1] ?? {};
      call += 1;
      callback(response.error ?? null, response.stdout ?? '');
    });
  }

  const validPsOutput = '63556 S+   herdr';
  const validLsofOutput = lines(
    'p63556',
    'f4',
    'd0xCLIENT4',
    'n->0xa2f6e19661b8f50e',
    'p21034',
    'f4',
    'd0x4de0d7f3038e4a18',
    'n/Users/s23159/.config/herdr/herdr.sock',
    'f8',
    'd0xa2f6e19661b8f50e',
    'n/Users/s23159/.config/herdr/herdr-client.sock'
  );
  const validSocketPath = '/Users/s23159/.config/herdr/herdr.sock';

  beforeEach(() => {
    vi.useFakeTimers();
    mockExecFile.mockReset();
    mockStat.mockReset();
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  it('normalizes /dev/ttys000 and ttys000 to the same ps argument', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => true });

    await resolveHerdrApiSocket('/dev/ttys000', 1000, makeNow([0, 10, 20, 30]));
    const argsWithDevPrefix = mockExecFile.mock.calls[0]?.[1];

    mockExecFile.mockClear();
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    const argsWithoutPrefix = mockExecFile.mock.calls[0]?.[1];

    expect(argsWithDevPrefix).toEqual(argsWithoutPrefix);
    expect(argsWithDevPrefix).toEqual(['-t', 'ttys000', '-o', 'pid=,stat=,comm=']);
  });

  it('passes args as an array (no shell expansion) with an absolute executable path', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => true });

    await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));

    const psCall = mockExecFile.mock.calls[0];
    expect(psCall?.[0]).toBe('/bin/ps');
    expect(Array.isArray(psCall?.[1])).toBe(true);

    const lsofCall = mockExecFile.mock.calls[1];
    expect(lsofCall?.[0]).toBe('/usr/sbin/lsof');
    expect(Array.isArray(lsofCall?.[1])).toBe(true);
  });

  it('passes a decreasing timeout to each stage and resolves successfully', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => true });

    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 100, 500, 900]));

    expect(result).toBe(validSocketPath);
    const psTimeout = (mockExecFile.mock.calls[0]?.[2] as { timeout: number }).timeout;
    const lsofTimeout = (mockExecFile.mock.calls[1]?.[2] as { timeout: number }).timeout;
    expect(psTimeout).toBe(900);
    expect(lsofTimeout).toBe(500);
    expect(lsofTimeout).toBeLessThan(psTimeout);
  });

  it('does not start ps at all once the initial budget is already exhausted', async () => {
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 1000]));
    expect(result).toBeNull();
    expect(mockExecFile).not.toHaveBeenCalled();
  });

  it('does not start lsof once ps has used up the remaining budget', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }]);

    const result = await resolveHerdrApiSocket('ttys000', 500, makeNow([0, 100, 500]));

    expect(result).toBeNull();
    expect(mockExecFile).toHaveBeenCalledTimes(1);
  });

  it('rounds a fractional clock (like performance.now()) to a positive integer timeout for every stage (F-41)', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => true });

    // Distinct fractional parts per call, matching a real performance.now()
    // clock: using the same offset (e.g. always .5) every time would make
    // deadline-minus-now an integer by coincidence and hide a missing
    // rounding step, since 1000 - 100.5 is already a whole number.
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 12.3, 45.7, 88.9]));

    expect(result).toBe(validSocketPath);
    const psTimeout = (mockExecFile.mock.calls[0]?.[2] as { timeout: number }).timeout;
    const lsofTimeout = (mockExecFile.mock.calls[1]?.[2] as { timeout: number }).timeout;
    expect(Number.isInteger(psTimeout)).toBe(true);
    expect(Number.isInteger(lsofTimeout)).toBe(true);
    // 1000 - 12.3 = 987.7 -> floor 987; 1000 - 45.7 = 954.3 -> floor 954.
    expect(psTimeout).toBe(987);
    expect(lsofTimeout).toBe(954);
  });

  it('returns null when ps fails with ENOENT', async () => {
    mockExecFileSequence([{ error: Object.assign(new Error('ENOENT'), { code: 'ENOENT' }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when ps exits non-zero', async () => {
    mockExecFileSequence([{ error: Object.assign(new Error('exit 1'), { code: 1 }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when ps is killed by a signal', async () => {
    mockExecFileSequence([{ error: Object.assign(new Error('killed'), { killed: true, signal: 'SIGTERM' }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when ps times out', async () => {
    mockExecFileSequence([{ error: Object.assign(new Error('timed out'), { killed: true, signal: 'SIGTERM' }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when ps output exceeds maxBuffer', async () => {
    mockExecFileSequence([{ error: Object.assign(new Error('maxBuffer exceeded'), { code: 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when ps produces empty stdout', async () => {
    mockExecFileSequence([{ stdout: '' }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when lsof fails', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { error: Object.assign(new Error('ENOENT'), { code: 'ENOENT' }) }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it('returns null when lsof produces empty stdout', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: '' }]);
    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
  });

  it.each(['ENOENT', 'EACCES', 'EPERM', 'ELOOP', 'ENOTDIR', 'EIO'])(
    'returns null when fs.stat rejects with %s',
    async code => {
      // Each case needs its own fresh ps/lsof mock: reusing one sequence
      // across a loop body would starve later iterations of ps/lsof output
      // (they'd fall through to the last mocked response instead) and never
      // actually reach fs.stat at all.
      mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
      mockStat.mockRejectedValueOnce(Object.assign(new Error(code), { code }));

      const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
      expect(result).toBeNull();
      expect(mockStat).toHaveBeenCalledTimes(1);
      expect(vi.getTimerCount()).toBe(0);
    }
  );

  it('returns null when the resolved path is a regular file, not a socket', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => false });

    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('succeeds when the resolved path is a socket reached via a symlink', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockResolvedValue({ isSocket: () => true });

    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBe(validSocketPath);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('returns null for a broken symlink (stat rejects with ENOENT)', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockRejectedValue(Object.assign(new Error('ENOENT'), { code: 'ENOENT' }));

    const result = await resolveHerdrApiSocket('ttys000', 1000, makeNow([0, 10, 20, 30]));
    expect(result).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('returns null when the stat stage times out, and clears its timer', async () => {
    mockExecFileSequence([{ stdout: validPsOutput }, { stdout: validLsofOutput }]);
    mockStat.mockReturnValue(new Promise(() => {
      // never resolves — forces the race to be decided by the timeout
    }));

    const resultPromise = resolveHerdrApiSocket('ttys000', 100, makeNow([0, 10, 20, 30]));
    await vi.advanceTimersByTimeAsync(200);

    expect(await resultPromise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('getHerdrFocusedPaneCwd', () => {
  class MockSocket extends EventEmitter {
    writtenData: string[] = [];
    destroyCallCount = 0;

    write(data: string): boolean {
      this.writtenData.push(data);
      return true;
    }

    destroy(): void {
      this.destroyCallCount += 1;
    }
  }

  let socket: MockSocket;

  beforeEach(() => {
    vi.useFakeTimers();
    socket = new MockSocket();
    mockCreateConnection.mockReset();
    mockCreateConnection.mockImplementation(() => socket);
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  function connect(): string {
    socket.emit('connect');
    const sent = JSON.parse(socket.writtenData[0] as string) as { id: string };
    return sent.id;
  }

  function paneCurrentLine(id: string, pane: Record<string, unknown>): string {
    return `${JSON.stringify({ id, result: { type: 'pane_current', pane } })}\n`;
  }

  it('returns foreground_cwd on a valid response', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(paneCurrentLine(id, { cwd: '/tmp/old', foreground_cwd: '/tmp/new' })));

    expect(await promise).toBe('/tmp/new');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('falls back to cwd when foreground_cwd is missing', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(paneCurrentLine(id, { cwd: '/tmp/only' })));

    expect(await promise).toBe('/tmp/only');
  });

  it('falls back to cwd when foreground_cwd is null', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(paneCurrentLine(id, { cwd: '/tmp/only', foreground_cwd: null })));

    expect(await promise).toBe('/tmp/only');
  });

  it('assembles a response line split across multiple chunks', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    const line = paneCurrentLine(id, { cwd: '/tmp/chunked' });
    const mid = Math.floor(line.length / 2);
    socket.emit('data', Buffer.from(line.slice(0, mid)));
    socket.emit('data', Buffer.from(line.slice(mid)));

    expect(await promise).toBe('/tmp/chunked');
  });

  it('reassembles a Japanese cwd even when a chunk boundary splits a multi-byte character', async () => {
    const japaneseCwd = '/Users/s23159/日本語のパス';
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    const line = paneCurrentLine(id, { cwd: japaneseCwd, foreground_cwd: japaneseCwd });
    const fullBuffer = Buffer.from(line, 'utf8');

    // Pick a split point that lands inside the multi-byte encoding of a
    // Japanese character rather than on a character boundary.
    let splitPoint = -1;
    for (let i = 1; i < fullBuffer.length; i++) {
      // A UTF-8 continuation byte has the top two bits set to 10.
      if ((fullBuffer[i]! & 0xc0) === 0x80) {
        splitPoint = i;
        break;
      }
    }
    expect(splitPoint).toBeGreaterThan(0);

    socket.emit('data', fullBuffer.subarray(0, splitPoint));
    socket.emit('data', fullBuffer.subarray(splitPoint));

    expect(await promise).toBe(japaneseCwd);
  });

  it('returns null when the response id does not match the request id', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    socket.emit('data', Buffer.from(paneCurrentLine('someone-elses-id', { cwd: '/tmp/x' })));

    expect(await promise).toBeNull();
  });

  it('returns null when result.type does not match', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(`${JSON.stringify({ id, result: { type: 'something_else', pane: { cwd: '/tmp/x' } } })}\n`));

    expect(await promise).toBeNull();
  });

  it('returns null when pane is absent', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(`${JSON.stringify({ id, result: { type: 'pane_current' } })}\n`));

    expect(await promise).toBeNull();
  });

  it('returns null when result is absent', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(`${JSON.stringify({ id })}\n`));

    expect(await promise).toBeNull();
  });

  it.each([
    ['both missing', {}],
    ['null', { cwd: null, foreground_cwd: null }],
    ['a number', { cwd: 42 }],
    ['an object', { cwd: {} }],
    ['an empty string', { cwd: '' }],
    ['a relative path', { cwd: 'relative/path' }]
  ])('returns null when cwd is %s', async (_label, pane) => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    socket.emit('data', Buffer.from(paneCurrentLine(id, pane)));

    expect(await promise).toBeNull();
  });

  it('returns null when the socket ends with no response', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    socket.emit('end');

    expect(await promise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('returns null when the socket closes with no newline received', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    socket.emit('data', Buffer.from('{"id":"partial", no newline yet'));
    socket.emit('close');

    expect(await promise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('resolves null and destroys the socket on timeout', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 50);
    connect();
    await vi.advanceTimersByTimeAsync(50);

    expect(await promise).toBeNull();
    expect(socket.destroyCallCount).toBeGreaterThanOrEqual(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('does not settle twice when data or error arrives after a timeout', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 50);
    const id = connect();
    await vi.advanceTimersByTimeAsync(50);
    expect(await promise).toBeNull();

    expect(() => {
      socket.emit('data', Buffer.from(paneCurrentLine(id, { cwd: '/tmp/late' })));
      socket.emit('error', new Error('late error'));
    }).not.toThrow();
  });

  it('returns null on a connection error (ENOENT)', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    socket.emit('error', Object.assign(new Error('ENOENT'), { code: 'ENOENT' }));

    expect(await promise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('returns null on a connection error (ECONNREFUSED)', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    socket.emit('error', Object.assign(new Error('ECONNREFUSED'), { code: 'ECONNREFUSED' }));

    expect(await promise).toBeNull();
  });

  it('returns null on malformed JSON', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    socket.emit('data', Buffer.from('{not valid json\n'));

    expect(await promise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('destroys the socket and returns null once the buffered line exceeds 1 MiB', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    const oversized = Buffer.alloc(1024 * 1024 + 1, 0x61);
    socket.emit('data', oversized);

    expect(await promise).toBeNull();
    expect(socket.destroyCallCount).toBeGreaterThanOrEqual(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('returns null when the first line itself exceeds 1 MiB, even though it is newline-terminated (F-43)', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    connect();
    const oversizedLine = Buffer.concat([Buffer.alloc(1024 * 1024 + 10, 0x61), Buffer.from('\n')]);
    socket.emit('data', oversizedLine);

    expect(await promise).toBeNull();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('accepts a first line under 1 MiB even when a huge line follows it (F-43)', async () => {
    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 1000);
    const id = connect();
    const firstLine = Buffer.from(paneCurrentLine(id, { cwd: '/tmp/first-line' }));
    const hugeFollowingLine = Buffer.concat([Buffer.alloc(2 * 1024 * 1024, 0x62), Buffer.from('\n')]);

    socket.emit('data', Buffer.concat([firstLine, hugeFollowingLine]));

    expect(await promise).toBe('/tmp/first-line');
  });

  it('processes many small chunks in bounded, roughly linear time (F-43)', async () => {
    // A naive per-chunk Buffer.concat([buffer, chunk]) implementation costs
    // O(n^2) here; the fixed implementation only concatenates once, so this
    // should finish in well under a second even on a slow machine.
    vi.useRealTimers();

    const promise = getHerdrFocusedPaneCwd('/tmp/api.sock', 5000);
    connect();

    const chunkCount = 4000;
    const chunkSize = 200; // 4000 * 200 = 800,000 bytes, under the 1 MiB cap
    const start = Date.now();
    for (let i = 0; i < chunkCount; i++) {
      socket.emit('data', Buffer.alloc(chunkSize, 0x78)); // no newline yet
    }
    socket.emit('data', Buffer.from('\n'));
    const result = await promise;
    const elapsedMs = Date.now() - start;

    // The buffered line is just repeated 'x' bytes, not valid JSON, so the
    // outcome is null — what matters here is that it resolves promptly.
    expect(result).toBeNull();
    expect(elapsedMs).toBeLessThan(1000);
  });
});
