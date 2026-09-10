import type { BrowserWindow } from 'electron';
import DirectoryDetector from '../../src/managers/window/directory-detector';
import type DirectoryManager from '../../src/managers/directory-manager';
import type FileCacheManager from '../../src/managers/file-cache-manager';
import type { IDirectoryDetectionStrategy } from '../../src/managers/window/strategies';
import type { DirectoryInfo, FileInfo } from '../../src/types';

vi.mock('../../src/utils/utils', () => ({
  logger: {
    info: vi.fn(),
    debug: vi.fn(),
    warn: vi.fn(),
    error: vi.fn()
  }
}));

/**
 * These tests exercise DirectoryDetector.executeBackgroundDirectoryDetection with two
 * overlapping background detections (one herdr-backed, one a plain shell/tty detection)
 * that complete out of start order. The strategy has no single-flight/generation guard
 * by design (see [subtask:ts-wiring]), so whichever call's promise *resolves* last always
 * wins, regardless of which call started first or which detection method it used. These
 * tests pin that accepted last-resolved-wins behavior — across savedDirectory, the file
 * cache, and the renderer notification payload — so a future change to it is caught, not
 * to assert that either detection is "more correct" than the other.
 */

function createWindowMock(): { window: BrowserWindow; send: ReturnType<typeof vi.fn> } {
  const send = vi.fn();
  const window = {
    isDestroyed: () => false,
    webContents: {
      send,
      isLoading: () => false,
      once: vi.fn()
    }
  } as unknown as BrowserWindow;
  return { window, send };
}

function createDirectoryManagerMock(): { manager: DirectoryManager; setDirectory: ReturnType<typeof vi.fn> } {
  const setDirectory = vi.fn();
  const manager = { setDirectory } as unknown as DirectoryManager;
  return { manager, setDirectory };
}

function createFileCacheManagerMock(): {
  manager: FileCacheManager;
  saveCache: ReturnType<typeof vi.fn>;
  setLastUsedDirectory: ReturnType<typeof vi.fn>;
} {
  const saveCache = vi.fn().mockResolvedValue(undefined);
  const setLastUsedDirectory = vi.fn().mockResolvedValue(undefined);
  const manager = {
    loadCache: vi.fn().mockResolvedValue(null),
    saveCache,
    updateCacheTimestamp: vi.fn().mockResolvedValue(undefined),
    setLastUsedDirectory,
    getLastUsedDirectory: vi.fn().mockResolvedValue(null),
    clearCache: vi.fn().mockResolvedValue(undefined),
    isCacheValid: vi.fn().mockReturnValue(false)
  } as unknown as FileCacheManager;
  return { manager, saveCache, setLastUsedDirectory };
}

function filesFor(tag: string): FileInfo[] {
  return [{ name: `${tag}.ts`, path: `${tag}.ts`, isDirectory: false }];
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
}

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

function createDetector(): {
  detector: DirectoryDetector;
  strategy: IDirectoryDetectionStrategy;
  setDirectory: ReturnType<typeof vi.fn>;
  saveCache: ReturnType<typeof vi.fn>;
  setLastUsedDirectory: ReturnType<typeof vi.fn>;
} {
  const { manager: fileCacheManager, saveCache, setLastUsedDirectory } = createFileCacheManagerMock();
  const detector = new DirectoryDetector(fileCacheManager);
  const { manager: directoryManager, setDirectory } = createDirectoryManagerMock();
  detector.setDirectoryManager(directoryManager);
  const detect = vi.fn();
  const strategy: IDirectoryDetectionStrategy = {
    getName: () => 'fake-for-order-test',
    isAvailable: () => true,
    detect
  };
  detector.setStrategy(strategy);
  return { detector, strategy, setDirectory, saveCache, setLastUsedDirectory };
}

