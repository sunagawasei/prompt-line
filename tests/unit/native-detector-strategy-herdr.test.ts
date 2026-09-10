import type { MockedFunction } from 'vitest';
import { execFile } from 'child_process';
import { resolveHerdrApiSocket, getHerdrFocusedPaneCwd } from '../../src/utils/herdr-client';
import { listDirectory } from '../../src/utils/file-search';
import { NativeDetectorStrategy } from '../../src/managers/window/strategies/native-detector-strategy';
import type { DirectoryInfo } from '../../src/types';

type ExecFileCallback = (error: Error | null, stdout?: string) => void;

vi.mock('child_process', () => ({
  execFile: vi.fn()
}));

vi.mock('../../src/utils/utils', () => ({
  logger: {
    info: vi.fn(),
    debug: vi.fn(),
    warn: vi.fn(),
    error: vi.fn()
  },
  DIRECTORY_DETECTOR_PATH: '/path/to/directory-detector'
}));

vi.mock('../../src/config/app-config', () => {
  const configMock = { platform: { isMac: true } };
  return { ...configMock, default: configMock };
});

vi.mock('../../src/utils/file-search', () => ({
  listDirectory: vi.fn()
}));

vi.mock('../../src/utils/herdr-client', () => ({
  resolveHerdrApiSocket: vi.fn(),
  getHerdrFocusedPaneCwd: vi.fn()
}));

const mockedExecFile = execFile as unknown as MockedFunction<
  (path: string, args: string[], options: unknown, callback: ExecFileCallback) => void
>;
const mockedResolveHerdrApiSocket = resolveHerdrApiSocket as MockedFunction<typeof resolveHerdrApiSocket>;
const mockedGetHerdrFocusedPaneCwd = getHerdrFocusedPaneCwd as MockedFunction<typeof getHerdrFocusedPaneCwd>;
const mockedListDirectory = listDirectory as MockedFunction<typeof listDirectory>;

/** Queues the Swift directory-detector's stdout for the next `detect()` call. */
function stubDetectorOutput(result: DirectoryInfo): void {
  mockedExecFile.mockImplementationOnce((_path, _args, _options, callback) => {
    callback(null, JSON.stringify(result));
  });
}

describe('NativeDetectorStrategy herdr wiring', () => {
  let strategy: NativeDetectorStrategy;

  beforeEach(() => {
    strategy = new NativeDetectorStrategy();
    mockedListDirectory.mockResolvedValue({ files: [], fileCount: 0, searchMode: 'recursive' });
  });

  it('replaces directory/method with herdr focused pane cwd when the full chain succeeds', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli', tty: 'ttys003' });
    mockedResolveHerdrApiSocket.mockResolvedValue('/tmp/herdr.sock');
    mockedGetHerdrFocusedPaneCwd.mockResolvedValue('/herdr/focused/pane/cwd');

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/herdr/focused/pane/cwd');
    expect(result?.method).toBe('herdr-api');
    expect(mockedListDirectory).toHaveBeenCalledWith('/herdr/focused/pane/cwd', undefined);
  });

  it('keeps the original directory/method when resolveHerdrApiSocket resolves null, and never calls getHerdrFocusedPaneCwd', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli', tty: 'ttys003' });
    mockedResolveHerdrApiSocket.mockResolvedValue(null);

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/tty/snapshot/cwd');
    expect(result?.method).toBe('wezterm-cli');
    expect(mockedGetHerdrFocusedPaneCwd).not.toHaveBeenCalled();
    expect(mockedListDirectory).toHaveBeenCalledWith('/tty/snapshot/cwd', undefined);
  });

  it('keeps the original directory/method when getHerdrFocusedPaneCwd resolves null', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli', tty: 'ttys003' });
    mockedResolveHerdrApiSocket.mockResolvedValue('/tmp/herdr.sock');
    mockedGetHerdrFocusedPaneCwd.mockResolvedValue(null);

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/tty/snapshot/cwd');
    expect(result?.method).toBe('wezterm-cli');
  });

  it('never calls resolveHerdrApiSocket when method is wezterm-process', async () => {
    stubDetectorOutput({ directory: '/proc/tree/cwd', method: 'wezterm-process' });

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/proc/tree/cwd');
    expect(result?.method).toBe('wezterm-process');
    expect(mockedResolveHerdrApiSocket).not.toHaveBeenCalled();
  });

  it('never calls resolveHerdrApiSocket when tty is absent', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli' });

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/tty/snapshot/cwd');
    expect(mockedResolveHerdrApiSocket).not.toHaveBeenCalled();
  });

  it('never calls resolveHerdrApiSocket when tty is an empty string', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli', tty: '' });

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/tty/snapshot/cwd');
    expect(mockedResolveHerdrApiSocket).not.toHaveBeenCalled();
  });

  it('falls back to the original directory when the herdr chain throws', async () => {
    stubDetectorOutput({ directory: '/tty/snapshot/cwd', method: 'wezterm-cli', tty: 'ttys003' });
    mockedResolveHerdrApiSocket.mockRejectedValue(new Error('unexpected'));

    const result = await strategy.detect(3000, null, null);

    expect(result?.directory).toBe('/tty/snapshot/cwd');
    expect(result?.method).toBe('wezterm-cli');
  });

  it('resolves each concurrent call independently without sharing herdr state', async () => {
    stubDetectorOutput({ directory: '/call-a/cwd', method: 'wezterm-cli', tty: 'ttys001' });
    stubDetectorOutput({ directory: '/call-b/cwd', method: 'wezterm-cli', tty: 'ttys002' });

    mockedResolveHerdrApiSocket.mockImplementation((tty) =>
      Promise.resolve(tty === 'ttys001' ? '/tmp/a.sock' : '/tmp/b.sock')
    );
    mockedGetHerdrFocusedPaneCwd.mockImplementation((socketPath) =>
      Promise.resolve(socketPath === '/tmp/a.sock' ? '/herdr/a/cwd' : '/herdr/b/cwd')
    );

    const [resultA, resultB] = await Promise.all([
      strategy.detect(3000, null, null),
      strategy.detect(3000, null, null)
    ]);

    expect(resultA?.directory).toBe('/herdr/a/cwd');
    expect(resultB?.directory).toBe('/herdr/b/cwd');
  });
});
