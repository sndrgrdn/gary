function sequenceLength(lead: number): number {
  if (lead < 0x80) {
    return 0;
  }

  if (lead >= 0xc2 && lead < 0xe0) {
    return 1;
  }

  if (lead >= 0xe0 && lead < 0xf0) {
    return 2;
  }

  if (lead >= 0xf0 && lead < 0xf5) {
    return 3;
  }

  return -1;
}

function bytesOf(input: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (ArrayBuffer.isView(input)) {
    return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  }

  return new Uint8Array(input);
}

class TextDecoder {
  readonly encoding = "utf-8";
  readonly fatal: boolean;

  constructor(_label = "utf-8", options: { readonly fatal?: boolean } = {}) {
    this.fatal = options.fatal === true;
  }

  decode(input?: ArrayBuffer | ArrayBufferView): string {
    if (input === undefined) {
      return "";
    }

    const bytes = bytesOf(input);
    let out = "";
    let index = 0;

    while (index < bytes.length) {
      const need = sequenceLength(bytes[index]);
      let code = need <= 0 ? bytes[index] : bytes[index] & (0x7f >> (need + 1));

      let valid = need >= 0 && index + need < bytes.length;

      for (let offset = 1; valid && offset <= need; offset++) {
        const next = bytes[index + offset];
        valid = (next & 0xc0) === 0x80;
        code = (code << 6) | (next & 63);
      }

      if (!valid || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
        if (this.fatal) {
          throw new TypeError("The encoded data was not valid utf-8");
        }

        out += "\uFFFD";
        index += 1;
        continue;
      }

      out += String.fromCodePoint(code);
      index += need + 1;
    }

    return out;
  }
}

Object.assign(globalThis, { TextDecoder });
