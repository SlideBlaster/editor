const errnoSuccess = 0;
const errnoBadFileDescriptor = 8;
const errnoInvalidArgument = 28;
const errnoNotSupported = 58;
const fileTypeCharacterDevice = 2;

/**
 * Minimal, self-contained WASI Preview 1 provider for a GHC reactor.
 *
 * SlideBlaster performs browser effects through JSFFI hostCall, so this class
 * intentionally provides only the clocks, randomness, and standard streams
 * needed to initialize and diagnose the single-threaded GHC runtime. Unknown
 * WASI imports resolve to ENOTSUP instead of gaining ambient capabilities.
 */
export class BrowserWasiPreview1 {
  #memory: WebAssembly.Memory | null = null;
  imports: any;
  #stdout = new LineSink("log");
  #stderr = new LineSink("error");

  constructor() {
    const implemented = {
      args_get: () => errnoSuccess,
      args_sizes_get: (countPointer, bufferSizePointer) => {
        this.#writeUint32(countPointer, 0);
        this.#writeUint32(bufferSizePointer, 0);
        return errnoSuccess;
      },
      clock_res_get: (_clockId, resolutionPointer) => {
        this.#writeUint64(resolutionPointer, 1_000_000n);
        return errnoSuccess;
      },
      clock_time_get: (clockId, _precision, timePointer) => {
        const milliseconds =
          clockId === 0 ? Date.now() : globalThis.performance.now();
        this.#writeUint64(
          timePointer,
          BigInt(Math.floor(milliseconds * 1_000_000)),
        );
        return errnoSuccess;
      },
      environ_get: () => errnoSuccess,
      environ_sizes_get: (countPointer, bufferSizePointer) => {
        this.#writeUint32(countPointer, 0);
        this.#writeUint32(bufferSizePointer, 0);
        return errnoSuccess;
      },
      fd_close: (descriptor) =>
        descriptor <= 2 ? errnoSuccess : errnoBadFileDescriptor,
      fd_datasync: (descriptor) =>
        descriptor <= 2 ? errnoSuccess : errnoBadFileDescriptor,
      fd_fdstat_get: (descriptor, statPointer) =>
        this.#writeFileDescriptorStat(descriptor, statPointer),
      fd_filestat_get: (descriptor, statPointer) =>
        this.#writeFileStat(descriptor, statPointer),
      fd_read: () => errnoBadFileDescriptor,
      fd_seek: () => errnoBadFileDescriptor,
      fd_sync: (descriptor) =>
        descriptor <= 2 ? errnoSuccess : errnoBadFileDescriptor,
      fd_write: (descriptor, vectorsPointer, vectorsLength, writtenPointer) =>
        this.#writeToDescriptor(
          descriptor,
          vectorsPointer,
          vectorsLength,
          writtenPointer,
        ),
      path_open: () => errnoNotSupported,
      poll_oneoff: (_input, _output, _subscriptions, eventCountPointer) => {
        this.#writeUint32(eventCountPointer, 0);
        return errnoNotSupported;
      },
      proc_exit: (code) => {
        throw new WebAssembly.RuntimeError(
          `The Wasm reactor requested process exit ${code}`,
        );
      },
      random_get: (bufferPointer, bufferLength) =>
        this.#fillRandom(bufferPointer, bufferLength),
      sched_yield: () => errnoSuccess,
    };

    this.imports = new Proxy(implemented, {
      get(target, property) {
        if (typeof property === "symbol") {
          return target[property];
        }
        return target[property] ?? (() => errnoNotSupported);
      },
    });
  }

  /**
   * Bind memory and invoke the reactor initializer exactly once.
   *
   * @param {WebAssembly.Instance} instance
   */
  initialize(instance) {
    if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
      throw new Error("The GHC Wasm module did not export linear memory");
    }
    if (typeof instance.exports._initialize !== "function") {
      throw new Error("The Wasm module is not a reactor: _initialize is absent");
    }
    if (this.#memory !== null) {
      throw new Error("The Wasm reactor was initialized more than once");
    }

    this.#memory = instance.exports.memory;
    instance.exports._initialize();
  }

  #fillRandom(bufferPointer, bufferLength) {
    const bytes = this.#bytes(bufferPointer, bufferLength);
    for (let offset = 0; offset < bytes.length; offset += 65_536) {
      globalThis.crypto.getRandomValues(bytes.subarray(offset, offset + 65_536));
    }
    return errnoSuccess;
  }

  #writeFileDescriptorStat(descriptor, statPointer) {
    if (descriptor > 2) {
      return errnoBadFileDescriptor;
    }
    const bytes = this.#bytes(statPointer, 24);
    bytes.fill(0);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    view.setUint8(0, fileTypeCharacterDevice);
    view.setBigUint64(8, 0xffffffffffffffffn, true);
    view.setBigUint64(16, 0xffffffffffffffffn, true);
    return errnoSuccess;
  }

  #writeFileStat(descriptor, statPointer) {
    if (descriptor > 2) {
      return errnoBadFileDescriptor;
    }
    const bytes = this.#bytes(statPointer, 64);
    bytes.fill(0);
    bytes[16] = fileTypeCharacterDevice;
    return errnoSuccess;
  }

  #writeToDescriptor(
    descriptor,
    vectorsPointer,
    vectorsLength,
    writtenPointer,
  ) {
    if (descriptor !== 1 && descriptor !== 2) {
      return errnoBadFileDescriptor;
    }

    const memoryView = this.#view();
    const chunks: Uint8Array[] = [];
    let totalLength = 0;
    for (let index = 0; index < vectorsLength; index += 1) {
      const vectorPointer = vectorsPointer + index * 8;
      const dataPointer = memoryView.getUint32(vectorPointer, true);
      const dataLength = memoryView.getUint32(vectorPointer + 4, true);
      const chunk = new Uint8Array(this.#memory!.buffer, dataPointer, dataLength);
      chunks.push(chunk);
      totalLength += dataLength;
    }

    const output = new Uint8Array(totalLength);
    let outputOffset = 0;
    for (const chunk of chunks) {
      output.set(chunk, outputOffset);
      outputOffset += chunk.length;
    }

    (descriptor === 1 ? this.#stdout : this.#stderr).write(output);
    this.#writeUint32(writtenPointer, totalLength);
    return errnoSuccess;
  }

  #bytes(pointer, length) {
    if (this.#memory === null) {
      throw new Error("WASI memory was accessed before reactor initialization");
    }
    return new Uint8Array(this.#memory.buffer, pointer >>> 0, length >>> 0);
  }

  #view() {
    if (this.#memory === null) {
      throw new Error("WASI memory was accessed before reactor initialization");
    }
    return new DataView(this.#memory.buffer);
  }

  #writeUint32(pointer, value) {
    this.#view().setUint32(pointer >>> 0, value >>> 0, true);
  }

  #writeUint64(pointer, value) {
    this.#view().setBigUint64(pointer >>> 0, value, true);
  }
}

class LineSink {
  #buffer = "";
  #decoder = new TextDecoder();
  #method;

  constructor(method) {
    this.#method = method;
  }

  write(bytes) {
    this.#buffer += this.#decoder.decode(bytes, { stream: true });
    const lines = this.#buffer.split("\n");
    this.#buffer = lines.pop() ?? "";
    for (const line of lines) {
      globalThis.console[this.#method](`[WASI] ${line}`);
    }
  }
}