describe('DirectoryDetector background detection completion order (accepted, unmediated)', () => {
  it('slow herdr detection started first, fast plain-shell detection completes first: the later-resolving call (herdr) ends up as the final state', async () => {
    const { detector, strategy, setDirectory, saveCache, setLastUsedDirectory } = createDetector();
    const herdrResult: DirectoryInfo = {
      success: true,
      directory: '/herdr/pane/cwd',
      method: 'herdr-api',
      files: filesFor('herdr-a')
    };
    const plainResult: DirectoryInfo = {
      success: true,
      directory: '/plain/shell/cwd',
      method: 'wezterm-process',
      files: filesFor('plain-b')
    };

    const slowHerdr = createDeferred<DirectoryInfo | null>();
    const fastPlain = createDeferred<DirectoryInfo | null>();
    (strategy.detect as ReturnType<typeof vi.fn>)
      .mockReturnValueOnce(slowHerdr.promise)
      .mockReturnValueOnce(fastPlain.promise);

    const slow = createWindowMock();
    const fast = createWindowMock();
    const callSlow = detector.executeBackgroundDirectoryDetection(slow.window);
    const callFast = detector.executeBackgroundDirectoryDetection(fast.window);

    // Fast plain-shell detection completes first.
    fastPlain.resolve(plainResult);
    await callFast;
    expect(detector.getSavedDirectory()).toBe('/plain/shell/cwd');
    expect(setDirectory).toHaveBeenLastCalledWith('/plain/shell/cwd');
    expect(saveCache).toHaveBeenLastCalledWith('/plain/shell/cwd', plainResult.files, expect.anything());
    expect(setLastUsedDirectory).toHaveBeenLastCalledWith('/plain/shell/cwd');
    expect(fast.send).toHaveBeenCalledTimes(1);
    expect(fast.send).toHaveBeenLastCalledWith(
      'directory-data-updated',
      expect.objectContaining({ directory: '/plain/shell/cwd' })
    );

    // Slow herdr detection completes second and overwrites the state, even though
    // it started first: no coordination exists between the two calls.
    slowHerdr.resolve(herdrResult);
    await callSlow;
    expect(detector.getSavedDirectory()).toBe('/herdr/pane/cwd');
    expect(setDirectory).toHaveBeenLastCalledWith('/herdr/pane/cwd');
    expect(saveCache).toHaveBeenLastCalledWith('/herdr/pane/cwd', herdrResult.files, expect.anything());
    expect(setLastUsedDirectory).toHaveBeenLastCalledWith('/herdr/pane/cwd');
    expect(slow.send).toHaveBeenCalledTimes(1);
    expect(slow.send).toHaveBeenLastCalledWith(
      'directory-data-updated',
      expect.objectContaining({ directory: '/herdr/pane/cwd' })
    );
  });

  it('slow plain-shell detection started first, fast herdr detection completes first: the later-resolving call (plain shell) ends up as the final state', async () => {
    const { detector, strategy, setDirectory, saveCache, setLastUsedDirectory } = createDetector();
    const plainResult: DirectoryInfo = {
      success: true,
      directory: '/plain/shell/cwd2',
      method: 'wezterm-process',
      files: filesFor('plain-a')
    };
    const herdrResult: DirectoryInfo = {
      success: true,
      directory: '/herdr/pane/cwd2',
      method: 'herdr-api',
      files: filesFor('herdr-b')
    };

    const slowPlain = createDeferred<DirectoryInfo | null>();
    const fastHerdr = createDeferred<DirectoryInfo | null>();
    (strategy.detect as ReturnType<typeof vi.fn>)
      .mockReturnValueOnce(slowPlain.promise)
      .mockReturnValueOnce(fastHerdr.promise);

    const slow = createWindowMock();
    const fast = createWindowMock();
    const callSlow = detector.executeBackgroundDirectoryDetection(slow.window);
    const callFast = detector.executeBackgroundDirectoryDetection(fast.window);

    // Fast herdr detection completes first this time.
    fastHerdr.resolve(herdrResult);
    await callFast;
    expect(detector.getSavedDirectory()).toBe('/herdr/pane/cwd2');
    expect(setDirectory).toHaveBeenLastCalledWith('/herdr/pane/cwd2');
    expect(saveCache).toHaveBeenLastCalledWith('/herdr/pane/cwd2', herdrResult.files, expect.anything());
    expect(setLastUsedDirectory).toHaveBeenLastCalledWith('/herdr/pane/cwd2');
    expect(fast.send).toHaveBeenCalledTimes(1);
    expect(fast.send).toHaveBeenLastCalledWith(
      'directory-data-updated',
      expect.objectContaining({ directory: '/herdr/pane/cwd2' })
    );

    // Slow plain-shell detection completes second and overwrites the state, even
    // though it started first: the winner is whichever call resolves last, not
    // whichever detection method is used.
    slowPlain.resolve(plainResult);
    await callSlow;
    expect(detector.getSavedDirectory()).toBe('/plain/shell/cwd2');
    expect(setDirectory).toHaveBeenLastCalledWith('/plain/shell/cwd2');
    expect(saveCache).toHaveBeenLastCalledWith('/plain/shell/cwd2', plainResult.files, expect.anything());
    expect(setLastUsedDirectory).toHaveBeenLastCalledWith('/plain/shell/cwd2');
    expect(slow.send).toHaveBeenCalledTimes(1);
    expect(slow.send).toHaveBeenLastCalledWith(
      'directory-data-updated',
      expect.objectContaining({ directory: '/plain/shell/cwd2' })
    );
  });
});
